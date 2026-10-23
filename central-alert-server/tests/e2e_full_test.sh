#!/usr/bin/env bash
# e2e_full_test.sh — E2E sát thực tế cho toàn chuỗi:
#   php2shell-monitor (engine thật, workdir deploy thật, batch scan thật)
#   -> alerts/queue.jsonl -> p2s-agent.sh -> central-alert-server -> Telegram
#
# Cases (mô phỏng một cuộc tấn công PHP2Shell đúng tiến trình):
#   0. Baseline lưu lượng lành        -> kỳ vọng 0 alert (âm tính, không FP)
#   1. T1  khai thác thử              -> P2S-008 (UA php2shell), P2S-017 (upload-progress)
#   2. T2  đang khai thác             -> P2S-010 (OOM x5, aggregate), P2S-011 (SIGSEGV),
#                                        P2S-014 (nginx upstream reset)
#   3. T3  hậu khai thác              -> P2S-020 (webshell drop), P2S-022 (auto_prepend),
#                                        P2S-030 (webshell cmd=whoami)
#   4.   chống bão alert              -> 10 dòng webshell giống hệt -> đúng 1 alert (dedup 900s)
#
# Usage:
#   e2e_full_test.sh [--src <php2shell-monitor/src>] [--conf <agent.conf>] [--keep]
#
#   --src  : thư mục src của php2shell-monitor (mặc định: <repo>/php2shell-monitor/src)
#   --conf : agent.conf có SERVER_URL + API_KEY hợp lệ -> alert được đẩy THẬT về
#            central server (và Telegram nếu dự án đã ghép nối). Bỏ qua = chỉ test engine.
#   --keep : giữ lại lab /tmp/p2s-e2e-full sau khi chạy (mặc định: dọn sạch).
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
QUEUE=$W/alerts/queue.jsonl
ATTACKER=203.0.113.42
BENIGN=198.51.100.7
AGENT_PID=

cleanup() {
  [[ -n $AGENT_PID ]] && kill "$AGENT_PID" 2>/dev/null
  (( KEEP )) || rm -rf -- "$LAB"
}
trap cleanup EXIT

# ---------------------------------------------------------------- helpers
clf_ts() { LC_ALL=C date '+%d/%b/%Y:%H:%M:%S %z'; }
fpm_ts() { LC_ALL=C date '+%d-%b-%Y %H:%M:%S'; }
ngx_ts() { LC_ALL=C date '+%Y/%m/%d %H:%M:%S'; }

PASS=0 FAIL=0
check() { # <case> <mô tả> <0/1>
  if (( $3 )); then PASS=$((PASS + 1)); printf '  PASS  %-4s %s\n' "$1" "$2";
  else FAIL=$((FAIL + 1)); printf '  FAIL  %-4s %s\n' "$1" "$2"; fi
}
has() { grep -qx "$2" <<<"$1" && echo 1 || echo 0; }
nlines() { grep -c . <<<"$1"; }

# Lưu ý: scan.sh source conf/default.conf nhưng KHÔNG export các biến nguồn log,
# nên plugin (process con) không nhận được custom path — bug đã biết của engine.
# Workaround: truyền thẳng qua môi trường lệnh scan.
scan() {
  WORKDIR=$W \
  NGINX_ACCESS="$LAB/logs/access.log" \
  NGINX_ERROR="$LAB/logs/nginx-error.log" \
  FPM_LOG="$LAB/logs/fpm.log" \
  APACHE_ACCESS=/nonexistent-e2e APACHE_ERROR=/nonexistent-e2e \
  WEBROOTS="$LAB/webroot" SESSION_DIRS=/nonexistent-e2e AUDIT_LOG=/nonexistent-e2e \
  PROC_SCAN=0 \
    bash "$W/engine/scan.sh" >>"$LAB/scan.log" 2>&1
}
MARK=0
mark() { MARK=$(wc -l <"$QUEUE" 2>/dev/null || echo 0); }
rules_since_mark() { tail -n +"$((MARK + 1))" -- "$QUEUE" 2>/dev/null | jq -r '.rule_id // empty' 2>/dev/null; }

# ---------------------------------------------------------------- setup lab
printf '== SETUP: deploy workdir php2shell-monitor vào %s ==\n' "$W"
rm -rf -- "$LAB"
mkdir -p "$LAB/logs" "$LAB/webroot"
cp -a -- "$SRC/." "$W/"
# default.conf của monitor gán cứng WORKDIR=/tmp/php2shell-monitor (sẽ ghi đè env sau khi
# được source) -> trỏ về sandbox; và tự tạo các thư mục runtime mà main.sh thường làm
sed -i "s|^WORKDIR=.*|WORKDIR=$W|" "$W/conf/default.conf"
mkdir -p -- "$W"/{alerts,export,reports,run,tmp,state/agg}
touch "$QUEUE"

printf '<?php echo "home";\n'  >"$LAB/webroot/index.php"
printf '<?php echo "about";\n' >"$LAB/webroot/about.php"

