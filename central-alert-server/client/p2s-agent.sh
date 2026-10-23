#!/usr/bin/env bash
# p2s-agent.sh — agent đẩy alert php2shell-monitor về Central Alert Server.
#
# Luồng:
#   1. pair : xin mã ghép nối -> in ra terminal -> user gửi mã cho bot Telegram
#             -> agent poll tới khi linked -> lưu api_key vào file conf (0600)
#   2. run  : tail file alert JSONL của monitor (mặc định
#             /tmp/php2shell-monitor/alerts/queue.jsonl), batch và POST về
#             server; lỗi mạng -> spool đĩa, thử lại ở chu kỳ sau
#   3. test : gửi một alert thử để kiểm tra đường truyền sau khi ghép nối
#
# Dependencies: bash 4+, curl, coreutils. jq (nếu có) dùng parse JSON.
set -u

CONF_PATH=${P2S_AGENT_CONF:-/etc/php2shell/agent.conf}
STATE_DIR=${P2S_AGENT_STATE:-/var/lib/php2shell-agent}
ALERT_FILE=${P2S_ALERT_FILE:-/tmp/php2shell-monitor/alerts/queue.jsonl}
POLL_INTERVAL=${P2S_AGENT_POLL:-5}
BATCH_MAX=20
PAIR_TIMEOUT=900          # 15 phút
CURL=(curl -sS --connect-timeout 10 --max-time 30)

PROG=$(basename "$0")

