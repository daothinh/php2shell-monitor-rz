#!/usr/bin/env bash
# p2s-agent.sh — agent đẩy alert php2shell-monitor về Central Alert Server.
#
# Luồng:
#   1. ghép nối (mặc định) : đăng ký theo Chat ID Telegram (tự động, không /confirm)
#             -> nhận api_key ngay -> lưu file conf (0600)
#   2. run  : tail file alert JSONL của monitor (mặc định
#             /var/lib/php2shell/projects/<project>/devices/<device>/alerts/queue.jsonl),
#             batch và POST về server; lỗi mạng -> spool đĩa, thử lại ở chu kỳ sau
#   3. test : gửi một alert thử để kiểm tra đường truyền sau khi ghép nối
#
# Dependencies: bash 4+, curl, coreutils. jq (nếu có) dùng parse JSON.
set -u

CONF_PATH=${P2S_AGENT_CONF:-/etc/php2shell/agent.conf}
STATE_DIR=${P2S_AGENT_STATE:-/var/lib/php2shell-agent}
# KHÔNG có central server mặc định: ghép nối bắt buộc --server (hoặc P2S_SERVER_URL).
# Không hardcode IP nào trong script — mỗi môi trường tự chỉ định server.
# Default queue of the monitor on this host. The monitor stores per
# project/device; set P2S_ALERT_FILE when the project/device name differs.
# Queue của monitor: suy ra từ PROJECT_NAME (conf) + hostname (thiết bị).
# P2S_ALERT_FILE ghi đè hoàn toàn khi cần trỏ file khác.
ALERT_FILE=${P2S_ALERT_FILE:-}
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

GHÉP NỐI (mặc định — không cần chữ "pair"):
  $PROG --server <url> --project <tên-dự-án> --chatid <chat-id>

  Cả 3 tham số BẮT BUỘC, không có giá trị mặc định:
    --server   URL central server, ví dụ http://192.168.22.191:8000
    --project  tên dự án khách hàng, ví dụ khach-hang-A
               (hostname là thông tin THIẾT BỊ, không phải tên dự án)
    --chatid   Chat ID Telegram: nhắn /id cho bot để lấy
               (chat riêng: số dương; group: số âm)

  Ghép nối TỰ ĐỘNG ngay khi chạy — không cần /confirm. Mỗi lần chạy cấp
  một API key riêng cho thiết bị này (key cũ vẫn sống).

LỆNH KHÁC:
  $PROG test
  $PROG run  [--file <alerts.jsonl>]
  $PROG help

Biến môi trường (dùng thay tham số khi chạy automation):
  P2S_SERVER_URL=<url central server>
  P2S_PROJECT_NAME=<tên dự án>
  P2S_TG_CHATID=<chat id Telegram>
  P2S_AGENT_CONF=$CONF_PATH
  P2S_AGENT_STATE=$STATE_DIR
  P2S_ALERT_FILE=<queue.jsonl>
      (mặc định: /var/lib/php2shell/projects/<PROJECT_NAME>/devices/<hostname>/alerts/queue.jsonl)
  P2S_AGENT_POLL=$POLL_INTERVAL (giây)
EOF
}

# ============================================================ pair
# Bot hệ thống (hiển thị trong hướng dẫn); server có thể trả tên bot thật
# trong response của register-chatid và sẽ ghi đè giá trị này.
P2S_BOT=${P2S_BOT:-@p2shell_bot}

