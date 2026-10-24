#!/usr/bin/env bash
# e2e_full_test.sh — end-to-end: php2shell-monitor -> queue -> p2s-agent -> server.
#
# Verifies the contract of the simplified model:
#   * one batch produces AT MOST ONE alert (highest severity)
#   * that alert carries every raw hit line with file + line
#   * batch with no hits produces no alert
#   * evidence files land under projects/<project>/devices/<device>/evidence/
#
# Usage:
#   e2e_full_test.sh [--src <php2shell-monitor/src>] [--conf <agent.conf>] [--keep]
set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
SRC=${REPO_ROOT}/php2shell-monitor/src
CONF=
KEEP=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --src) SRC=${2:?}; shift 2 ;;
    --conf) CONF=${2:?}; shift 2 ;;
    --keep) KEEP=1; shift ;;
    *) echo "tham số lạ: $1" >&2; exit 2 ;;
  esac
done
[[ -d $SRC/engine && -d $SRC/plugins ]] || { echo "không tìm thấy engine/plugins trong $SRC" >&2; exit 2; }

LAB=/tmp/p2s-e2e-full
W=$LAB/workdir
DEV=$W/projects/khach-hang-a/devices/web01
QUEUE=$DEV/alerts/queue.jsonl
ATTACKER=203.0.113.42
BENIGN=198.51.100.7
AGENT_PID=

cleanup() {
  [[ -n $AGENT_PID ]] && kill "$AGENT_PID" 2>/dev/null
  (( KEEP )) || rm -rf -- "$LAB"
}
trap cleanup EXIT

clf_ts() { LC_ALL=C date '+%d/%b/%Y:%H:%M:%S %z'; }
fpm_ts() { LC_ALL=C date '+%d-%b-%Y %H:%M:%S'; }
ngx_ts() { LC_ALL=C date '+%Y/%m/%d %H:%M:%S'; }

PASS=0 FAIL=0
# eq <actual> <expected> -> 1 when equal (keeps arithmetic contexts string-safe)
eq() { [[ "$1" == "$2" ]] && echo 1 || echo 0; }

check() { # <case> <mô tả> <0/1>
  if (( $3 )); then PASS=$((PASS + 1)); printf '  PASS  %-4s %s\n' "$1" "$2";
  else FAIL=$((FAIL + 1)); printf '  FAIL  %-4s %s\n' "$1" "$2"; fi
}

scan() {
  WORKDIR=$W bash "$W/engine/scan.sh" >>"$LAB/scan.log" 2>&1
}

# alerts added since the last mark
MARK=0
mark() { MARK=$(wc -l <"$QUEUE" 2>/dev/null || echo 0); }
since_mark() { tail -n +"$((MARK + 1))" -- "$QUEUE" 2>/dev/null; }

# ---------------------------------------------------------------- setup lab
printf '== SETUP: %s ==\n' "$W"
rm -rf -- "$LAB"
mkdir -p "$LAB/logs" "$LAB/webroot"
cp -a -- "$SRC/." "$W/"
mkdir -p -- "$W"/{projects,run,tmp,reports,export}

cat >"$W/conf/device.conf" <<'EOF'
PROJECT="khach-hang-a"
DEVICE="web01"
EOF

cat >"$W/conf/default.conf" <<EOF
WORKDIR=$W
BATCH_INTERVAL=300
MAX_EVIDENCE_INLINE=500
EVIDENCE_KEEP=50
PLUGINS_DISABLED="kernel docker_logs appcms sessions modsec proc_tree"
PROC_SCAN=0
NGINX_ACCESS="$LAB/logs/access.log"
NGINX_ERROR="$LAB/logs/nginx-error.log"
FPM_LOG="$LAB/logs/fpm.log"
APACHE_ACCESS=/nonexistent-e2e
APACHE_ERROR=/nonexistent-e2e
WEBROOTS="$LAB/webroot"
SESSION_DIRS=/nonexistent-e2e
AUDIT_LOG=/nonexistent-e2e
EOF
: >"$W/conf/whitelist.conf"
touch "$LAB/logs/access.log" "$LAB/logs/nginx-error.log" "$LAB/logs/fpm.log"
mkdir -p -- "$DEV/alerts" "$DEV/evidence" "$DEV/state" "$DEV/run"
: >"$QUEUE"
printf '<?php echo "home";\n' >"$LAB/webroot/index.php"

