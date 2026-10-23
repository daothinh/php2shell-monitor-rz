#!/usr/bin/env bash
# appcms.sh - app/CMS logs (plan 3.2.H): WP debug, Laravel, mail, cron/persistence.
set -u
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_batch_common.sh"

plugin_name=appcms

appcms_files() {
  local -a out=()
  local f
  for f in /var/www/*/wp-content/debug.log /var/www/*/*/wp-content/debug.log \
           /home/*/public_html/wp-content/debug.log \
           /var/www/*/storage/logs/laravel.log \
           /home/*/public_html/storage/logs/laravel.log \
           /var/log/mail.log /var/log/maillog; do
    [[ -f $f && -r $f ]] && out+=("$f")
  done
  ((${#out[@]})) && printf '%s\n' "${out[@]}"
  return 0
}

parse_appcms_line() {
  local line=$1
  local ts
  ts=$(t_extract_journal_ts "$line" || t_syslog_noyear_to_utc "$(printf '%s' "$line" | cut -c1-15)" || utc_now)
  P2S_TS=$ts
  local rule=-
  case $line in
    *'Allowed memory size of'*|*'Out of memory'*|*'PHP Fatal error'*) rule=P2S-010 ;;
    *'exited on signal'*|*'segfault'*) rule=P2S-011 ;;
  esac
  [[ $rule == - ]] && return 0
  emit_record appcms "" "" "" "" "" "" "" "" "" "$rule" "$line"
}

plugin_run() {
  local f
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    case $f in
      */debug.log|*/laravel.log)
        # fatal lines only, they are rare
        grep -h 'PHP Fatal error\|Allowed memory size\|Out of memory' "$f" 2>/dev/null |
        while IFS= read -r line; do parse_appcms_line "$line"; done
        ;;
      */mail.log|*/maillog)
        # mail sent by web uid indicates shell spam; heavy grep, keep light
        grep -h 'www-data\|apache@' "$f" 2>/dev/null | tail -50 |
        while IFS= read -r line; do parse_appcms_line "$line"; done
        ;;
    esac
  done < <(appcms_files)
}

plugin_run
exit 0
