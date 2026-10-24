#!/usr/bin/env bash
# central.sh - Central Alert Server integration: pair once, forward alerts.
#
#   central.sh pair  --server <url> [--detach]
#     Asks the central server for a pairing code (for the PROJECT already set
#     in conf/device.conf), prints it, waits until the operator sends the code
#     to the Telegram bot, then stores the API key in conf/central.conf (0600).
#
#   central.sh agent
#     Long-running forwarder: tails <device>/alerts/queue.jsonl (inode+byte
#     offset, spool on network loss) and POSTs to /api/v1/ingest-log. Started
#     automatically by supervisor.sh when conf/central.conf exists; flock keeps
#     it a singleton.
#
#   central.sh test
#     Sends one INFO test alert; the reply must show delivered >= 1.
#
# Everything is stored under WORKDIR (conf/central.conf, <device>/run/agent/):
# no /etc, no /var, nothing outside the install directory. Credentials are only
# the API key; the server keeps the Telegram chat_id on its side.
set -u
WORKDIR=${WORKDIR:-/opt/php2shell-monitor}
# shellcheck source=/dev/null
source "$WORKDIR/lib/common.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/paths.sh"

CONF_PATH=$WORKDIR/conf/central.conf
POLL_INTERVAL=${P2S_AGENT_POLL:-5}
BATCH_MAX=20
PAIR_TIMEOUT=900          # 15 phút
CURL=(curl -sS --connect-timeout 10 --max-time 30)