if [[ -n $CONF ]]; then
  # shellcheck disable=SC1090
  source "$CONF"
  printf '== AGENT: đẩy alert về %s (dự án: %s) ==\n' "${SERVER_URL:-?}" "${PROJECT_NAME:-?}"
  P2S_AGENT_CONF=$CONF P2S_AGENT_STATE=$LAB/agent-state P2S_ALERT_FILE=$QUEUE \
    P2S_AGENT_POLL=2 bash "$REPO_ROOT/central-alert-server/client/p2s-agent.sh" run \
    >"$LAB/agent.log" 2>&1 &
  AGENT_PID=$!
fi

# ---------------------------------------------------------------- warm-up
printf '== WARM-UP: batch đầu (học offset + manifest webroot) ==\n'
scan
check WUP "khởi động không sinh alert (N=$(wc -l <"$QUEUE" 2>/dev/null || echo 0))" \
  $(( $(wc -l <"$QUEUE" 2>/dev/null || echo 0) == 0 ))
mark

# ---------------------------------------------------------------- case 0
printf '== CASE 0: lưu lượng lành ==\n'
{
  printf '%s - - [%s] "GET / HTTP/1.1" 200 5120 "-" "Mozilla/5.0"\n' "$BENIGN" "$(clf_ts)"
  printf '%s - - [%s] "GET /index.php HTTP/1.1" 200 892 "-" "Mozilla/5.0"\n' "$BENIGN" "$(clf_ts)"
  printf '%s - - [%s] "GET /static/logo.png HTTP/1.1" 304 0 "-" "Mozilla/5.0"\n' "$BENIGN" "$(clf_ts)"
  printf '%s - - [%s] "POST /contact.php HTTP/1.1" 200 320 "-" "Mozilla/5.0"\n' "$BENIGN" "$(clf_ts)"
  printf '%s - - [%s] "GET /khong-ton-tai.js HTTP/1.1" 404 153 "-" "Googlebot"\n' "$BENIGN" "$(clf_ts)"
} >>"$LAB/logs/access.log"
scan
check 0 "5 request lành không sinh alert" $(( $(since_mark | grep -c .) == 0 ))
check 0 "batch không hit được ghi log" \
  $(( $(tail -1 "$DEV/run/batches.log" | grep -c 'no-hits') == 1 ))
mark

# ---------------------------------------------------------------- case 1
printf '== CASE 1: T1 — UA php2shell + upload-progress + webshell cmd ==\n'
{
  printf '%s - - [%s] "POST /upload.php HTTP/1.1" 200 512 "-" "php2shell-109619"\n' "$ATTACKER" "$(clf_ts)"
  printf '%s - - [%s] "POST /upload.php?PHP_SESSION_UPLOAD_PROGRESS=exec HTTP/1.1" 200 128 "-" "curl/8.5.0"\n' "$ATTACKER" "$(clf_ts)"
  printf '%s - - [%s] "GET /sh.php?cmd=whoami HTTP/1.1" 200 34 "-" "curl/8.5.0"\n' "$ATTACKER" "$(clf_ts)"
} >>"$LAB/logs/access.log"
scan
A=$(since_mark)
check 1 "3 dòng tấn công -> ĐÚNG 1 alert (N=$(printf '%s' "$A" | grep -c .))" \
  $(( $(printf '%s' "$A" | grep -c .) == 1 ))
check 1 "alert gộp đủ 3 rule" \
  "$(eq "$(printf '%s' "$A" | jq -r '[.rules[].rule_id]|sort|join(",")')" "P2S-008,P2S-017,P2S-030")"
check 1 "alert có 3 hit" $(( $(printf '%s' "$A" | jq -r '.hits') == 3 ))
check 1 "severity = HIGH (cao nhất trong batch)" \
  "$(eq "$(printf '%s' "$A" | jq -r '.severity')" "HIGH")"
check 1 "mỗi hit có file + line + raw" \
  $(( $(printf '%s' "$A" | jq -r '[.evidence[] | select(.file != "" and .line > 0 and (.raw|length) > 10)] | length') == 3 ))
mark

# ---------------------------------------------------------------- case 2
printf '== CASE 2: T2 — FPM OOM x5 (min=5) + SIGSEGV + nginx upstream ==\n'
for i in 1 2 3 4 5; do
  printf '[%s] WARNING: [pool www] child %d said into stderr: "PHP Fatal error:  Allowed memory size of 134217728 bytes exhausted"\n' \
    "$(fpm_ts)" $((4200 + i)) >>"$LAB/logs/fpm.log"
