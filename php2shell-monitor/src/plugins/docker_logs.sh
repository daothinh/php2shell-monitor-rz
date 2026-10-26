#!/usr/bin/env bash
# docker_logs.sh - log của mọi container Docker (stdout/stderr). Read-only.
#
# Script chạy sudo nên ưu tiên đọc THẲNG file json log dưới
# $DOCKER_LOG_DIR (mặc định /var/lib/docker/containers): không cần docker
# CLI/socket, offset-tracked nên không quét lại dòng cũ giữa các batch.
# Fallback khi thư mục đó không đọc được (rootless docker...): `docker logs`
# qua con trỏ bền bên dưới.
#
# VÌ SAO DÙNG AWK (lib/dockerlog.awk):
# Bản bash cũ bung từng dòng bằng `sed` rồi lọc bằng `grep -qP`. Mỗi dòng tốn
# 2 fork ≈ 2.4 ms. Đo trên máy thật: hai container 76 MB = 1.216.130 dòng mất
# 49 phút, trong khi PLUGIN_TIMEOUT là 120 s. Plugin bị kill mỗi batch, không
# bao giờ chạy xong, và vì offset chỉ được ghi SAU vòng lặp nên batch sau lại
# đọc từ byte 0 — vòng lặp chết, host quét ổn định nhưng container thì không
# bao giờ xong. awk làm cùng việc trong MỘT process: 607k dòng hết 10 s.
#
# Ngoài ra dòng access-log của container lab ghi dạng nginx ngắn
#   IP -  dd/Mon/yyyy:hh:mm:ss +0000 "GET /x" 200
# không có referer/ua và không có HTTP/1.1, nên regex combined cũ không khớp
# và 100% dòng rơi xuống nhánh grep chậm nhất. Parser awk nhận cả hai dạng.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/_batch_common.sh"

plugin_name=docker_logs
export plugin_name

DOCKER_LOG_DIR=${DOCKER_LOG_DIR:-/var/lib/docker/containers}
DOCKERLOG_AWK=$P2S_SRC_DIR/lib/dockerlog.awk

# Marker cho dòng KHÔNG phải access-log: chỉ giữ khi là lỗi PHP/FPM thật hoặc
# marker tấn công. KHÔNG dùng nhánh trần "in Unknown on line 0": MỌI cảnh báo
# PHP đều kết thúc bằng chuỗi đó, nên nó từng biến log lành thành HIGH. Chỉ giữ
# khi đi kèm "PHP Fatal error:".
MARKER_RE='Allowed memory size of [0-9]+ bytes exhausted|PHP Fatal error: +Out of memory|Hard memory limit of [0-9]+ bytes|PHP Fatal error:.*in Unknown on line 0|exited on signal|exit signal|segfault|SIGSEGV|SIGBUS|SIGABRT|upstream prematurely|recv\(\) failed \(104|exit code (70|137)|execution timed out|php2shell|php_session_upload_progress'

# Nhận diện dòng bắt đầu bằng địa chỉ IP: đủ để biết đây là access-log và đưa
# sang parser field. Chi tiết method/uri/status do awk bóc.
ACCESS_RE='^([0-9]{1,3}(\.[0-9]{1,3}){3}|\[?[0-9a-fA-F:]{2,}\]?) '

