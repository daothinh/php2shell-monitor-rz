#!/usr/bin/env bash
# readcap.sh - đọc phần MỚI của một file đang ghi, có trần byte và có trần thời
# gian cho TỪNG nguồn (không phải cho cả batch).
#
# VÌ SAO CẦN
# 1. `tail -c +$((pos+1)) file > chunk` đọc tới EOF. Với /var/log/syslog 269 MB
#    và offset 0, một batch đọc hết 269 MB: vượt PLUGIN_TIMEOUT, plugin bị kill
#    trước khi kịp ghi offset, batch sau lại đọc từ byte 0 — lặp vô hạn, mỗi
#    batch đều rc=124 và không dòng nào tới được rule matcher.
# 2. Không có trần thời gian thì một nguồn chậm (ổ đĩa bận, file trên NFS) giữ
#    CPU của plugin cho tới khi bị timeout cả plugin — nghĩa là các nguồn phía
#    sau trong cùng plugin không bao giờ được đọc.
#
# HAI LUẬT
#   * Chưa có cursor (pos == 0) và file lớn hơn trần  -> nhảy tới EOF - trần.
#     Cursor của lần đầu là "từ đây về sau", không phải "toàn bộ lịch sử": quét
#     lịch sử là việc của retro_hunt (có cửa sổ thời gian riêng), không phải
#     của batch 5 phút.
#   * Đã có cursor -> đọc tiếp từ cursor, tối đa <trần> byte mỗi batch.
# Nhảy tới giữa file thì dòng đầu tiên là một mảnh dòng: bỏ nó đi và dời base
# tới newline đầu tiên, nếu không record đầu tiên sẽ có ip/uri rỗng.
[[ -n ${P2S_READCAP_SH:-} ]] && return 0
P2S_READCAP_SH=1

P2S_READ_CAP_BYTES=${P2S_READ_CAP_BYTES:-33554432}   # 32 MB / nguồn / batch
P2S_READ_TIMEOUT=${P2S_READ_TIMEOUT:-45}             # giây / nguồn / batch
# Ngưỡng để LẦN ĐẦU nhảy tới (EOF - cap). Dưới ngưỡng này thì đọc tuần tự từ
# byte 0 theo từng chunk: log vừa phải (access log container vài chục MB) phải
# được đọc TRỌN, không được bỏ lịch sử chỉ vì nó lớn hơn trần một batch.
# Trên ngưỡng (syslog 269 MB) thì lịch sử là việc của retro_hunt.
P2S_READ_JUMP_BYTES=${P2S_READ_JUMP_BYTES:-67108864}  # 64 MB
# Kết quả của p2s_read_new_bytes / p2s_read_chunk được CALLER đọc; shellcheck
# không thấy được điều đó nên khai báo tường minh.
# shellcheck disable=SC2034
P2S_RD_BASE=0
# shellcheck disable=SC2034
P2S_RD_LEN=0
# shellcheck disable=SC2034
P2S_RD_JUMPED=0
# shellcheck disable=SC2034
P2S_RD_TIMEOUT=0
# shellcheck disable=SC2034
P2S_TRIM_BYTES=0