die() { printf 'php2shell-monitor: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

reinit_device() { # (re)compute device paths — also called after conf changes
  # shellcheck disable=SC2034  # vars are read by p2s_device_init & callers
  P2S_DATA_DIR='' P2S_ALERT_DIR='' P2S_EVIDENCE_DIR='' P2S_STATE_DIR='' P2S_DEVICE_RUN_DIR=''
  p2s_device_init || die "cannot initialise data dirs under $WORKDIR"
}
reinit_device

# LAN IP: source address of the default route, then first global IPv4, then
# `hostname -I`. Never loopback; never `hostname -i` (reverse DNS can block).
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

# json_get <json> <key> — jq nếu có, fallback grep (đủ với JSON phẳng của server)
json_get() {
  local j=$1 k=$2
  if [[ -n ${P2S_JQ:-} ]]; then
    "$P2S_JQ" -r --arg k "$k" '.[$k] // empty' <<<"$j" 2>/dev/null
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

load_conf() {
  [[ -r $CONF_PATH ]] || die "chưa ghép nối — chạy: sudo bash php2shell-monitor.sh -- pair --server <url>"
  # shellcheck disable=SC1090
  source "$CONF_PATH"
  [[ ${SERVER_URL:-} =~ ^https?:// ]] || die "SERVER_URL trong conf không hợp lệ"
  [[ -n ${API_KEY:-} ]] || die "API_KEY trống trong conf — chạy pair lại"
}

supervisor_pid() { cat "$P2S_DEVICE_RUN_DIR/supervisor.pid" 2>/dev/null || echo 0; }

start_agent() { # spawn the forwarder unless it is already running
  local pid
  pid=$(cat "$P2S_DEVICE_RUN_DIR/agent/agent.pid" 2>/dev/null ||
        cat "$P2S_DEVICE_RUN_DIR/agent.pid" 2>/dev/null || echo 0)
  if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  (umask 077 && mkdir -p -- "$P2S_DEVICE_RUN_DIR")
  setsid bash "$WORKDIR/engine/central.sh" agent \
    >>"$P2S_DEVICE_RUN_DIR/agent.log" 2>&1 &
}

# ============================================================ pair
cmd_pair() {
  local server= detach=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --server) server=${2:?}; shift 2 ;;
      --detach) detach=1; shift ;;
      *) die "tham số không hợp lệ: $1 (pair --server <url>)" ;;
    esac
  done
  [[ $server =~ ^https?:// ]] || die "--server phải là URL http(s)://..."
  local proj=$PROJECT

  local resp code
  resp=$("${CURL[@]}" -X POST "$server/api/v1/register-pairing" \
    -H 'Content-Type: application/json' \
    -d "{\"project_name\":\"$(json_escape "$proj")\"}") || die "không gọi được $server"
  code=$(json_get "$resp" code)
  [[ -n $code ]] || die "server trả về không có mã: $resp"

  cat <<EOF

==============================================================
   DỰ ÁN:  $proj  (device: $DEVICE)
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
      [[ -n $api_key ]] || continue   # đã linked nhưng hết cửa sổ lấy key
      (umask 077 && printf 'SERVER_URL=%q\nAPI_KEY=%q\nPROJECT_NAME=%q\n' \
        "$server" "$api_key" "$proj" >"$CONF_PATH")
      printf '✅ Ghép nối thành công! Cấu hình đã lưu: %s\n' "$CONF_PATH"
      if ((detach)) || { [[ $(supervisor_pid) =~ ^[0-9]+$ ]] && \
                         kill -0 "$(supervisor_pid)" 2>/dev/null; }; then
        start_agent
        printf 'Agent đẩy alert đã chạy — log: %s/agent.log\n' "$P2S_DEVICE_RUN_DIR"
      else
        printf 'Bật forwarding:   sudo bash php2shell-monitor.sh -- run\n'
      fi
      printf 'Kiểm tra Telegram: sudo bash php2shell-monitor.sh -- test\n'
      return 0
    fi
  done
  die "hết thời gian chờ ghép nối — chạy lại lệnh pair để lấy mã mới"
}

# ============================================================ forwarder
post_alerts() { # các dòng JSON làm tham số -> 0 nếu server nhận
  local payload
  payload=$(printf '{"host":"%s","device":"%s","lan_ip":"%s","user":"%s","alerts":[%s]}' \
    "$(json_escape "$(hostname 2>/dev/null || echo unknown)")" \
    "$(json_escape "$DEVICE")" \
    "$(json_escape "$(lan_ip)")" \
    "$(json_escape "$(id -un 2>/dev/null || echo unknown)")" \
    "$(printf '%s\n' "$@" | paste -sd, -)")
  "${CURL[@]}" -X POST "$SERVER_URL/api/v1/ingest-log" \
    -H "X-API-Key: $API_KEY" -H 'Content-Type: application/json' \
    --data "$payload" >/dev/null
}

# Đọc dòng mới hoàn chỉnh từ $ALERT_FILE; rotation-aware theo inode.
# Chỉ tiêu thụ đúng số byte đã stat; dòng cuối chưa có \n để lại cho chu kỳ sau.
# Sets: NEW_LINES (array), NEW_POS, NEW_INO.
read_new() {
  NEW_LINES=()
  NEW_POS=${NEW_POS:-0}
  NEW_INO=${NEW_INO:-0}
  local alert_file=$P2S_ALERT_DIR/queue.jsonl
  [[ -r $alert_file && -f $alert_file ]] || return 0
  local ino size pos=0 oino opos
  ino=$(stat -c %i -- "$alert_file" 2>/dev/null) || return 0
  size=$(stat -c %s -- "$alert_file" 2>/dev/null) || return 0
  if [[ -s $STATE_DIR/offset ]]; then
    { IFS=$'\t' read -r oino opos || true; } <"$STATE_DIR/offset"
    [[ ${oino:-} == "$ino" ]] && pos=${opos:-0}
  fi
  (( pos <= size )) || pos=0
  (( size > pos )) || { NEW_POS=$pos; NEW_INO=$ino; return 0; }

  local tmp chunk_len
  tmp=$P2S_TMP_DIR/agent-tail.$$
  chunk_len=$((size - pos))
  tail -c +"$((pos + 1))" -- "$alert_file" 2>/dev/null | head -c "$chunk_len" >"$tmp"
  mapfile -t _lines <"$tmp"
  rm -f -- "$tmp"
  if (( chunk_len > 0 )) && [[ $(tail -c1 -- "$alert_file" 2>/dev/null | wc -l) -eq 0 ]]; then
    if ((${#_lines[@]})); then
      local last
      last=${_lines[-1]}
      LC_ALL=C   # ${#last} must count BYTES to match tail -c offsets
      chunk_len=$((chunk_len - ${#last}))
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

drain_spool() { # gửi spool trước (FIFO); thành công -> xoá đúng số dòng đã gửi
  local f=$STATE_DIR/spool/pending.jsonl
  [[ -s $f ]] || return 0
  local n batch
  n=$(wc -l <"$f")
  (( n > BATCH_MAX )) && n=$BATCH_MAX
  mapfile -t batch < <(head -n "$n" -- "$f")
  if post_alerts "${batch[@]}"; then
    tail -n +"$((n + 1))" -- "$f" >"$f.2" && mv -f -- "$f.2" "$f"
    printf '%s: đã gửi %d alert từ spool\n' "$P2S_PROG" "$n"
  fi
}

cmd_agent() {
  load_conf
  STATE_DIR=$P2S_DEVICE_RUN_DIR/agent
  mkdir -p -- "$STATE_DIR"
  # singleton: supervisor cũng tự bật agent khi có conf; lần sau thoát im lặng
  exec 9>"$STATE_DIR/agent.lock"
  flock -n 9 || exit 0
  echo $$ >"$STATE_DIR/agent.pid"
  printf '%s: forwarding %s -> %s (project %s, device %s)\n' \
    "$P2S_PROG" "$P2S_ALERT_DIR/queue.jsonl" "$SERVER_URL" "$PROJECT" "$DEVICE"
  trap 'printf "\n%s: agent dừng\n" "$P2S_PROG"; exit 0' INT TERM
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
            "$P2S_PROG" $((${#NEW_LINES[@]} - sent)) >&2
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
  ts=$(utc_now)
  payload=$(printf '{"host":"%s","lan_ip":"%s","user":"%s","alerts":[{"ts_utc":"%s","rule_id":"TEST-001","severity":"INFO","tier":"TEST","message":"Alert thử từ php2shell-monitor (%s) — đường truyền ghép nối hoạt động!"}]}' \
    "$(json_escape "$(hostname 2>/dev/null || echo unknown)")" \
    "$(json_escape "$(lan_ip)")" \
    "$(json_escape "$(id -un 2>/dev/null || echo unknown)")" \
    "$ts" "$DEVICE")
  resp=$("${CURL[@]}" -X POST "$SERVER_URL/api/v1/ingest-log" \
    -H "X-API-Key: $API_KEY" -H 'Content-Type: application/json' \
    --data "$payload") || die "không gọi được $SERVER_URL"
  printf 'Phản hồi server: %s\n' "$resp"
  printf 'Nếu delivered >= 1, hãy kiểm tra Telegram — alert thử phải xuất hiện.\n'
}

case ${1:-help} in
  pair)  shift; cmd_pair "$@" ;;
  agent) cmd_agent ;;
  test)  cmd_test ;;
  *) die "central.sh {pair --server <url>} | agent | test" ;;
esac
