#!/usr/bin/env bash
# central.sh - ghép nối với central server và đẩy alert lên đó.
#
#   central.sh pair  --chatid <chat-id>
#   central.sh agent
#   central.sh test
set -u
WORKDIR=${WORKDIR:-/opt/php2shell-monitor}
source "$WORKDIR/lib/common.sh"
source "$WORKDIR/lib/paths.sh"
source "$WORKDIR/lib/endpoint.sh"

CONF_PATH=$WORKDIR/conf/central.conf
POLL_INTERVAL=${P2S_AGENT_POLL:-5}
BATCH_MAX=20
PAIR_TIMEOUT=${P2S_PAIR_TIMEOUT:-900}   # 15 phút
PAIR_POLL=${P2S_PAIR_POLL:-3}
CURL=(curl -sS --connect-timeout 10 --max-time 30)

die() { printf 'php2shell-monitor: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

reinit_device() { # (re)compute device paths — also called after conf changes
  # shellcheck disable=SC2034  # vars are read by p2s_device_init & callers
  P2S_DATA_DIR='' P2S_ALERT_DIR='' P2S_EVIDENCE_DIR='' P2S_STATE_DIR='' P2S_DEVICE_RUN_DIR=''
  p2s_device_init || die "cannot initialise data dirs under $WORKDIR"
}
reinit_device

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
  [[ -r $CONF_PATH ]] || die "chưa ghép nối — chạy:
  sudo php2shell-monitor.sh --project <tên-dự-án> --chatid <chat-id>"
  # shellcheck disable=SC1090
  source "$CONF_PATH"
  [[ ${SERVER_URL:-} =~ ^https?:// ]] || SERVER_URL=$(p2s_endpoint)
  [[ ${SERVER_URL:-} =~ ^https?:// ]] || die "không xác định được central server"
  [[ -n ${API_KEY:-} ]] || die "API_KEY trống trong conf — chạy pair lại"
}

# Bot hệ thống (hiển thị trong hướng dẫn); server có thể trả tên bot thật
# trong response của register-chatid và sẽ ghi đè giá trị này.
P2S_BOT=${P2S_BOT:-@p2shell_bot}

# Key trong conf còn được server công nhận không? /unlink trên bot không có
# kênh báo ngược về máy nên conf local vẫn "nguyên vẹn" dù key đã bị thu hồi.
#   exit 0 = còn sống · 1 = server từ chối (401: đã /unlink, key bị thu hồi)
#   2 = không kết luận được (chưa có conf, mạng lỗi, server cũ chưa có /whoami)
check_pairing() {
  [[ -r $CONF_PATH ]] || return 2
  local key url code
  key=$(sed -n 's/^API_KEY=//p' "$CONF_PATH" | head -1)
  url=$(sed -n 's/^SERVER_URL=//p' "$CONF_PATH" | head -1)
  [[ -n $url ]] || url=$(p2s_endpoint)
  [[ -n $key && $url =~ ^https?:// ]] || return 2
  code=$("${CURL[@]}" -o /dev/null --max-time 10 -w '%{http_code}' \
    "$url/api/v1/whoami" -H "X-API-Key: $key") || return 2
  case $code in
    200) return 0 ;;
    401) return 1 ;;
    *)   return 2 ;;   # 404 = server cũ chưa có /whoami: giữ hành vi cũ
  esac
}

# Đã ghép nối đúng bộ ba server/project/chatid chưa? -> in trạng thái, trả 0.
already_paired() { # <server> <chatid>
  local server=$1 chatid=$2
  [[ -r $CONF_PATH ]] || return 1
  local c_server c_key c_proj c_chat
  c_server=$(sed -n 's/^SERVER_URL=//p' "$CONF_PATH" | head -1)
  c_key=$(sed -n 's/^API_KEY=//p' "$CONF_PATH" | head -1)
  c_proj=$(sed -n 's/^PROJECT_NAME=//p' "$CONF_PATH" | head -1)
  c_chat=$(sed -n 's/^CHAT_ID=//p' "$CONF_PATH" | head -1)
  # conf without CHAT_ID is not a match: pair again once
  [[ -n $c_key && $c_server == "$server" && $c_proj == "$PROJECT" && $c_chat == "$chatid" ]] || return 1
  # Conf khớp tham số CHƯA đủ: dự án có thể đã bị /unlink trên bot. Hỏi server;
  # chỉ khi server khẳng định từ chối (401) mới pair lại — mạng lỗi thì giữ
  # conf như cũ để chạy lệnh deploy nhiều lần không spam đăng ký.
  check_pairing
  (( $? == 1 )) && return 1
  return 0
}

cmd_pair() {
  local server='' chatid=''
  while [[ $# -gt 0 ]]; do
    case $1 in
      --server) shift 2 ;;   # bỏ: endpoint nằm trong mã nguồn
      --chatid) [[ -n ${2:-} ]] || die "--chatid cần Chat ID"; chatid=$2; shift 2 ;;
      *) die "tham số không hợp lệ: $1 (dùng: pair --chatid <id>)" ;;
    esac
  done

  local missing=()
  [[ -n $chatid  ]] || missing+=(--chatid)
  if ((${#missing[@]})); then
    die "thiếu tham số bắt buộc: ${missing[*]}
  sudo php2shell-monitor.sh --project <tên-dự-án> --chatid <chat-id>"
  fi

  server=$(p2s_endpoint) || die "không đọc được endpoint trong mã nguồn"
  [[ $server =~ ^https?:// ]] || die "endpoint trong mã nguồn không hợp lệ"
  chatid=$(printf '%s' "$chatid" | tr -d ' ')
  [[ $chatid =~ ^-?[1-9][0-9]{2,14}$ ]] \
    || die "--chatid không hợp lệ: phải là số Telegram (chat riêng dương, group âm)"

  local proj=$PROJECT
  [[ -n ${proj:-} && ${proj:-} != default ]] \
    || die "thiếu tên dự án — chạy: sudo php2shell-monitor.sh --project <tên> --chatid <id>"

  # ---- idempotent: chạy lại cùng tham số không ghép nối lại, không spam chat ----
  if already_paired "$server" "$chatid"; then
    printf 'Đã ghép nối trước đó — giữ nguyên API key trong %s\n' "$CONF_PATH"
    printf ' Dự án: %s · Thiết bị: %s\n' "$proj" "$DEVICE"
    return 0
  fi

  local ip
  ip=$(lan_ip)
  printf '\n⏳ Đang đăng ký thiết bị %s | %s cho dự án "%s" (thiết bị %s)\n' \
    "$DEVICE" "${ip:-không rõ IP}" "$proj" "$DEVICE"
  local resp pair_ref warn rbot
  resp=$("${CURL[@]}" -X POST "$server/api/v1/register-chatid" \
    -H 'Content-Type: application/json' \
    -d "{\"project_name\":\"$(json_escape "$proj")\",\"chat_id\":\"$(json_escape "$chatid")\",\"device\":\"$(json_escape "$DEVICE")\"}") \
    || die "không gọi được $server — kiểm tra đường mạng/URL: $server"
  pair_ref=$(json_get "$resp" pair_ref)
  [[ -n $pair_ref ]] || die "server trả về không có pair_ref: $resp"
  local bot=$P2S_BOT
  rbot=$(json_get "$resp" bot)
  [[ -n $rbot && $rbot != null ]] && bot=$rbot
  warn=$(json_get "$resp" warning)
  if [[ -n $warn && $warn != null ]]; then
    cat >&2 <<EOF

⚠️  Bot chưa nhắn được vào chat $chatid (chưa được START).
   Cách xử lý: mở https://t.me/${bot#@} → nhấn START (thêm bot vào group nếu là group).
   Dự án VẪN đã ghép nối và API key vẫn được cấp — nhưng alert chỉ tới
   sau khi bot nhắn được vào chat, nên hãy START trước.
EOF
  fi

  local i st status api_key
  for ((i = 0; i < PAIR_TIMEOUT; i += PAIR_POLL)); do
    sleep "$PAIR_POLL"
    if ! st=$("${CURL[@]}" "$server/api/v1/pairing-status?code=$pair_ref"); then
      printf '  (chờ lại — không gọi được server)\n' >&2
      continue
    fi
    status=$(json_get "$st" status)
    if [[ $status == linked ]]; then
      api_key=$(json_get "$st" api_key)
      [[ -n $api_key ]] || continue   # đã linked nhưng hết cửa sổ reveal
      (umask 077 && printf 'SERVER_URL=%q\nAPI_KEY=%q\nPROJECT_NAME=%q\nCHAT_ID=%q\n' \
        "$server" "$api_key" "$proj" "$chatid" >"$CONF_PATH")
      return 0
    fi
    if (( (i + PAIR_POLL) % 30 == 0 )); then
      printf '  ... vẫn đang chờ server phản hồi (đã %d giây)\n' "$((i + PAIR_POLL))"
    fi
  done
  die "hết thời gian chờ server cấp key — chạy lại lệnh triển khai"
}

# Ghi payload ra file rồi dùng --data-binary @file: argv có giới hạn
# (MAX_ARG_STRLEN ~128 KiB) nên một batch nhiều hit sẽ chết với
# "curl: Argument list too long" và alert kẹt lại trong spool.
post_alerts() { # các dòng JSON làm tham số -> 0 chỉ khi server NHẬN (HTTP 2xx)
  local payload_file os_name env_kind
  os_name=$(os_pretty); env_kind=$(env_label)
  payload_file=$P2S_TMP_DIR/payload.$$.json
  {
    printf '{"host":"%s","device":"%s","lan_ip":"%s","user":"%s","os":"%s","env":"%s","alerts":[' \
      "$(json_escape "$(hostname 2>/dev/null || echo unknown)")" \
      "$(json_escape "$DEVICE")" \
      "$(json_escape "$(lan_ip)")" \
      "$(json_escape "$(id -un 2>/dev/null || echo unknown)")" \
      "$(json_escape "$os_name")" \
      "$(json_escape "$env_kind")"
    printf '%s\n' "$@" | paste -sd, -
    printf ']}'
  } >"$payload_file" || { rm -f -- "$payload_file"; return 1; }
  local rc=0 code body_file=$P2S_TMP_DIR/resp.$$.json
  code=$("${CURL[@]}" -o "$body_file" -w '%{http_code}' -X POST \
    "$SERVER_URL/api/v1/ingest-log" \
    -H "X-API-Key: $API_KEY" -H 'Content-Type: application/json' \
    --data-binary "@$payload_file") || rc=$?
  rm -f -- "$payload_file"
  # Không nhìn HTTP status thì 4xx cũng "thành công" với curl: server từ chối
  # (vd 401 sau /unlink trên bot) mà agent tưởng đã gửi -> offset tiến, alert
  # mất im lặng. Chỉ 2xx mới tính là đã gửi.
  if (( rc )) || [[ ! $code =~ ^2 ]]; then
    [[ $code == 401 || $code == 403 ]] && _reject_hint "$body_file" "$code"
    rm -f -- "$body_file"
    return 1
  fi
  rm -f -- "$body_file"
  return 0
}

# Nói đúng nguyên nhân bị từ chối: server trả detail.code=project_disabled
# khi dự án đã /unlink (key bị thu hồi) — khi đó phải chạy deploy lại, không
# phải chờ mạng.
_reject_hint() { # <file body phản hồi> <http_code>
  local why
  why=$(grep -o '"code"[[:space:]]*:[[:space:]]*"project_disabled"' "$1" 2>/dev/null | head -1)
  if [[ -n $why ]]; then
    printf '%s: server từ chối — dự án đã bị ngắt (/unlink trên bot). Alert được giữ trong spool; chạy lại lệnh deploy để ghép nối lại.\n' \
      "$P2S_PROG" >&2
  else
    printf '%s: server từ chối (HTTP %s) — API key không hợp lệ. Alert được giữ trong spool; chạy lại lệnh deploy để ghép nối lại.\n' \
      "$P2S_PROG" "${2:-không rõ}" >&2
  fi
}

# upload_evidence <alert_json_line>
# Gửi file evidence của batch dạng gzip thô, tách khỏi alert JSON. Alert chỉ
# mang metadata; đây là kênh chở toàn bộ event. Server ghi thẳng vào mirror.
upload_evidence() {
  local line=$1 batch evf
  batch=$(printf '%s' "$line" | sed -n 's/.*"batch_id":"\([^"]*\)".*/\1/p')
  evf=$(printf '%s' "$line" | sed -n 's/.*"evidence_file":"\([^"]*\)".*/\1/p')
  [[ -n $batch && -n $evf && -r $evf ]] || return 0
  local gz="$P2S_TMP_DIR/ev.$batch.$$.gz"
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
  # singleton: the supervisor also starts an agent; later runs exit silently
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
          local _l
          for _l in "${part[@]}"; do upload_evidence "$_l" || true; done
          sent=$((sent + ${#part[@]}))
        else
          spool_append "${NEW_LINES[@]:sent}"
          printf '%s: không gửi được — spool %d alert, thử lại sau\n' \
            "$P2S_PROG" $((${#NEW_LINES[@]} - sent)) >&2
          break
        fi
      done
      save_offset "$NEW_INO" "$NEW_POS"   # luôn tiến offset; chưa gửi nằm trong spool
    fi
    sleep "$POLL_INTERVAL"
  done
}

cmd_test() {
  load_conf
  local ts payload resp
  ts=$(utc_now)
  payload=$(printf '{"host":"%s","lan_ip":"%s","user":"%s","os":"%s","env":"%s","alerts":[{"ts_utc":"%s","rule_id":"TEST-001","severity":"INFO","tier":"TEST","message":"Alert thử từ php2shell-monitor (%s) — đường truyền ghép nối hoạt động!"}]}' \
    "$(json_escape "$(hostname 2>/dev/null || echo unknown)")" \
    "$(json_escape "$(lan_ip)")" \
    "$(json_escape "$(id -un 2>/dev/null || echo unknown)")" \
    "$(json_escape "$(os_pretty)")" \
    "$(json_escape "$(env_label)")" \
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
  # Health-check ghép nối cho guard của main.sh: 0=sống 1=bị từ chối 2=không rõ
  is-alive) check_pairing; exit $? ;;
  *) die "central.sh {pair --chatid <id>} | agent | test | is-alive" ;;
esac
