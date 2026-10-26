#!/usr/bin/env bash
# docker_logs.sh - log của mọi container Docker (stdout/stderr). Read-only.
#
# Script chạy sudo nên ưu tiên đọc THẲNG file json log dưới
# $DOCKER_LOG_DIR (mặc định /var/lib/docker/containers): không cần docker
# CLI/socket, offset-tracked qua batch_read nên không quét lại dòng cũ giữa
# các batch. Fallback khi thư mục đó không đọc được (rootless docker...):
# `docker logs` qua con trỏ bền dưới đây.
#
# Con trỏ cho nhánh CLI: plugin từng chạy `docker logs --since 10m` mỗi batch
# mà không lưu con trỏ. BATCH_INTERVAL=300s nên cửa sổ 600s phủ gấp đôi chu kỳ:
# cùng một dòng bị đẩy lên central 2-3 lần, và `n` đếm lại từ 1 mỗi lần nên
# `file:line` trỏ sai chỗ. Con trỏ lưu (timestamp cuối, số thứ tự cuối) cho
# từng container.
#
# Mỗi dòng log được bung nội dung:
#   - dòng có dạng access-log combined (image apache/nginx chính thức ghi
#     access ra stdout) -> phát dưới nguồn access_log kèm đủ field
#     ip/method/uri/status/ua để TRỌN BỘ rule tấn công (P2S-008/015/016/017/
#     030/050..058) áp dụng cho cả app chạy trong container;
#   - dòng còn lại chỉ phát khi khớp marker crash/OOM hoặc marker tấn công,
#     dưới nguồn docker.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/_batch_common.sh"

plugin_name=docker_logs
export plugin_name

DOCKER_LOG_DIR=${DOCKER_LOG_DIR:-/var/lib/docker/containers}

# Lọc thô cho dòng KHÔNG phải access-log: chỉ những dòng có khả năng là lỗi
# PHP/FPM thật hoặc marker tấn công.
#
# KHÔNG dùng nhánh trần "in Unknown on line 0": MỌI cảnh báo PHP (session ID
# quá dài, module đã load, deprecated, startup warning...) đều kết thúc bằng
# chuỗi đó. Nó từng biến log lành của container thành HIGH: 3 dòng "Session ID
# is too long / Failed to read session data / Failed to write session data"
# khớp cả prefilter này lẫn rule P2S-010. Chỉ giữ "in Unknown on line 0" khi đi
# kèm "PHP Fatal error:" — đó mới là crash, không phải cảnh báo.
DOCKER_RE='Allowed memory size of [0-9]+ bytes exhausted|PHP Fatal error: +Out of memory|Hard memory limit of [0-9]+ bytes|PHP Fatal error:.*in Unknown on line 0|exited on signal|exit signal|segfault|SIGSEGV|SIGBUS|SIGABRT|upstream prematurely|recv\(\) failed \(104|exit code (70|137)|execution timed out'
ATTACK_RE='(?i)php2shell|php_session_upload_progress'

# access-log combined: $1=ip $4=method $5=request $6=status $8=referer $9=ua
ACCESS_RE='^([0-9]{1,3}(\.[0-9]{1,3}){3}|([0-9a-f]{0,4}:){2,}[0-9a-f:]+) [^ ]+ [^ ]+ \[[^]]*\] "([A-Z]+) ([^"]*)" ([0-9]{3}) ([0-9]+|-) "([^"]*)" "([^"]*)"'

