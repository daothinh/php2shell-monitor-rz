#!/usr/bin/env bash
# p2s-agent.sh — agent đẩy alert php2shell-monitor về Central Alert Server.
#
# Luồng:
#   1. pair : xin mã ghép nối -> in ra terminal -> user gửi mã cho bot Telegram
#             -> agent poll tới khi linked -> lưu api_key vào file conf (0600)
#   2. run  : tail file alert JSONL của monitor (mặc định
#             /var/lib/php2shell/projects/<project>/devices/<device>/alerts/queue.jsonl),
#             batch và POST về server; lỗi mạng -> spool đĩa, thử lại ở chu kỳ sau
#   3. test : gửi một alert thử để kiểm tra đường truyền sau khi ghép nối
#
# Dependencies: bash 4+, curl, coreutils. jq (nếu có) dùng parse JSON.
set -u

CONF_PATH=${P2S_AGENT_CONF:-/etc/php2shell/agent.conf}
STATE_DIR=${P2S_AGENT_STATE:-/var/lib/php2shell-agent}
# Default queue of the monitor on this host. The monitor stores per
# project/device; set P2S_ALERT_FILE when the project/device name differs.
ALERT_FILE=${P2S_ALERT_FILE:-/var/lib/php2shell/projects/default/devices/$(hostname 2>/dev/null || echo unknown)/alerts/queue.jsonl}
POLL_INTERVAL=${P2S_AGENT_POLL:-5}
BATCH_MAX=20
PAIR_TIMEOUT=900          # 15 phút
CURL=(curl -sS --connect-timeout 10 --max-time 30)

PROG=$(basename "$0")

die() { printf '%s: lỗi: %s\n' "$PROG" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# LAN IP of this host: source address of the default route, then the first
# global IPv4 from `ip -4 addr`, then `hostname -I`. Never loopback, and never
# `hostname -i` (reverse DNS can block for minutes on a host without a resolver).
lan_ip() {
  local ip
  if have ip; then
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)
    [[ -n $ip ]] || ip=$(ip -4 -o addr show scope global 2>/dev/null |
      awk '{ sub(/\/.*/, "", $4); if ($4 !~ /^127\./) { print $4; exit } }')
  fi
  [[ -n $ip ]] || ip=$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '/^[0-9]+\./ && !/^127\./ { print; exit }')
  [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || ip=""
  printf '%s' "$ip"
}

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
  $PROG pair   --server <url-central-server> [--chatid <chat-id-telegram>]
  $PROG run    [--file <alerts.jsonl>]
  $PROG test

pair sẽ HỎI Chat ID Telegram (hoặc nhận qua --chatid / P2S_TG_CHATID).
Lấy Chat ID: nhắn /id cho bot (trong chat riêng HOẶC group — group để cả
team cùng nhận alert). Sau đó chỉ cần nhắn /confirm trong chat đó.

Tên dự án gửi lên server lấy từ P2S_PROJECT_NAME (mặc định: hostname).

Biến môi trường (ghi đè mặc định):
  P2S_AGENT_CONF=$CONF_PATH
  P2S_AGENT_STATE=$STATE_DIR
  P2S_TG_CHATID=<chat id Telegram>
  P2S_ALERT_FILE=<queue.jsonl> (mặc định: /var/lib/php2shell/projects/default/devices/<host>/alerts/queue.jsonl)
  P2S_AGENT_POLL=$POLL_INTERVAL (giây)
EOF
}

