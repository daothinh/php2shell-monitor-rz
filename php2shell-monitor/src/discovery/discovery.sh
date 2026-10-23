#!/usr/bin/env bash
# discovery.sh - 100% READ-ONLY host discovery (plan 3.4, approval-gated).
# Output: reports/log-map-actual.md + key-filtered config lines (no secret dump).
set -u
WORKDIR=${WORKDIR:-/tmp/php2shell-monitor}
# shellcheck source=/dev/null
source "$WORKDIR/lib/common.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/log.sh"

REPORT=$P2S_REPORT_DIR/log-map-actual.md
mkdir -p -- "$P2S_REPORT_DIR"

: >"$REPORT"
_r() { printf '%s\n' "$*" >>"$REPORT"; }

_r "# php2shell-monitor discovery — $(utc_now)"
_r ""
_r "Host: $(hostname 2>/dev/null || echo unknown) | kernel: $(uname -r)"
_r "/tmp mount: $(findmnt -n -o FSTYPE,SIZE,OPTIONS /tmp 2>/dev/null | head -1 || echo unknown)"
_r "tmp cleanup: $(systemctl is-active systemd-tmpfiles-clean.timer 2>/dev/null || echo unknown)"
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
grep -RhE '^\s*(error_log|access\.log|slowlog|catch_workers_output|request_slowlog_timeout|php_admin_value\[(error_log|memory_limit)\]|php_admin_flag\[session\.upload_progress\.enabled\])' /etc/php* /etc/php-fpm* 2>/dev/null | tee -a "$REPORT" || true
_r ""

echo "== fpm effective ini (NOT cli php -i) =="
_r "## fpm effective ini"
for b in /usr/sbin/php-fpm* /usr/local/sbin/php-fpm*; do
  [[ -x $b ]] || continue
  _r "-- $b"
  "$b" -i 2>/dev/null | grep -E '^(error_log|memory_limit|session\.save_path|session\.upload_progress\.enabled|opcache\.file_cache)\b' | tee -a "$REPORT" || true
done
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
  _r "audit log present: $(ls -l /var/log/audit/audit.log 2>/dev/null)"
else
  _r "no auditd log"
fi
_r ""

echo "== coredump =="
_r "## coredump"
if have coredumpctl; then
  coredumpctl list --no-pager 2>/dev/null | tail -5 | tee -a "$REPORT" || true
else
  ls /var/crash /var/spool/abrt 2>/dev/null | tee -a "$REPORT" || _r "no coredump handler"
fi
_r ""

echo "== modsec =="
_r "## modsec / waf"
find /var/log -maxdepth 2 -iname '*modsec*' 2>/dev/null | tee -a "$REPORT" || true
[[ -f /var/log/suricata/eve.json ]] && _r "suricata eve.json present"
_r ""

echo "== sessions =="
_r "## session dirs"
ls -ld /var/lib/php/sessions /var/lib/php/session /tmp 2>/dev/null | head -3 | tee -a "$REPORT" || true
_r ""

echo "== journal persistent =="
_r "## journal"
[[ -d /var/log/journal ]] && _r "persistent journal" || _r "volatile journal"
_r ""

echo "== kernel segfault sample (since leak window) =="
_r "## kernel segfault/OOM since 2026-10-17"
have journalctl && journalctl -k --since "2026-10-17" --no-pager 2>/dev/null | grep -ciE 'php-fpm.*(segfault|signal 11)' | tee -a "$REPORT" || true
_r ""

echo "== rotated access logs available (retro-hunt scope) =="
_r "## rotated logs"
ls -l /var/log/nginx/access.log* /var/log/apache2/access.log* /var/log/httpd/access_log* 2>/dev/null | head -50 | tee -a "$REPORT" || true
_r ""

# write capabilities file consumed by rules loader
: >"$P2S_STATE_DIR/capabilities.txt"
grep -qP '^\S+\taccess_log\t' /dev/null 2>/dev/null || true
[[ -n $(ls /var/log/nginx/access.log* /var/log/apache2/access.log* /var/log/httpd/access_log* 2>/dev/null) ]] && echo "access_log" >>"$P2S_STATE_DIR/capabilities.txt"
[[ -n $(ls /var/log/php*-fpm*.log /var/log/php-fpm/*.log 2>/dev/null) ]] && echo "fpm_error" >>"$P2S_STATE_DIR/capabilities.txt"
[[ -f /var/log/audit/audit.log ]] && echo "auditd" >>"$P2S_STATE_DIR/capabilities.txt"
[[ -d /var/log/journal ]] && echo "journal" >>"$P2S_STATE_DIR/capabilities.txt"
[[ -d /var/lib/php/sessions || -d /var/lib/php/session ]] && echo "sessions" >>"$P2S_STATE_DIR/capabilities.txt"
[[ $(id -u) -eq 0 ]] && echo "proc" >>"$P2S_STATE_DIR/capabilities.txt"
have nginx && grep -qs 'js_access\|njs' /etc/nginx/nginx.conf 2>/dev/null && echo "njs" >>"$P2S_STATE_DIR/capabilities.txt"

echo ""
echo "discovery complete: $REPORT"
