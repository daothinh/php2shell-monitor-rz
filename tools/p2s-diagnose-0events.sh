#!/usr/bin/env bash
# p2s-diagnose-0events.sh — vì sao alert Telegram ghi "Event logs (0 nhóm / 0 events)"
# trong khi batch có hit?
#
# Chạy TRÊN SERVER DỰ ÁN (máy có php2shell-monitor). Chỉ đọc, không sửa gì.
#
#   sudo ./p2s-diagnose-0events.sh
#   sudo ./p2s-diagnose-0events.sh --workdir /opt/php2shell-monitor
#   sudo ./p2s-diagnose-0events.sh --batch 20261102T072700Z
#   sudo ./p2s-diagnose-0events.sh --server http://10.3.64.10:8000 --api-key KEY --alert-id 128
#
# Kết luận in ở cuối, mỗi dòng là một nguyên nhân đã kiểm chứng + cách xử lý.
set -u

WORKDIR=${WORKDIR:-/opt/php2shell-monitor}
BATCH=''
SERVER=''
API_KEY=''
ALERT_ID=''
CURL=(curl -sS --connect-timeout 5 --max-time 15)

while [[ $# -gt 0 ]]; do
  case $1 in
    --workdir) WORKDIR=${2:?}; shift 2 ;;
    --batch)   BATCH=${2:?}; shift 2 ;;
    --server)  SERVER=${2:?}; shift 2 ;;
    --api-key) API_KEY=${2:?}; shift 2 ;;
    --alert-id) ALERT_ID=${2:?}; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) printf 'tham số không hợp lệ: %s\n' "$1" >&2; exit 2 ;;
  esac
done

ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
head2(){ printf '\n== %s\n' "$*"; }

FINDINGS=()
add() { FINDINGS+=("$1"); }

# ---------------------------------------------------------------- 1. code
head2 "1. Code monitor đang cài ($WORKDIR)"
if [[ ! -d $WORKDIR ]]; then
  bad "không có $WORKDIR — dùng --workdir"
  add "Không tìm thấy bản cài; kiểm tra đường dẫn rồi chạy lại."
  printf '\n'
  printf '%s\n' "${FINDINGS[@]}"
  exit 0
fi

HAVE_PREVIEW=0
[[ -f $WORKDIR/lib/preview.awk ]] && HAVE_PREVIEW=1
if (( HAVE_PREVIEW )); then
  ok "có lib/preview.awk (>= 1.4.3)"
else
  bad "KHÔNG có lib/preview.awk  ->  monitor <= 1.4.2, alert KHÔNG mang preview[]"
  add "Monitor <= 1.4.2: nâng cấp lên >= 1.4.3 (dist/php2shell-monitor-1.4.3.sh). Đây là nguyên nhân trực tiếp của khối 'Event logs 0 nhóm / 0 events'."
fi

if grep -q 'ALERT_PREVIEW_MAX' "$WORKDIR/engine/report.sh" 2>/dev/null; then
  ok "report.sh có khối preview (3b)"
else
  bad "report.sh KHÔNG sinh preview[]  ->  server không có raw line để in"
  add "report.sh cũ: thay engine/report.sh bằng bản >= 1.4.3 (cài lại bằng dist mới)."
fi

PM=8
CONF=$WORKDIR/conf/default.conf
if [[ -r $CONF ]]; then
  v=$(sed -n 's/^[[:space:]]*ALERT_PREVIEW_MAX=//p' "$CONF" | tail -1 | tr -d '"'"'"' ')
  if [[ -n ${v:-} ]]; then
    PM=$v
    if [[ $v =~ ^[0-9]+$ ]] && (( v == 0 )); then
      bad "conf/default.conf: ALERT_PREVIEW_MAX=0  ->  preview[] rỗng dù code mới"
      add "Đặt ALERT_PREVIEW_MAX=8 trong $CONF (0 = tắt preview, tin nhắn sẽ không có raw)."
    else
      ok "conf/default.conf: ALERT_PREVIEW_MAX=$v"
    fi
  else
    ok "conf/default.conf không đặt ALERT_PREVIEW_MAX -> mặc định 8 (bản mới)"
  fi