done
printf '[%s] WARNING: [pool www] child 4242 exited on signal 11 (SIGSEGV)\n' "$(fpm_ts)" >>"$LAB/logs/fpm.log"
printf '%s [error] 909#0: *4567 upstream prematurely closed connection, client: %s\n' \
  "$(ngx_ts)" "$ATTACKER" >>"$LAB/logs/nginx-error.log"
scan
A=$(since_mark)
check 2 "vẫn đúng 1 alert cho cả batch T2" $(( $(printf '%s' "$A" | grep -c .) == 1 ))
check 2 "alert gồm P2S-010, P2S-011, P2S-014" \
  "$(eq "$(printf '%s' "$A" | jq -r '[.rules[].rule_id]|sort|join(",")')" "P2S-010,P2S-011,P2S-014")"
check 2 "7 hit được giữ" $(( $(printf '%s' "$A" | jq -r '.hits') == 7 ))
check 2 "hit FPM chỉ đúng file log + số dòng" \
  $(( $(printf '%s' "$A" | jq -r '[.evidence[] | select(.source=="fpm_error" and (.file|endswith("fpm.log")))] | length') == 6 ))
mark

# ---------------------------------------------------------------- case 3
printf '== CASE 3: T3 — webshell drop + auto_prepend ==\n'
printf '<?php system($_GET["cmd"]); ?>\n' >"$LAB/webroot/uploads_shell.php"
printf 'auto_prepend_file=/tmp/.ev030428.txt\n' >"$LAB/webroot/.htaccess"
scan
A=$(since_mark)
check 3 "đúng 1 alert" $(( $(printf '%s' "$A" | grep -c .) == 1 ))
check 3 "severity = CRITICAL" "$(eq "$(printf '%s' "$A" | jq -r '.severity')" "CRITICAL")"
check 3 "có P2S-020 và P2S-022" \
  "$(eq "$(printf '%s' "$A" | jq -r '[.rules[].rule_id]|sort|join(",")')" "P2S-020,P2S-022")"
check 3 "evidence trỏ đúng file trên webroot" \
  $(( $(printf '%s' "$A" | jq -r '[.evidence[] | select(.file|contains("webroot"))] | length') >= 2 ))
mark

# ---------------------------------------------------------------- case 4
printf '== CASE 4: 10 request giống nhau trong 1 batch ==\n'
for i in $(seq 1 10); do
  printf '%s - - [%s] "GET /uploads_shell.php?cmd=uname HTTP/1.1" 200 20 "-" "curl/8.5.0"\n' \
    "$ATTACKER" "$(clf_ts)" >>"$LAB/logs/access.log"
done
scan
A=$(since_mark)
check 4 "10 dòng -> 1 alert" $(( $(printf '%s' "$A" | grep -c .) == 1 ))
check 4 "giữ đủ 10 hit (không dedup)" $(( $(printf '%s' "$A" | jq -r '.hits') == 10 ))
check 4 "evidence file có 10 dòng" \
  $(( $(wc -l <"$DEV/evidence/$(printf '%s' "$A" | jq -r '.batch_id').jsonl") == 10 ))
mark

# ---------------------------------------------------------------- tổng kết
printf '\n== TỔNG KẾT: PASS=%d FAIL=%d ==\n' "$PASS" "$FAIL"
printf -- '---- alert trong queue ----\n'
jq -r '[.batch_id, .severity, (.hits|tostring), ([.rules[].rule_id]|join(","))] | @tsv' "$QUEUE" 2>/dev/null

if [[ -n $AGENT_PID ]]; then
  printf -- '---- chờ agent đẩy (tối đa 60s) ----\n'
  for _ in $(seq 1 60); do
    sleep 1
    kill -0 "$AGENT_PID" 2>/dev/null || break
    qsize=$(stat -c %s "$QUEUE" 2>/dev/null || echo 0)
    apos=$(awk '{print $2}' "$LAB/agent-state/offset" 2>/dev/null || echo 0)
    [[ ${apos:-0} -ge ${qsize:-0} ]] && break
  done
  kill "$AGENT_PID" 2>/dev/null; wait "$AGENT_PID" 2>/dev/null; AGENT_PID=
  printf -- '---- agent log ----\n'; grep -E 'đã gửi|mạng lỗi|spool' "$LAB/agent.log" || true
  printf -- '---- server ----\n'
  # /devices yêu cầu credential đọc: dùng chính API key của agent vừa đẩy alert.
  curl -s "${SERVER_URL}/api/v1/devices" -H "X-API-Key: ${API_KEY:?}" \
    | jq -c '.devices[]?' 2>/dev/null || true
fi
(( FAIL == 0 ))