# docker json-file escape \" \\ \n \r \t -> chuỗi gốc (thứ tự: \\ qua placeholder
# để không corrupt cặp \\\\n = backslash thật + chữ n)
json_unescape() { # <chuỗi>
  local s=$1
  s=${s//\\\\/$'\x01'}
  s=${s//\\\"/\"}
  s=${s//\\n/ }
  s=${s//\\r/}
  s=${s//\\t/ }
  s=${s//$'\x01'/\\}
  printf '%s' "$s"
}

# Xử lý 1 dòng log: json từ file (tự chứa time) hoặc nội dung thô từ CLI
# (ts truyền qua $2 khi `docker logs --timestamps` tách sẵn prefix).
# Biến toàn cục DL_NAME = tên container do vòng gọi đặt sẵn.
# return 0 khi có emit, 1 khi dòng bị lọc.
docker_handle_line() {
  local raw=$1 ots=${2:-} msg='' ts=''
  msg=$(printf '%s' "$raw" | sed -n 's/^{"log":"\(.*\)","stream":"\(stdout\|stderr\)".*$/\1/p')
  if [[ -n $msg ]]; then
    ts=$(printf '%s' "$raw" | sed -n 's/.*"time":"\([^"]*\)".*$/\1/p')
    msg=$(json_unescape "$msg")
  else
    msg=$raw   # docker logs CLI đã bung sẵn; hoặc dòng không phải json
  fi
  [[ -n $ots ]] && ts=$ots

  # access-log combined -> nguồn access_log, bung field cho rule tấn công
  if [[ $msg =~ $ACCESS_RE ]]; then
    local ip=${BASH_REMATCH[1]} method=${BASH_REMATCH[4]} req=${BASH_REMATCH[5]}
    local status=${BASH_REMATCH[6]} ua=${BASH_REMATCH[9]} uri
    uri=${req% HTTP/*}; uri=${uri% http/*}
    P2S_TS=${ts:-$(utc_now)}; export P2S_TS
    emit_record access_log "docker:$DL_NAME" "$P2S_LINE" \
      "$ip" "$method" "$uri" "$status" "$ua" - "$msg" -
    return 0
  fi

  # dòng thường: chỉ giữ dòng có marker crash/OOM hoặc marker tấn công
  printf '%s' "$msg" | grep -qP "$DOCKER_RE|$ATTACK_RE" || return 1
  P2S_TS=${ts:-$(utc_now)}; export P2S_TS
  emit_record docker "docker:$DL_NAME" "$P2S_LINE" "" "" "" "" "" "" "[$DL_NAME] $msg" -
  return 0
}

# ----- con trỏ cho nhánh CLI (file json log thì batch_read đã tự offset) -----

CURSOR_FILE=$P2S_STATE_DIR/docker_cursors.tsv

# _cursor_get <container> -> "<ts>\t<seq>" hoặc chuỗi RỖNG khi chưa có con trỏ.
# Không dùng sentinel "\t0": tab đứng đầu là IFS-whitespace nên `read` nuốt
# mất, biến thành cur_ts="0" — mà --since 0 là EPOCH 0, lần chạy đầu đọc lại
# TOÀN BỘ lịch sử container thay vì chỉ cửa sổ gần nhất.
_cursor_get() {
  local c=$1
  [[ -r $CURSOR_FILE ]] || return 0
  awk -F'\t' -v c="$c" '$1 == c { printf "%s\t%s", $2, $3; exit }' "$CURSOR_FILE"
}

# _cursor_set <container> <timestamp> <seq> — ghi đè dòng của container, giữ
# nguyên dòng của container khác (flock: các plugin chạy song song).
_cursor_set() {
  local c=$1 ts=$2 seq=$3 tmp="$CURSOR_FILE.tmp.$$"
  [[ -d ${CURSOR_FILE%/*} ]] || return 0
  (
    flock -w 5 8 || exit 0
    {
      [[ -r $CURSOR_FILE ]] && awk -F'\t' -v c="$c" '$1 != c' "$CURSOR_FILE"
      printf '%s\t%s\t%s\n' "$c" "$ts" "$seq"
    } >"$tmp" && mv -f -- "$tmp" "$CURSOR_FILE"
  ) 8>"$CURSOR_FILE.lock"
  rm -f -- "$tmp"
}

# ----- đường 1: đọc file json log trực tiếp (cần root — script chạy sudo) -----
found_json=0
if [[ -d $DOCKER_LOG_DIR && -r $DOCKER_LOG_DIR ]]; then
  for d in "$DOCKER_LOG_DIR"/*/; do
    [[ -d $d ]] || continue
    local_cid=$(basename "$d")
    jf="$d/${local_cid}-json.log"
    # local log driver không có *-json.log (định dạng nội bộ) -> để CLI fallback
    [[ -f $jf && -r $jf ]] || continue
    found_json=1
    DL_NAME=$(grep -o '"Name":"[^"]*"' "$d/config.v2.json" 2>/dev/null \
              | head -1 | cut -d'"' -f4)
    DL_NAME=${DL_NAME#/}
    DL_NAME=${DL_NAME:-${local_cid:0:12}}
    export DL_NAME
    batch_read "$jf" docker_handle_line
  done
fi

# ----- đường 2 (fallback): docker logs CLI + con trỏ bền -----
if (( ! found_json )); then
  have docker || exit 0
  docker ps --format '{{.Names}}' 2>/dev/null |
  while IFS= read -r c; do
    [[ -z $c ]] && continue
    cur_ts=''; cur_seq=0
    x=$(_cursor_get "$c")
    if [[ -n $x ]]; then
      cur_ts=${x%%$'\t'*}
      cur_seq=${x#*$'\t'}
      # dòng cursor của bản lỗi cũ ghi ts="0" (epoch 0): coi như chưa có mốc
      [[ $cur_ts == 0 ]] && cur_ts=''
    fi
    # --since nhận RFC3339 tới giây; phần lẻ nano do bộ lọc bên dưới xử lý.
    since=${cur_ts:+${cur_ts%%.*}}
    since=${since:-${DOCKER_LOG_SINCE:-10m}}

    new_ts=$cur_ts
    new_seq=$cur_seq
    DL_NAME=$c
    export DL_NAME
    while IFS= read -r line; do
      [[ -z $line ]] && continue
      # `docker logs --timestamps`: "<rfc3339nano> <message>"
      ts=${line%% *}
      if [[ $ts =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z$ ]]; then
        body=${line#* }
      else
        ts=''; body=$line
      fi
      # Đã thấy ở batch trước: bỏ. So sánh chuỗi hợp lệ vì docker in timestamp
      # cố định độ rộng phần lẻ (9 chữ số).
      [[ -n $cur_ts && -n $ts && ! $ts > $cur_ts ]] && continue
      P2S_LINE=$((new_seq + 1)); export P2S_LINE
      if docker_handle_line "$body" "$ts"; then
        new_seq=$((new_seq + 1))
        [[ -n $ts ]] && new_ts=$ts
      fi
    done < <(docker logs --timestamps --since "$since" "$c" 2>&1)

    if [[ $new_ts != "$cur_ts" || $new_seq -gt "$cur_seq" ]]; then
      _cursor_set "$c" "${new_ts:-}" "$new_seq"
    fi
  done
fi