# pre-seed manifest webroot = "monitor đã biết webroot này từ trước"
# (không thì scan đầu tiên báo NEW cho mọi file hiện có — nhiễu baseline)
mkdir -p -- "$W/state"
{
  printf '# path\tsize\tmtime\towner\n'
  find "$LAB/webroot" -xdev -type f \
    \( -name '*.php' -o -name '*.phtml' -o -name '*.phar' -o -name '*.php5' \
       -o -name '*.inc' -o -name '.user.ini' -o -name '.htaccess' -o -name '*.sh' \) \
    -printf '%p\t%s\t%T@\t%U\n' 2>/dev/null
} >"$W/state/webroot.manifest.tsv"

# trỏ mọi nguồn log vào sandbox; tắt plugin đọc hệ thống thật (ngoài scope case)
cat >>"$W/conf/default.conf" <<EOF

# ---- E2E sandbox overrides ----
NGINX_ACCESS="$LAB/logs/access.log"
NGINX_ERROR="$LAB/logs/nginx-error.log"
FPM_LOG="$LAB/logs/fpm.log"
APACHE_ACCESS=/nonexistent-e2e
APACHE_ERROR=/nonexistent-e2e
WEBROOTS="$LAB/webroot"
SESSION_DIRS=/nonexistent-e2e
AUDIT_LOG=/nonexistent-e2e
PROC_SCAN=0
PLUGINS_DISABLED="kernel docker_logs appcms sessions modsec auditd proc_tree"
EOF
touch "$LAB/logs/access.log" "$LAB/logs/nginx-error.log" "$LAB/logs/fpm.log"

if [[ -n $CONF ]]; then
  # shellcheck disable=SC1090
  source "$CONF"
  printf '== AGENT: bật đẩy alert về %s (dự án: %s) ==\n' "${SERVER_URL:-?}" "${PROJECT_NAME:-?}"
  P2S_AGENT_CONF=$CONF P2S_AGENT_STATE=$LAB/agent-state P2S_ALERT_FILE=$QUEUE P2S_AGENT_POLL=3 \
    bash "$REPO_ROOT/central-alert-server/client/p2s-agent.sh" run >"$LAB/agent.log" 2>&1 &
  AGENT_PID=$!
fi

# ---------------------------------------------------------------- warm-up
printf '== WARM-UP: 1 batch với log rỗng (học offset/manifest) ==\n'
scan
WARM=$(wc -l <"$QUEUE" 2>/dev/null || echo 0)
check WUP "baseline sạch — không alert lúc khởi động (N=$WARM)" $(( WARM == 0 ))
: >"$QUEUE"
mark

# ---------------------------------------------------------------- case 0
printf '== CASE 0: lưu lượng lành (kỳ vọng 0 alert) ==\n'
{
  printf '%s - - [%s] "GET / HTTP/1.1" 200 5120 "-" "Mozilla/5.0 (X11; Linux x86_64)"\n' "$BENIGN" "$(clf_ts)"
  printf '%s - - [%s] "GET /about.php HTTP/1.1" 200 892 "-" "Mozilla/5.0 (X11; Linux x86_64)"\n' "$BENIGN" "$(clf_ts)"
  printf '%s - - [%s] "GET /static/logo.png HTTP/1.1" 304 0 "-" "Mozilla/5.0"\n' "$BENIGN" "$(clf_ts)"
  printf '%s - - [%s] "POST /contact.php HTTP/1.1" 200 320 "https://site.vn/" "Mozilla/5.0"\n' "$BENIGN" "$(clf_ts)"
  printf '%s - - [%s] "GET /khong-ton-tai.js HTTP/1.1" 404 153 "-" "Googlebot/2.1"\n' "$BENIGN" "$(clf_ts)"
} >>"$LAB/logs/access.log"
scan
R=$(rules_since_mark)
check 0 "5 request lành (200/304/404) KHÔNG sinh alert (N=$(nlines "$R"))" \
  $(( $(nlines "$R") == 0 ))
mark

# ---------------------------------------------------------------- case 1
printf '== CASE 1 (T1 — khai thác thử): UA php2shell + upload-progress ==\n'
{
  printf '%s - - [%s] "POST /upload.php HTTP/1.1" 200 512 "-" "php2shell-109619"\n' "$ATTACKER" "$(clf_ts)"
  printf '%s - - [%s] "POST /upload.php?PHP_SESSION_UPLOAD_PROGRESS=exec HTTP/1.1" 200 128 "-" "Mozilla/5.0 (X11; Linux x86_64)"\n' "$ATTACKER" "$(clf_ts)"
  printf '%s - - [%s] "GET /admin.php HTTP/1.1" 404 0 "-" "Mozilla/5.0 (X11; Linux x86_64)"\n' "$ATTACKER" "$(clf_ts)"
} >>"$LAB/logs/access.log"
scan
R=$(rules_since_mark)
check 1 "P2S-008 (UA php2shell) kích phát"      $(( $(has "$R" P2S-008) ? 1 : 0 ))
check 1 "P2S-017 (upload-progress URI) kích phát" $(( $(has "$R" P2S-017) ? 1 : 0 ))
check 1 "đúng 2 alert cho 3 dòng tấn công (N=$(nlines "$R"))" $(( $(nlines "$R") == 2 ))
mark