# ============================================================ pair
cmd_pair() {
  local server= chatid=
  while [[ $# -gt 0 ]]; do
    case $1 in
      --server) server=${2:?}; shift 2 ;;
      --chatid) chatid=${2:?}; shift 2 ;;
      *) die "tham số không hợp lệ: $1 (xem $PROG help)" ;;
    esac
  done
  [[ $server =~ ^https?:// ]] || die "--server phải là URL http(s)://..."

  # Chat ID: --chatid > P2S_TG_CHATID > prompt tương tác
  chatid=${chatid:-${P2S_TG_CHATID:-}}
  if [[ -z $chatid ]]; then
    cat >&2 <<'EOF'
Lấy Chat ID: mở Telegram → vào bot → nhắn /id → bot trả Chat ID
(chat riêng: số dương; group: số âm — dùng group để cả team nhận alert).
EOF
    printf 'Nhập Chat ID Telegram: '
    IFS= read -r chatid || die "không đọc được input — dùng --chatid <chat_id>"
  fi
  chatid=$(printf '%s' "$chatid" | tr -d ' ')
  [[ $chatid =~ ^-?[1-9][0-9]{2,14}$ ]] \
    || die "Chat ID không hợp lệ: '$chatid' (ví dụ: 8005354626 hoặc -1001234567890)"

  local resp pair_ref name warn
  name=${P2S_PROJECT_NAME:-$(hostname 2>/dev/null || echo unknown)}
  resp=$("${CURL[@]}" -X POST "$server/api/v1/register-chatid" \
    -H 'Content-Type: application/json' \
    -d "{\"project_name\":\"$(json_escape "$name")\",\"chat_id\":\"$(json_escape "$chatid")\"}") \
    || die "không gọi được $server"
  pair_ref=$(json_get "$resp" pair_ref)
  [[ -n $pair_ref ]] || die "server trả về không có pair_ref: $resp"
  warn=$(json_get "$resp" warning)
  [[ -n $warn && $warn != null ]] && printf '⚠️  %s\n' "$warn"

  cat <<EOF

==============================================================
   GHÉP NỐI QUA TELEGRAM CHAT ID:   $chatid
==============================================================
 1. Mở Telegram vào CHAT có ID $chatid
    (bot đã vừa gửi yêu cầu ghép nối vào đó)
 2. Nhắn:   /confirm
 3. Bot trả lời "Ghép nối thành công" là xong.
    → KHÔNG cần gõ mã nào.

 Đang chờ /confirm (tối đa $((PAIR_TIMEOUT / 60)) phút)...
==============================================================

EOF

  local i st status api_key
  for ((i = 0; i < PAIR_TIMEOUT; i += 3)); do
    sleep 3
    if ! st=$("${CURL[@]}" "$server/api/v1/pairing-status?code=$pair_ref"); then
      printf '  (chờ lại — không gọi được server)\n' >&2
      continue
    fi
    status=$(json_get "$st" status)
    if [[ $status == linked ]]; then
      api_key=$(json_get "$st" api_key)
      [[ -n $api_key ]] || continue   # hết cửa sổ reveal -> poll tiếp vô ích
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

# Device name: derived from the monitor's data layout
# (<workdir>/projects/<project>/devices/<device>/alerts/queue.jsonl) when the
# path matches, otherwise the hostname.
device_name() {
  local d
  d=$(printf '%s' "$ALERT_FILE" | sed -n 's#.*/projects/[^/]*/devices/\([^/]*\)/alerts/.*#\1#p')
  printf '%s' "${d:-$(hostname 2>/dev/null || echo unknown)}"
}

post_alerts() { # các dòng JSON làm tham số -> 0 nếu server nhận
  local payload
  # The monitor names its own device; fall back to the hostname. Host + LAN IP
  # + user are sent so the central store can attribute and locate the box.
  payload=$(printf '{"host":"%s","device":"%s","lan_ip":"%s","user":"%s","alerts":[%s]}' \
    "$(json_escape "$(hostname 2>/dev/null || echo unknown)")" \
    "$(json_escape "$(device_name)")" \
    "$(json_escape "$(lan_ip)")" \
    "$(json_escape "$(id -un 2>/dev/null || echo unknown)")" \
    "$(printf '%s\n' "$@" | paste -sd, -)")
  "${CURL[@]}" -X POST "$SERVER_URL/api/v1/ingest-log" \
    -H "X-API-Key: $API_KEY" -H 'Content-Type: application/json' \
    --data "$payload" >/dev/null
}

# Đọc dòng mới hoàn chỉnh từ $ALERT_FILE; aware-rotation theo inode.
# An toàn khi file đang được ghi cùng lúc (scan append từng dòng): chỉ tiêu thụ
# đúng số byte đã stat, và nếu dòng cuối chưa có \n thì bỏ cả dòng đó lại cho chu kỳ sau.
# Sets: NEW_LINES (array), NEW_POS, NEW_INO.
read_new() {
  NEW_LINES=()
  NEW_POS=${NEW_POS:-0}
  NEW_INO=${NEW_INO:-0}
  [[ -r $ALERT_FILE && -f $ALERT_FILE ]] || return 0
  local ino size pos=0 oino opos
  ino=$(stat -c %i -- "$ALERT_FILE" 2>/dev/null) || return 0
  size=$(stat -c %s -- "$ALERT_FILE" 2>/dev/null) || return 0
  if [[ -s $STATE_DIR/offset ]]; then
    { IFS=$'\t' read -r oino opos || true; } <"$STATE_DIR/offset"
    [[ ${oino:-} == "$ino" ]] && pos=${opos:-0}
  fi
  (( pos <= size )) || pos=0
  (( size > pos )) || { NEW_POS=$pos; NEW_INO=$ino; return 0; }

  local tmp chunk_len
  tmp=$(mktemp)
  chunk_len=$((size - pos))
  # head -c giới hạn đúng số byte đã stat: phần append SAU lúc stat chờ chu kỳ sau
  tail -c +"$((pos + 1))" -- "$ALERT_FILE" 2>/dev/null | head -c "$chunk_len" >"$tmp"
  mapfile -t _lines <"$tmp"
  rm -f -- "$tmp"
  if (( chunk_len > 0 )) && [[ $(tail -c1 -- "$ALERT_FILE" 2>/dev/null | wc -l) -eq 0 ]]; then
    # file chưa kết thúc bằng \n = dòng cuối đang ghi dở -> để lại cho chu kỳ sau
    if ((${#_lines[@]})); then
      local last LC_ALL=C
      last=${_lines[-1]}
      chunk_len=$((chunk_len - ${#last}))   # ${#last} đếm BYTE vì LC_ALL=C
      unset '_lines[${#_lines[@]}-1]'
    fi
  fi
  local line
  for line in "${_lines[@]}"; do
    line=${line%$'\r'}
    [[ $line == \{* && $line == *\} ]] && NEW_LINES+=("$line")
  done
  NEW_POS=$((pos + chunk_len))
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
  payload=$(printf '{"host":"%s","lan_ip":"%s","user":"%s","alerts":[{"ts_utc":"%s","rule_id":"TEST-001","severity":"INFO","tier":"TEST","message":"Alert thử từ %s — đường truyền ghép nối hoạt động!"}]}' \
    "$(json_escape "$(hostname 2>/dev/null || echo unknown)")" \
    "$(json_escape "$(lan_ip)")" \
    "$(json_escape "$(id -un 2>/dev/null || echo unknown)")" \
    "$ts" "$PROG")
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
