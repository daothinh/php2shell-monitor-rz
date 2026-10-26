#!/usr/bin/env bash
# docker_logs.sh - container stdout/stderr via `docker logs`. Read-only.
#
# Mỗi batch chỉ đọc phần log MỚI của từng container, không đọc lại cửa sổ cũ.
#
# Trước đây plugin chạy `docker logs --since 10m` mỗi batch mà không lưu con trỏ.
# BATCH_INTERVAL=300s nên cửa sổ 600s phủ gấp đôi chu kỳ: cùng một dòng bị đẩy
# lên central 2-3 lần, và vì `n` đếm lại từ 1 mỗi lần nên `file:line` trỏ sai
# chỗ. Con trỏ ở đây lưu (timestamp cuối, số thứ tự cuối) cho từng container.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/_batch_common.sh"

plugin_name=docker_logs
export plugin_name

# Lọc thô trước khi emit: chỉ những dòng có khả năng là lỗi PHP/FPM thật.
#
# KHÔNG dùng nhánh trần "in Unknown on line 0": MỌI cảnh báo PHP (session ID
# quá dài, module đã load, deprecated, startup warning...) đều kết thúc bằng
# chuỗi đó. Nó từng biến log lành của container thành HIGH: 3 dòng "Session ID
# is too long / Failed to read session data / Failed to write session data"
# khớp cả prefilter này lẫn rule P2S-010. Chỉ giữ "in Unknown on line 0" khi đi
# kèm "PHP Fatal error:" — đó mới là crash, không phải cảnh báo.
DOCKER_RE='Allowed memory size of [0-9]+ bytes exhausted|PHP Fatal error: +Out of memory|Hard memory limit of [0-9]+ bytes|PHP Fatal error:.*in Unknown on line 0|exited on signal|exit signal|segfault|SIGSEGV|SIGBUS|SIGABRT|upstream prematurely|recv\(\) failed \(104|exit code (70|137)|execution timed out'

CURSOR_FILE=$P2S_STATE_DIR/docker_cursors.tsv

# _cursor_get <container> -> "<timestamp>\t<seq>"; chưa có thì "\t0".
_cursor_get() {
  local c=$1
  if [[ -r $CURSOR_FILE ]]; then
    awk -F'\t' -v c="$c" '$1 == c { printf "%s\t%s", $2, $3; f=1; exit }
                          END { if (!f) printf "\t0" }' "$CURSOR_FILE"
  else
    printf '\t0'
  fi
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

have docker || exit 0
docker ps --format '{{.Names}}' 2>/dev/null |
while IFS= read -r c; do
  [[ -z $c ]] && continue
  IFS=$'\t' read -r cur_ts cur_seq <<<"$(_cursor_get "$c")"
  [[ -n ${cur_seq:-} ]] || cur_seq=0
  # --since nhận RFC3339 tới giây; phần lẻ nano do bộ lọc bên dưới xử lý.
  since=${cur_ts:+${cur_ts%%.*}}
  since=${since:-${DOCKER_LOG_SINCE:-10m}}

  new_ts=$cur_ts
  new_seq=$cur_seq
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
    [[ $body =~ $DOCKER_RE ]] || continue
    new_seq=$((new_seq + 1))
    [[ -n $ts ]] && new_ts=$ts
    # ts_utc lấy từ chính dòng log, không phải giờ chạy batch: alert phải chỉ
    # đúng lúc sự việc xảy ra.
    P2S_TS=${ts:-$(utc_now)}; export P2S_TS
    emit_record docker "docker:$c" "$new_seq" "" "" "" "" "" "" "[$c] $body" "-"
  done < <(docker logs --timestamps --since "$since" "$c" 2>&1)

  if [[ $new_ts != "$cur_ts" || $new_seq -gt $cur_seq ]]; then
    _cursor_set "$c" "${new_ts:-}" "$new_seq"
  fi
done
