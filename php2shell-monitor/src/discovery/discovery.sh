#!/usr/bin/env bash
# discovery.sh - 100% READ-ONLY host discovery. Output:
#   reports/log-map-actual.md        human report
#   <device>/state/capabilities.txt  which log sources exist (gates rules)
set -u
WORKDIR=${WORKDIR:-/opt/php2shell-monitor}
# shellcheck source=/dev/null
source "$WORKDIR/lib/common.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/log.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/paths.sh"
p2s_device_init || exit 1

REPORT=$WORKDIR/reports/log-map-actual.md
mkdir -p -- "$WORKDIR/reports"
: >"$REPORT"
_r() { printf '%s\n' "$*" >>"$REPORT"; }

_r "# php2shell-monitor discovery — $(utc_now)"
_r ""
_r "Project: $PROJECT | Device: $DEVICE"
_r "Host: $(hostname 2>/dev/null || echo unknown) | kernel: $(uname -r)"
_r ""

echo "== nginx (filtered) =="
_r "## nginx (filtered)"
if have nginx; then
  nginx -T 2>/dev/null | grep -nE '^\s*(access_log|error_log|log_format|client_max_body_size|real_ip_header|set_real_ip_from)\b' | tee -a "$REPORT"
  _r ""
else
  _r "not installed"
fi

echo "== apache =="
_r "## apache"
(apachectl -S 2>/dev/null || httpd -S 2>/dev/null) | tee -a "$REPORT" || _r "not installed"
grep -RhE '^\s*(LogFormat|CustomLog|ErrorLog|LogLevel)\b' /etc/apache2 /etc/httpd 2>/dev/null | tee -a "$REPORT" || true
_r ""

echo "== fpm units =="
_r "## fpm units"
systemctl list-units 'php*' --no-pager 2>/dev/null | tee -a "$REPORT" || true
_r "## fpm conf (filtered)"
grep -RhE '^\s*(error_log|slowlog|catch_workers_output|request_slowlog_timeout|php_admin_value\[(error_log|memory_limit)\]|php_admin_flag\[session\.upload_progress\.enabled\])' /etc/php* /etc/php-fpm* 2>/dev/null | tee -a "$REPORT" || true
_r ""

echo "== php version / sapi =="
_r "## php version"
php -v 2>/dev/null | head -1 | tee -a "$REPORT" || _r "php cli not found"
_r ""

echo "== PATCH STATUS (changelog, not version number) =="
_r "## patch status (package changelog)"
bash "$WORKDIR/discovery/patch_status.sh" | tee -a "$REPORT"
_r ""

echo "== auditd =="
_r "## auditd"
if [[ -f /var/log/audit/audit.log ]]; then
  _r "audit log present"
else
  _r "no auditd log"
fi
_r ""

echo "== rotated access logs (retro scope) =="
_r "## rotated logs"
ls -l /var/log/nginx/access.log* /var/log/apache2/access.log* /var/log/httpd/access_log* 2>/dev/null |
  head -50 | tee -a "$REPORT" || true
_r ""

# ---- capabilities (gates rule `needs`)
: >"$P2S_STATE_DIR/capabilities.txt"
[[ -n $(ls /var/log/nginx/access.log* /var/log/apache2/access.log* /var/log/httpd/access_log* 2>/dev/null) ]] && echo "access_log" >>"$P2S_STATE_DIR/capabilities.txt"
[[ -n $(ls /var/log/php*-fpm*.log /var/log/php-fpm/*.log 2>/dev/null) ]] && echo "fpm_error" >>"$P2S_STATE_DIR/capabilities.txt"
[[ -f /var/log/audit/audit.log ]] && echo "auditd" >>"$P2S_STATE_DIR/capabilities.txt"
[[ -d /var/log/journal ]] && echo "journal" >>"$P2S_STATE_DIR/capabilities.txt"
[[ -d /var/lib/php/sessions || -d /var/lib/php/session ]] && echo "sessions" >>"$P2S_STATE_DIR/capabilities.txt"
[[ $(id -u) -eq 0 ]] && echo "proc" >>"$P2S_STATE_DIR/capabilities.txt"

echo ""
echo "discovery complete: $REPORT"
echo "capabilities: $(tr '\n' ' ' <"$P2S_STATE_DIR/capabilities.txt")"