# ---------------------------------------------------------------- case 2
printf '== CASE 2 (T2 — đang khai thác): FPM OOM x5 + SIGSEGV + nginx upstream ==\n'
for i in 1 2 3 4 5; do
  printf '[%s] WARNING: [pool www] child %d said into stderr: "PHP Fatal error:  Allowed memory size of 134217728 bytes exhausted (tried to allocate 20480 bytes)"\n' \
    "$(fpm_ts)" $((4200 + i)) >>"$LAB/logs/fpm.log"
  sleep 1
done
printf '[%s] WARNING: [pool www] child 4242 exited on signal 11 (SIGSEGV)\n' "$(fpm_ts)" >>"$LAB/logs/fpm.log"
printf '%s [error] 909#0: *4567 upstream prematurely closed connection while reading response header from upstream, client: %s\n' \
  "$(ngx_ts)" "$ATTACKER" >>"$LAB/logs/nginx-error.log"
scan
R=$(rules_since_mark)
check 2 "P2S-010 (OOM aggregate >=5) kích phát đúng 1 lần"  $(( $(has "$R" P2S-010) ? 1 : 0 ))
check 2 "P2S-011 (SIGSEGV) kích phát"                       $(( $(has "$R" P2S-011) ? 1 : 0 ))
check 2 "P2S-014 (nginx upstream reset) kích phát"          $(( $(has "$R" P2S-014) ? 1 : 0 ))
check 2 "đúng 3 alert T2 (N=$(nlines "$R"))"                $(( $(nlines "$R") == 3 ))
mark

# ---------------------------------------------------------------- case 3
printf '== CASE 3 (T3 — hậu khai thác): drop webshell + auto_prepend + cmd=whoami ==\n'
printf '<?php system($_GET["cmd"]); ?>\n' >"$LAB/webroot/uploads_shell.php"
printf 'auto_prepend_file=/tmp/.ev030428.txt\n' >"$LAB/webroot/.htaccess"
printf '%s - - [%s] "GET /uploads_shell.php?cmd=whoami HTTP/1.1" 200 34 "-" "curl/8.5.0"\n' \
  "$ATTACKER" "$(clf_ts)" >>"$LAB/logs/access.log"
scan
R=$(rules_since_mark)
check 3 "P2S-020 (file mới trong webroot) kích phát"          $(( $(has "$R" P2S-020) ? 1 : 0 ))
check 3 "P2S-022 (auto_prepend_file) kích phát"               $(( $(has "$R" P2S-022) ? 1 : 0 ))
check 3 "P2S-030 (webshell cmd=whoami) kích phát"             $(( $(has "$R" P2S-030) ? 1 : 0 ))
check 3 "đúng 3 alert T3 (N=$(nlines "$R"))"                 $(( $(nlines "$R") == 3 ))
mark

# ---------------------------------------------------------------- case 4
printf '== CASE 4: chống bão alert — 10 request webshell giống hệt nhau ==\n'
for i in $(seq 1 10); do
  printf '%s - - [%s] "GET /uploads_shell.php?cmd=uname HTTP/1.1" 200 20 "-" "curl/8.5.0"\n' \
    "$ATTACKER" "$(clf_ts)" >>"$LAB/logs/access.log"
done
scan
R=$(rules_since_mark)
check 4 "10 dòng giống nhau -> ĐÚNG 1 alert (N=$(nlines "$R"))" $(( $(nlines "$R") == 1 ))
check 4 "alert đó là P2S-030"                                  $(( $(has "$R" P2S-030) ? 1 : 0 ))
mark

# ---------------------------------------------------------------- tổng kết
printf '\n== TỔNG KẾT: PASS=%d FAIL=%d ==\n' "$PASS" "$FAIL"
printf -- '---- alert đã ghi vào queue (đã/kẽ sẽ đẩy Telegram nếu --conf) ----\n'
jq -r '[.severity, .rule_id, .uri // "-", (.src_ip_candidates[0].ip // "-")] | @tsv' "$QUEUE" 2>/dev/null | sort | uniq -c
if [[ -n $AGENT_PID ]]; then
  printf -- '---- chờ agent đẩy nốt (tối đa 60s) ----\n'
  for _ in $(seq 1 60); do
    sleep 1
    kill -0 "$AGENT_PID" 2>/dev/null || break
    qsize=$(stat -c %s "$QUEUE" 2>/dev/null || echo 0)
    apos=$(awk '{print $2}' "$LAB/agent-state/offset" 2>/dev/null || echo 0)
    [[ ${apos:-0} -ge ${qsize:-0} ]] && break
  done
  kill "$AGENT_PID" 2>/dev/null; wait "$AGENT_PID" 2>/dev/null; AGENT_PID=
  printf -- '---- log agent ----\n'; grep -E 'đã gửi|mạng lỗi|spool' "$LAB/agent.log" || true
  printf -- '---- offset agent %s / queue %s byte ----\n' \
    "$(awk '{print $2}' "$LAB/agent-state/offset" 2>/dev/null)" "$(stat -c %s "$QUEUE")"
fi
(( FAIL == 0 ))