else
  warn "không đọc được $CONF"
fi

# ---------------------------------------------------------------- 2. alert gần nhất
head2 "2. Alert gần nhất trong queue.jsonl"
DEV=$(sed -n 's/^DEVICE=//p' "$WORKDIR/conf/device.conf" 2>/dev/null | head -1)
PROJ=$(sed -n 's/^PROJECT=//p' "$WORKDIR/conf/device.conf" 2>/dev/null | head -1)
[[ -n ${DEV:-} ]] || DEV=$(hostname 2>/dev/null || echo unknown)
[[ -n ${PROJ:-} ]] || PROJ=default
Q=$WORKDIR/projects/$PROJ/devices/$DEV/alerts/queue.jsonl
printf '  device: %s/%s\n  queue : %s\n' "$PROJ" "$DEV" "$Q"

if [[ -s $Q ]]; then
  last=$(tail -1 "$Q")
  [[ -n $BATCH ]] || BATCH=$(printf '%s' "$last" | sed -n 's/.*"batch_id":"\([^"]*\)".*/\1/p')
  hits=$(printf '%s' "$last" | sed -n 's/.*"hits":\([0-9]*\).*/\1/p')
  meta=$(printf '%s' "$last" | sed -n 's/.*"preview_meta":"\([^"]*\)".*/\1/p')
  printf '  batch: %s  hits: %s  preview_meta: %s\n' "${BATCH:-?}" "${hits:-?}" "${meta:-<không có>}"
  if printf '%s' "$last" | grep -q '"preview":\[{'; then
    ok "alert CÓ preview[] (server in được raw line)"
  elif printf '%s' "$last" | grep -q '"preview":\[\]'; then
    bad "alert có preview:[] rỗng  ->  đúng là nguyên nhân tin nhắn 0 events"
    (( PM == 0 )) && add "preview:[] vì ALERT_PREVIEW_MAX=0 — bật lại =8."
  else
    bad "alert KHÔNG có khoá preview  ->  monitor <= 1.4.2 (đây là ca của sự cố)"
  fi
else
  warn "chưa có alert nào trong $Q (hoặc sai PROJECT/DEVICE)"
  add "Không có alert trong queue: kiểm tra conf/device.conf và 'php2shell-monitor.sh -- status'."
fi

# ---------------------------------------------------------------- 3. evidence
head2 "3. Evidence của batch (raw đầy đủ)"
EV=$WORKDIR/projects/$PROJ/devices/$DEV/evidence/$BATCH.jsonl
if [[ -n ${BATCH:-} && -s $EV ]]; then
  n=$(wc -l <"$EV")
  ok "có $EV ($n dòng)"
  if [[ -n ${hits:-} ]] && (( n != hits )); then
    warn "số dòng evidence ($n) != hits trong alert ($hits) — bình thường nếu alert gửi trước khi ghi xong, đáng ngờ nếu lâu"
  fi
else
  bad "KHÔNG có file evidence cho batch ${BATCH:-?} (đã bị retention xoá?)"
  add "Thiếu evidence cục bộ: EVIDENCE_KEEP=${EVIDENCE_KEEP:-2016} batch (~7 ngày). Cần tra lâu hơn thì tăng EVIDENCE_KEEP."
fi

