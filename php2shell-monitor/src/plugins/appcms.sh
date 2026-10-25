#!/usr/bin/env bash
# appcms.sh - application logs: WordPress debug, Laravel, mail (web uid only).
set -u
source "$(dirname "${BASH_SOURCE[0]}")/_batch_common.sh"

plugin_name=appcms
export plugin_name
APP_RE='PHP Fatal error|Allowed memory size of|Out of memory|exited on signal|segfault'

appcms_files() {
  local -a out=()
  local f
  for f in /var/www/*/wp-content/debug.log /var/www/*/*/wp-content/debug.log \
           /home/*/public_html/wp-content/debug.log \
           /var/www/*/storage/logs/laravel.log \
           /home/*/public_html/storage/logs/laravel.log; do
    [[ -f $f && -r $f ]] && out+=("$f")
  done
  ((${#out[@]})) && printf '%s\n' "${out[@]}"
  return 0
}

parse_appcms_line() { # <line>
  local line=$1 ts
  printf '%s' "$line" | grep -qP "$APP_RE" || return 0
  ts=$(t_extract_journal_ts "$line" || t_syslog_noyear_to_utc "${line:0:15}" || utc_now)
  P2S_TS=$ts; export P2S_TS
  emit_record appcms "$P2S_FILE" "$P2S_LINE" "" "" "" "" "" "" "$line" "-"
}

while IFS= read -r f; do
  [[ -n $f ]] && batch_read "$f" parse_appcms_line
done < <(appcms_files)

# mail logs: only lines showing the web user sending mail (shell spam)
for f in /var/log/mail.log /var/log/maillog; do
  [[ -f $f && -r $f ]] || continue
  grep -nP 'www-data|apache@' "$f" 2>/dev/null |
  while IFS=: read -r no line; do
    P2S_TS=$(utc_now); export P2S_TS
    emit_record appcms "$f" "$no" "" "" "" "" "" "" "$line" "-"
  done
done