die() { printf '%s: lỗi: %s\n' "$PROG" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# json_get <json> <key> — jq nếu có, fallback grep (đủ dùng với JSON phẳng của server)
json_get() {
  local j=$1 k=$2
  if have jq; then
    jq -r --arg k "$k" '.[$k] // empty' <<<"$j" 2>/dev/null
  else
    grep -oP "\"$k\"\s*:\s*\"\K[^\"]*" <<<"$j" 2>/dev/null | head -1
  fi
}

json_escape() { # chuỗi -> chuỗi JSON an toàn (không có dấu " \ và control)
  local s=${1-}
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\t'/ }; s=${s//$'\n'/ }; s=${s//$'\r'/ }
  printf '%s' "$s"
}

usage() {
  cat <<EOF
$PROG — agent Central Alert Server cho php2shell-monitor

Usage:
  $PROG pair   --name <tên-dự-án> --server <url-central-server>
  $PROG run    [--file <alerts.jsonl>]
  $PROG test

Biến môi trường (ghi đè mặc định):
  P2S_AGENT_CONF=$CONF_PATH
  P2S_AGENT_STATE=$STATE_DIR
  P2S_ALERT_FILE=$ALERT_FILE
  P2S_AGENT_POLL=$POLL_INTERVAL (giây)
EOF
}

# ============================================================ pair
cmd_pair() {
  local server= name=
  while [[ $# -gt 0 ]]; do
    case $1 in
      --name)   name=${2:?}; shift 2 ;;
      --server) server=${2:?}; shift 2 ;;
      *) die "tham số không hợp lệ: $1 (xem $PROG help)" ;;
    esac
  done
  [[ $server =~ ^https?:// ]] || die "--server phải là URL http(s)://..."
  [[ $name =~ ^[A-Za-z0-9._@-]{1,64}$ ]] || die "--name 1-64 ký tự (chữ/số/._-@)"

  local resp code
  resp=$("${CURL[@]}" -X POST "$server/api/v1/register-pairing" \
    -H 'Content-Type: application/json' \
    -d "{\"project_name\":\"$(json_escape "$name")\"}") || die "không gọi được $server"
  code=$(json_get "$resp" code)
  [[ -n $code ]] || die "server trả về không có mã: $resp"

  cat <<EOF

==============================================================
   MÃ GHÉP NỐI TELEGRAM:   $code
==============================================================
 1. Mở Telegram, tìm bot của hệ thống (do quản trị viên cung cấp)
 2. Nhắn đúng nội dung:   $code
 3. Bot trả lời "Ghép nối thành công" là xong.

 Đang chờ ghép nối (tối đa $((PAIR_TIMEOUT / 60)) phút)...
==============================================================

EOF

  local i st status api_key
  for ((i = 0; i < PAIR_TIMEOUT; i += 3)); do
    sleep 3
    if ! st=$("${CURL[@]}" "$server/api/v1/pairing-status?code=$code"); then
      printf '  (chờ lại — không gọi được server)\n' >&2
      continue
    fi
    status=$(json_get "$st" status)
    if [[ $status == linked ]]; then
      api_key=$(json_get "$st" api_key)
      [[ -n $api_key ]] || continue   # đã linked nhưng hết cửa sổ lấy key ->.poll tiếp vô ích
      mkdir -p -- "$(dirname -- "$CONF_PATH")"
      (umask 077 && printf 'SERVER_URL=%q\nAPI_KEY=%q\nPROJECT_NAME=%q\n' \
        "$server" "$api_key" "$name" >"$CONF_PATH")
      printf '✅ Ghép nối thành công! Cấu hình đã lưu: %s\n' "$CONF_PATH"
      printf 'Kiểm tra đường truyền:  %s test\nBắt đầu đẩy alert:      %s run\n' "$PROG" "$PROG"
      return 0
    fi
  done
  die "hết thời gian chờ ghép nối — chạy lại lệnh pair để lấy mã mới"
}

# ============================================================ helpers run
load_conf() {
  [[ -r $CONF_PATH ]] || die "chưa có cấu hình $CONF_PATH — chạy '$PROG pair' trước"
  # shellcheck disable=SC1090
  source "$CONF_PATH"
  [[ ${SERVER_URL:-} =~ ^https?:// ]] || die "SERVER_URL trong conf không hợp lệ"
  [[ -n ${API_KEY:-} ]] || die "API_KEY trống trong conf — ghép nối lại"
}

post_alerts() { # các dòng JSON làm tham số -> 0 nếu server nhận
  local payload
  payload=$(printf '{"host":"%s","alerts":[%s]}' \
    "$(json_escape "$(hostname 2>/dev/null || echo unknown)")" \
    "$(printf '%s\n' "$@" | paste -sd, -)")
  "${CURL[@]}" -X POST "$SERVER_URL/api/v1/ingest-log" \
    -H "X-API-Key: $API_KEY" -H 'Content-Type: application/json' \
    --data "$payload" >/dev/null
}

# Đọc dòng mới hoàn chỉnh từ $ALERT_FILE; aware-rotation theo inode.
# Sets: NEW_LINES (array), NEW_POS, NEW_INO.
read_new() {
  NEW_LINES=()
  [[ -r $ALERT_FILE ]] && [[ -f $ALERT_FILE ]] || return 0
  local ino size pos=0 oino opos
  ino=$(stat -c %i -- "$ALERT_FILE" 2>/dev/null) || return 0
  size=$(stat -c %s -- "$ALERT_FILE" 2>/dev/null) || return 0
  if [[ -s $STATE_DIR/offset ]]; then
    { IFS=$'\t' read -r oino opos || true; } <"$STATE_DIR/offset"
    [[ ${oino:-} == "$ino" ]] && pos=${opos:-0}
  fi
  (( size > pos )) || { NEW_POS=$pos; NEW_INO=$ino; return 0; }
  local tmp complete
  tmp=$(mktemp)
  tail -c +"$((pos + 1))" -- "$ALERT_FILE" >"$tmp" 2>/dev/null
  if [[ $(tail -c1 -- "$tmp" 2>/dev/null | wc -l) -eq 0 ]]; then
    complete=$(awk '{n += length($0) + 1} END {print n - 1}' "$tmp" 2>/dev/null)
    [[ ${complete:-0} -gt 0 ]] || { rm -f -- "$tmp"; NEW_POS=$pos; NEW_INO=$ino; return 0; }
    head -c "$complete" -- "$tmp" >"$tmp.2" && mv -f -- "$tmp.2" "$tmp"
  else
    complete=$size
  fi
  local line
  while IFS= read -r line; do
    line=${line%$'\r'}
    [[ $line == \{* && $line == *\} ]] || continue   # chỉ nhận dòng JSON
    NEW_LINES+=("$line")
  done <"$tmp"
  rm -f -- "$tmp"
  NEW_POS=$((pos + complete))
  NEW_INO=$ino
}

save_offset() { # <inode> <pos>
  mkdir -p -- "$STATE_DIR"
  printf '%s\t%s\n' "$1" "$2" >"$STATE_DIR/offset"
}

spool_append() { # các dòng JSON
  local f=$STATE_DIR/spool/pending.jsonl
  mkdir -p -- "$STATE_DIR/spool"
  printf '%s\n' "$@" >>"$f"
}

# Gửi spool trước (FIFO). Thành công -> xoá đúng số dòng đã gửi.
drain_spool() {
  local f=$STATE_DIR/spool/pending.jsonl
  [[ -s $f ]] || return 0
  local n batch
  n=$(wc -l <"$f")
  (( n > BATCH_MAX )) && n=$BATCH_MAX
  mapfile -t batch < <(head -n "$n" -- "$f")
  if post_alerts "${batch[@]}"; then
    tail -n +"$((n + 1))" -- "$f" >"$f.2" && mv -f -- "$f.2" "$f"
    printf '%s: đã gửi %d alert từ spool\n' "$PROG" "$n"
  fi
}

# ============================================================ run
cmd_run() {
  load_conf
  while [[ $# -gt 0 ]]; do
    case $1 in
      --file) ALERT_FILE=${2:?}; shift 2 ;;
      *) die "tham số không hợp lệ: $1" ;;
    esac
  done
  printf '%s: bắt đầu chạy — server=%s file=%s\n' "$PROG" "$SERVER_URL" "$ALERT_FILE"
  printf '%s: Ctrl+C để dừng\n\n' "$PROG"
  trap 'printf "\n%s: dừng\n" "$PROG"; exit 0' INT TERM
  while true; do
    drain_spool || true
    read_new
    if ((${#NEW_LINES[@]})); then
      local sent=0
      while ((sent < ${#NEW_LINES[@]})); do
        local -a part=("${NEW_LINES[@]:sent:BATCH_MAX}")
        if post_alerts "${part[@]}"; then
          sent=$((sent + ${#part[@]}))
        else
          spool_append "${NEW_LINES[@]:sent}"
          printf '%s: mạng lỗi — spool %d alert, thử lại sau\n' \
            "$PROG" $((${#NEW_LINES[@]} - sent)) >&2
          break
        fi
      done
      save_offset "$NEW_INO" "$NEW_POS"   # luôn tiến offset; chưa gửi nằm trong spool
    fi
    sleep "$POLL_INTERVAL"
  done
}

# ============================================================ test
cmd_test() {
  load_conf
  local ts payload resp
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  payload=$(printf '{"host":"%s","alerts":[{"ts_utc":"%s","rule_id":"TEST-001","severity":"INFO","tier":"TEST","message":"Alert thử từ %s — đường truyền ghép nối hoạt động!"}]}' \
    "$(json_escape "$(hostname 2>/dev/null || echo unknown)")" "$ts" "$PROG")
  resp=$(curl -sS --connect-timeout 10 --max-time 30 -X POST \
    "$SERVER_URL/api/v1/ingest-log" \
    -H "X-API-Key: $API_KEY" -H 'Content-Type: application/json' \
    --data "$payload") || die "không gọi được $SERVER_URL"
  printf 'Phản hồi server: %s\n' "$resp"
  printf 'Nếu delivered >= 1, hãy kiểm tra Telegram — alert thử phải xuất hiện.\n'
}

# ============================================================ main
case ${1:-help} in
  pair) shift; cmd_pair "$@" ;;
  run)  shift; cmd_run "$@" ;;
  test) shift; cmd_test "$@" ;;
  help|-h|--help) usage ;;
  *) die "mode không hợp lệ: $1 (pair | run | test)" ;;
esac