# ---------------------------------------------------------------- 3b. upload evidence
head2 "3b. Agent có upload evidence lên server không"
if [[ -r $WORKDIR/conf/central.conf ]]; then
  if grep -q "upload_evidence" "$WORKDIR/engine/central.sh" 2>/dev/null; then
    ok "engine/central.sh có upload_evidence (raw đi kênh /ingest-evidence)"
  else
    bad "engine/central.sh KHÔNG upload evidence -> server không có raw để dựng preview"
    add "Cài lại monitor >= 1.4.4 trên máy này: alert chỉ mang metadata, raw phải đi kênh riêng."
  fi
  log=$WORKDIR/projects/$PROJ/devices/$DEV/run/agent.log
  if [[ -r $log ]]; then
    n=$(grep -c "ingest-evidence\|evidence" "$log" 2>/dev/null || echo 0)
    ok "agent.log có $n dòng liên quan evidence"
  fi
else
  warn "chưa có central.conf — bỏ qua"
fi

# ---------------------------------------------------------------- 4. agent
head2 "4. Agent đẩy alert (conf/central.conf)"
CONF2=$WORKDIR/conf/central.conf
if [[ -r $CONF2 ]]; then
  ok "có $CONF2"
  [[ -n $SERVER ]] || SERVER=$(sed -n 's/^SERVER_URL=//p' "$CONF2" | head -1)
  [[ -n $API_KEY ]] || API_KEY=$(sed -n 's/^API_KEY=//p' "$CONF2" | head -1)
  if [[ -n ${SERVER:-} ]]; then
    code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$SERVER/api/v1/whoami" \
      -H "X-API-Key: $API_KEY" 2>/dev/null || echo 000)
    case $code in
      200) ok "whoami $SERVER -> 200 (key còn sống)" ;;
      401) bad "whoami -> 401: dự án đã bị /unlink, key bị thu hồi (alert nằm trong spool)"
           add "Chạy lại lệnh deploy/pair trên máy này để cấp key mới." ;;
      *)   warn "whoami -> $code (không kết luận được: mạng/URL)" ;;
    esac
  fi
else
  warn "chưa ghép nối ($CONF2 không tồn tại) — alert chỉ nằm trong queue, không lên Telegram"
  add "Chưa pair: chạy 'php2shell-monitor.sh --project <tên> --chatid <id>'."
fi

# ---------------------------------------------------------------- 5. server-side
head2 "5. Phía central server"
if [[ -n ${SERVER:-} && -n ${ALERT_ID:-} && -n ${API_KEY:-} ]]; then
  body=$("${CURL[@]}" "$SERVER/api/v1/alerts/$ALERT_ID" -H "X-API-Key: $API_KEY" 2>/dev/null)
  hc=$(printf '%s' "$body" | sed -n 's/.*"hit_count":\([0-9]*\).*/\1/p')
  ne=$(printf '%s' "$body" | python3 -c 'import json,sys;print(len(json.load(sys.stdin).get("evidence") or []))' 2>/dev/null || echo '?')
  printf '  alert %s: hit_count=%s  rows trong alert_hits=%s\n' "$ALERT_ID" "${hc:-?}" "$ne"
  if [[ ${hc:-0} =~ ^[0-9]+$ ]] && (( hc > 0 )) && [[ ${ne:-0} == 0 ]]; then
    bad "server lưu 0 raw row cho alert có $hc hit  ->  /alerts/$ALERT_ID và /search trống"
    add "Server cần bản vá evidence.normalize (không bịa hit NULL, lưu preview[] thành hit)."
  fi
  # tin nhắn đã gửi là bất biến: muốn xem lại phải đọc evidence, không đọc Telegram
  add "Tin nhắn đã gửi KHÔNG sửa lại được. Raw của batch này lấy ở: $EV (local) hoặc $SERVER (evidence mirror)."
else
  warn "bỏ qua (cần --server + --api-key + --alert-id để kiểm tra DB server)"
fi

# ---------------------------------------------------------------- kết luận
head2 "KẾT LUẬN"
if ((${#FINDINGS[@]})); then
  i=1
  for f in "${FINDINGS[@]}"; do printf '  %d. %s\n' "$i" "$f"; i=$((i+1)); done
else
  printf '  Không thấy bất thường: alert có preview[], agent sống, evidence đủ.\n'
fi
printf '\n'