# ----- nhánh 1: đọc file json log trực tiếp (cần root — script chạy sudo) -----
found_json=0
if [[ -d $DOCKER_LOG_DIR && -r $DOCKER_LOG_DIR ]]; then
  for d in "$DOCKER_LOG_DIR"/*/; do
    [[ -d $d ]] || continue
    cid=$(basename "$d")
    jf="$d/${cid}-json.log"
    # local log driver không có *-json.log (định dạng nội bộ) -> để CLI fallback
    [[ -f $jf && -r $jf ]] || continue
    found_json=1
    name=$(grep -o '"Name":"[^"]*"' "$d/config.v2.json" 2>/dev/null | head -1 | cut -d'"' -f4)
    name=${name#/}
    name=${name:-${cid:0:12}}

    # batch_parse_awk: đọc phần byte mới, chạy awk MỘT lần, cập nhật offset.
    # realfile override đường dẫn thật bằng "docker:<tên container>": alert phải
    # chỉ được container nào, không phải chuỗi hash 64 ký tự. Offset vẫn khoá
    # theo đường dẫn thật (bash giữ $jf), nên đổi tên container không làm mất
    # tiến độ đọc.
    batch_parse_awk "$jf" access_log dockerlog.awk \
      -v realfile="docker:$name" -v name="$name" \
      -v accessre="$ACCESS_RE" -v markerre="$MARKER_RE"
  done
fi

# ----- nhánh 2 (fallback): docker logs CLI + con trỏ bền -----
# Chỉ chạy khi không đọc được file json (rootless docker, log driver khác).
if (( ! found_json )); then
  have docker || exit 0

  CURSOR_FILE=$P2S_STATE_DIR/docker_cursors.tsv

  # _cursor_get <container> -> "<ts>\t<seq>" hoặc chuỗi RỖNG khi chưa có.
  # Không dùng sentinel "\t0": tab đứng đầu là IFS-whitespace nên `read` nuốt
  # mất, biến thành cur_ts="0" — mà --since 0 là EPOCH 0, lần chạy đầu đọc lại
  # TOÀN BỘ lịch sử container.
  _cursor_get() {
    local c=$1
    [[ -r $CURSOR_FILE ]] || return 0
    awk -F'\t' -v c="$c" '$1 == c { printf "%s\t%s", $2, $3; exit }' "$CURSOR_FILE"
  }

  # _cursor_set <container> <ts> <seq> — ghi đè dòng của container, giữ nguyên
  # dòng của container khác (flock: các plugin chạy song song).
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

  docker ps --format '{{.Names}}' 2>/dev/null |
  while IFS= read -r c; do
    [[ -z $c ]] && continue
    cur_ts=''; cur_seq=0
    x=$(_cursor_get "$c")
    if [[ -n $x ]]; then
      cur_ts=${x%%$'\t'*}
      cur_seq=${x#*$'\t'}
      # cursor của bản lỗi cũ ghi ts="0" (epoch 0): coi như chưa có mốc
      [[ $cur_ts == 0 ]] && cur_ts=''
    fi
    # --since nhận RFC3339 tới giây; phần lẻ nano do bộ lọc dưới đây xử lý.
    since=${cur_ts:+${cur_ts%%.*}}
    since=${since:-${DOCKER_LOG_SINCE:-10m}}

    new_ts=$cur_ts
    new_seq=$cur_seq
    # Gom nội dung mới vào một file rồi cho awk xử lý MỘT lượt: giữ nguyên
    # tốc độ của nhánh file, không quay lại fork từng dòng.
    raw="$P2S_TMP_DIR/docker.cli.$$.log"
    : >"$raw"
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
      # Ghi vào $raw kèm ts để awk dùng đúng thời điểm sự việc. PHẢI >>"$raw":
      # thiếu redirect thì dòng in thẳng ra stream record (phá TSV), $raw rỗng
      # mãi -> awk không chạy -> CLI fallback mất im lặng mọi dòng trong khi
      # cursor vẫn ghi như đã xử lý.
      if [[ -n $ts ]]; then printf '%s %s\n' "$ts" "$body" >>"$raw"; else printf '%s\n' "$body" >>"$raw"; fi
      new_seq=$((new_seq + 1))
      [[ -n $ts ]] && new_ts=$ts
    done < <(docker logs --timestamps --since "$since" "$c" 2>&1)

    if [[ -s $raw ]]; then
      awk -f "$DOCKERLOG_AWK" \
          -v realfile="docker:$c" -v startline=0 -v name="$c" \
          -v accessre="$ACCESS_RE" -v markerre="$MARKER_RE" \
          -v cli_ts=1 "$raw"
    fi
    rm -f -- "$raw"

    if [[ $new_ts != "$cur_ts" || $new_seq -gt $cur_seq ]]; then
      _cursor_set "$c" "${new_ts:-}" "$new_seq"
    fi
  done
fi