cmd_pair() {
  local server=${P2S_SERVER_URL:-} project=${P2S_PROJECT_NAME:-} chatid=${P2S_TG_CHATID:-}
  while [[ $# -gt 0 ]]; do
    case $1 in
      --server)  [[ $# -ge 2 && -n $2 ]] || die "--server cần giá trị URL"; server=$2; shift 2 ;;
      --project) [[ $# -ge 2 && -n $2 ]] || die "--project cần tên dự án"; project=$2; shift 2 ;;
      --chatid)  [[ $# -ge 2 && -n $2 ]] || die "--chatid cần Chat ID Telegram"; chatid=$2; shift 2 ;;
      *) die "tham số không hợp lệ: $1 (dùng: $PROG --server <url> --project <tên> --chatid <id>)" ;;
    esac
  done

  # ---------- bắt buộc đủ 3 tham số, không có mặc định ----------
  local missing=()
  [[ -n $server  ]] || missing+=(--server)
  [[ -n $project ]] || missing+=(--project)
  [[ -n $chatid  ]] || missing+=(--chatid)
  if (( ${#missing[@]} )); then
    die "thiếu tham số bắt buộc: ${missing[*]}
  $PROG --server <url> --project <tên-dự-án> --chatid <chat-id>
  Lấy Chat ID: nhắn /id cho bot Telegram (chat riêng: dương, group: âm)."
  fi

  [[ $server =~ ^https?:// ]] || die "--server phải là URL http(s)://..."
  project=$(printf '%s' "$project" | tr -d ' ')
  [[ $project =~ ^[A-Za-z0-9._-]{1,64}$ ]] \
    || die "--project không hợp lệ: chỉ A-Z a-z 0-9 . _ - (1-64 ký tự)"
  chatid=$(printf '%s' "$chatid" | tr -d ' ')
  [[ $chatid =~ ^-?[1-9][0-9]{2,14}$ ]] \
    || die "--chatid không hợp lệ: phải là số Telegram (chat riêng dương, group âm, ví dụ -1001234567890)"

  local bot=$P2S_BOT botlink="https://t.me/${P2S_BOT#@}" device
  device=$(hostname 2>/dev/null || echo unknown)   # hostname = THIẾT BỊ, không phải dự án

  printf '\n⏳ Đăng ký dự án "%s" (thiết bị %s) với %s ...\n' "$project" "$device" "$server"
  local resp pair_ref warn rbot
  resp=$("${CURL[@]}" -X POST "$server/api/v1/register-chatid" \
    -H 'Content-Type: application/json' \
    -d "{\"project_name\":\"$(json_escape "$project")\",\"chat_id\":\"$(json_escape "$chatid")\",\"device\":\"$(json_escape "$device")\"}") \
    || die "không gọi được $server — kiểm tra đường mạng/URL: $server"
  pair_ref=$(json_get "$resp" pair_ref)
  [[ -n $pair_ref ]] || die "server trả về không có pair_ref: $resp"
  rbot=$(json_get "$resp" bot)
  [[ -n $rbot && $rbot != null ]] && bot=$rbot && botlink="https://t.me/${rbot#@}"
  warn=$(json_get "$resp" warning)
  if [[ -n $warn && $warn != null ]]; then
    cat >&2 <<EOF

⚠️  Bot chưa nhắn được vào chat $chatid (chưa được START).
   Cách xử lý: mở $botlink → nhấn START (thêm bot vào group nếu là group).
   Dự án VẪN đã ghép nối và API key vẫn được cấp — nhưng alert chỉ tới
   sau khi bot nhắn được vào chat, nên hãy START trước.
EOF
  fi

  printf '\n⏳ Đang nhận API key (ghép nối TỰ ĐỘNG — không cần /confirm)...\n'

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
      (umask 077 && printf 'SERVER_URL=%q\nAPI_KEY=%q\nPROJECT_NAME=%q\nDEVICE=%q\n' \
        "$server" "$api_key" "$project" "$device" >"$CONF_PATH")
      cat <<EOF

╔══════════════════════════════════════════════════════════════╗
║   ✅  GHÉP NỐI THÀNH CÔNG!                                  ║
╚══════════════════════════════════════════════════════════════╝
 Dự án      :  $project
 Thiết bị    :  $device
 Chat nhận   :  $chatid
 Cấu hình    :  $CONF_PATH   (chỉ root đọc được)

 BƯỚC TIẾP THEO — kiểm tra & chạy thật:
   1) Gửi alert thử (xem Telegram có nhận không):
        $PROG test
   2) Chạy thường trực để đẩy alert tự động:
        sudo $PROG run
      hoặc cài service (khởi động cùng máy chủ):
        sudo cp p2s-agent.service /etc/systemd/system/
        sudo systemctl enable --now p2s-agent
   3) Trên Telegram, nhắn  /list  cho $bot để xem các dự án đang quản lý.
   4) Thêm THIẾT BỊ khác vào CÙNG dự án: chạy lại lệnh này trên máy đó
      với --project và --chatid giữ nguyên — tự động, không spam chat.
EOF
      return 0
    fi
    if (( (i + 3) % 30 == 0 )); then
      printf '  ... vẫn đang chờ server phản hồi (đã %d giây)\n' "$((i + 3))"
    fi
  done
  die "hết thời gian chờ server cấp key — chạy lại lệnh pair"
}

# ============================================================ helpers run
load_conf() {
  [[ -r $CONF_PATH ]] || die "chưa có cấu hình $CONF_PATH — ghép nối trước:
  $PROG --server <url> --project <tên-dự-án> --chatid <chat-id>"
  # shellcheck disable=SC1090
  source "$CONF_PATH"
  [[ ${SERVER_URL:-} =~ ^https?:// ]] || die "SERVER_URL trong conf không hợp lệ"
  [[ -n ${API_KEY:-} ]] || die "API_KEY trống trong conf — ghép nối lại"
  [[ -n ${PROJECT_NAME:-} ]] || die "PROJECT_NAME trống trong conf — ghép nối lại"
  # queue mặc định: <root>/projects/<PROJECT_NAME>/devices/<hostname>/alerts/queue.jsonl
  if [[ -z ${ALERT_FILE:-} ]]; then
    ALERT_FILE=/var/lib/php2shell/projects/$PROJECT_NAME/devices/$(hostname 2>/dev/null || echo unknown)/alerts/queue.jsonl
  fi
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

# upload_evidence <alert_json_line>
# Gửi file evidence của batch dạng gzip thô qua kênh riêng (/ingest-evidence).
# Alert chỉ mang metadata (evidence[] rỗng khi MAX_EVIDENCE_INLINE=0), nên đây là
# kênh duy nhất chở raw line lên server. Không có bước này thì mọi alert đều
# hiện "Event logs 0 nhóm" trên Telegram dù monitor phát hiện đúng.
upload_evidence() {
  local line=$1 batch evf
  batch=$(printf '%s' "$line" | sed -n 's/.*"batch_id":"\([^"]*\)".*/\1/p')
  evf=$(printf '%s' "$line" | sed -n 's/.*"evidence_file":"\([^"]*\)".*/\1/p')
  [[ -n $batch && -n $evf && -r $evf ]] || return 0
  local gz
  gz=$(mktemp)
  gzip -6 -c -- "$evf" >"$gz" || { rm -f -- "$gz"; return 1; }
  local rc=0
  "${CURL[@]}" --max-time 300 -X POST "$SERVER_URL/api/v1/ingest-evidence" \
    -H "X-API-Key: $API_KEY" \
    -H "X-Batch-Id: $batch" \
    -H "X-Hostname: $(hostname 2>/dev/null || echo unknown)" \
    -H "X-Lan-Ip: $(lan_ip)" \
    -H "X-User: $(id -un 2>/dev/null || echo unknown)" \
    -H 'Content-Type: application/gzip' \
    --data-binary "@$gz" >/dev/null || rc=$?
  rm -f -- "$gz"
  return $rc
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
    local _l
    for _l in "${batch[@]}"; do upload_evidence "$_l" || true; done
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
          # Evidence của từng batch phải lên server, nếu không alert đã tới mà
          # không có raw: server không dựng lại được preview[] và /search mù.
          # Agent này chạy được với monitor <= 1.4.2 vì alert cũ vẫn mang
          # evidence_file trỏ tới file local.
          local _l
          for _l in "${part[@]}"; do upload_evidence "$_l" || true; done
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
# Không có chữ "pair": truyền thẳng --server/--project/--chatid là ghép nối.
case ${1:-help} in
  run)  shift; cmd_run "$@" ;;
  test) shift; cmd_test "$@" ;;
  help|-h|--help) usage ;;
  --*)  cmd_pair "$@" ;;          # mặc định = ghép nối
  pair) die "bỏ chữ \"pair\" — truyền thẳng tham số:
  $PROG --server <url> --project <tên-dự-án> --chatid <chat-id>" ;;
  *) die "tham số không hợp lệ: $1 (xem: $PROG help)" ;;
esac