# p2s_file_kind <path> -> regular | stdout | other
#
# `stdout` là trường hợp thật đã làm container_accesslog treo 120 s mỗi batch:
# nginx:alpine để /var/log/nginx/access.log là symlink tới /dev/stdout. Khi đọc
# từ host, đích tuyệt đối /dev/stdout được giải theo namespace của HOST, tức
# /proc/<pid-của-chính-plugin>/fd/1. Vì plugins.sh redirect stdout của plugin
# vào một file, `-f` lại ĐÚNG, và `tail` đọc chính file đang được plugin ghi ra
# -> file tự dài ra trong lúc đọc -> không bao giờ tới EOF. Đây là lý do phải
# phân loại bằng readlink TRƯỚC, không bằng `-f`.
p2s_file_kind() {
  local f=$1 t abs
  t=$(readlink -- "$f" 2>/dev/null) || t=''
  if [[ -n $t ]]; then
    case $t in
      /*) abs=$t ;;
      *)  abs=$(dirname -- "$f" 2>/dev/null)/$t ;;
    esac
    case $abs in
      /dev/*|/proc/*) printf 'stdout'; return 0 ;;
    esac
  fi
  case $(stat -Lc '%F' -- "$f" 2>/dev/null) in
    'regular file'|'regular empty file') printf 'regular' ;;
    *) printf 'other' ;;
  esac
}

# p2s_read_bytes <file> <start> <want> <timeout> <out> -> 0 | 124 (timeout)
# Đọc tối đa <want> byte kể từ byte <start> (0-based), ghi ra <out>.
# `</dev/null` để lệnh không bao giờ chờ stdin của plugin.
# PIPESTATUS[0]=141 (tail bị SIGPIPE vì head đã đủ byte) là thành công: đó chính
# là trường hợp "còn dữ liệu nhưng đã chạm trần", không phải lỗi.
p2s_read_bytes() {
  local f=$1 start=$2 want=$3 tmo=$4 out=$5 rc
  : >"$out" || return 1
  (( want > 0 )) || return 0
  timeout -k 2 "$tmo" tail -c "+$((start + 1))" -- "$f" 2>/dev/null </dev/null \
    | head -c "$want" >"$out"
  rc=${PIPESTATUS[0]}
  case $rc in
    0|141) return 0 ;;
    *)     return "$rc" ;;
  esac
}

# p2s_read_new_bytes <file> <pos> <size> <cap> <timeout> <out>
# Kết quả (biến toàn cục, không dùng $(...) để khỏi fork):
#   P2S_RD_BASE    byte gốc thật của chunk (sau khi nhảy / bỏ mảnh đầu)
#   P2S_RD_LEN     số byte đã đọc
#   P2S_RD_JUMPED  1 = lần đọc đầu và đã nhảy tới EOF - cap
#   P2S_RD_TIMEOUT 1 = bị cắt vì trần thời gian
# Trả 0 nếu đọc được (kể cả timeout — phần đã đọc vẫn dùng được), 1 nếu lỗi I/O.
# shellcheck disable=SC2034  # các P2S_RD_* được caller đọc
p2s_read_new_bytes() {
  local f=$1 pos=$2 size=$3 cap=$4 tmo=$5 out=$6
  P2S_RD_BASE=$pos; P2S_RD_LEN=0; P2S_RD_JUMPED=0; P2S_RD_TIMEOUT=0
  (( cap > 0 )) || cap=$P2S_READ_CAP_BYTES
  local avail=$((size - pos)) start want rc
  (( avail > 0 )) || { : >"$out"; return 0; }

  start=$pos
  if (( pos == 0 && size > cap && size > P2S_READ_JUMP_BYTES )); then
    start=$((size - cap))
    P2S_RD_JUMPED=1
  fi
  want=$((size - start))
  (( want > cap )) && want=$cap

  p2s_read_bytes "$f" "$start" "$want" "$tmo" "$out"
  rc=$?
  case $rc in
    0) ;;
    124|137) P2S_RD_TIMEOUT=1 ;;
    *) return 1 ;;
  esac
  local got
  got=$(stat -c '%s' -- "$out" 2>/dev/null || printf '0')
  [[ $got =~ ^[0-9]+$ ]] || got=0
  P2S_RD_BASE=$start
  P2S_RD_LEN=$got

  # Nhảy vào giữa file: bỏ mảnh dòng đầu tiên (không có newline đứng trước nó).
  if (( P2S_RD_JUMPED )) && (( got > 0 )); then
    : >"$out.t"
    LC_ALL=C awk 'NR == 1 { printf "%d\n", length($0) + 1; exit }' "$out" \
      >"$out.t" 2>/dev/null
    local nl=0
    read -r nl <"$out.t" 2>/dev/null || nl=0
    [[ $nl =~ ^[0-9]+$ ]] || nl=0
    rm -f -- "$out.t"
    # awk trên chunk: dòng đầu dài `nl - 1` byte ⇒ newline đầu tiên ở byte `nl`.
    # Chunk không có newline nào ⇒ nl = got + 1 > got ⇒ rơi vào nhánh bỏ sạch.
    if (( nl > 0 && nl <= got )); then
      tail -c "+$((nl + 1))" -- "$out" >"$out.t" 2>/dev/null && mv -f -- "$out.t" "$out"
      P2S_RD_BASE=$((start + nl))
      got=$((got - nl))
      P2S_RD_LEN=$got
    else
      : >"$out"
      P2S_RD_BASE=$((start + got))
      P2S_RD_LEN=0
    fi
  fi
  return 0
}

# p2s_trim_partial <chunk>
# Bỏ dòng dở cuối (file/chunk không kết thúc bằng newline) và đặt
# P2S_TRIM_BYTES = số byte của phần đã trọn dòng.
# shellcheck disable=SC2034  # P2S_TRIM_BYTES được caller đọc
p2s_trim_partial() {
  local chunk=$1
  P2S_TRIM_BYTES=0
  [[ -s $chunk ]] || return 0
  P2S_TRIM_BYTES=$(stat -c '%s' -- "$chunk" 2>/dev/null || printf '0')
  [[ $P2S_TRIM_BYTES =~ ^[0-9]+$ ]] || P2S_TRIM_BYTES=0
  [[ $(tail -c1 -- "$chunk" 2>/dev/null | wc -l) -ne 0 ]] && return 0
  local complete=0
  LC_ALL=C awk '
    { n += length($0) + 1; last = length($0) }
    END { v = n - last - 1; print (v > 0 ? v : 0) }
  ' "$chunk" 2>/dev/null >"$chunk.cb"
  read -r complete <"$chunk.cb" 2>/dev/null || complete=0
  rm -f -- "$chunk.cb"
  [[ $complete =~ ^[0-9]+$ ]] || complete=0
  if (( complete > 0 )); then
    head -c "$complete" -- "$chunk" >"$chunk.full" && mv -f -- "$chunk.full" "$chunk"
    P2S_TRIM_BYTES=$complete
  else
    : >"$chunk"
    P2S_TRIM_BYTES=0
  fi
  return 0
}

# p2s_read_chunk <file> <pos> <size> <cap> <timeout> <chunk>
# Đọc phần mới + bỏ dòng dở. Kết quả: P2S_RD_BASE, P2S_RD_TIMEOUT, P2S_RD_JUMPED,
# P2S_TRIM_BYTES.
# shellcheck disable=SC2034  # P2S_TRIM_BYTES/P2S_RD_* được caller đọc
p2s_read_chunk() {
  local file=$1 pos=$2 size=$3 cap=$4 tmo=$5 chunk=$6
  p2s_read_new_bytes "$file" "$pos" "$size" "$cap" "$tmo" "$chunk" || return 1
  p2s_trim_partial "$chunk"
  return 0
}
