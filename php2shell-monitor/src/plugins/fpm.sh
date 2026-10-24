#!/usr/bin/env bash
# fpm.sh - PHP-FPM master/pool error logs (strongest T2 source).
# Emits every line that looks like a PHP failure; the rule pack decides which
# rule it belongs to. File path and line number travel with each record.
set -u
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_batch_common.sh"

plugin_name=fpm
export plugin_name

fpm_log_files() {
  local -a out=()
  local f
  for f in ${FPM_LOG:-} /var/log/php*-fpm*.log /var/log/php-fpm/*.log \
           /usr/local/cpanel/logs/php-fpm/*.log; do
    [[ -z $f ]] && continue
    [[ -f $f && -r $f ]] && out+=("$f")
  done
  ((${#out[@]})) && printf '%s\n' "${out[@]}"
  return 0
}

parse_fpm_line() {
  local line=$1 ts pid
  ts=$(t_extract_fpm_ts "$line") || ts=$(utc_now)
  P2S_TS=$ts; export P2S_TS
  pid=$(printf '%s' "$line" | grep -oP 'child \K[0-9]+' | head -1)
  emit_record fpm_error "$P2S_FILE" "$P2S_LINE" "" "" "" "" "" "$pid" "$line" "-"
}

while IFS= read -r f; do
  [[ -n $f ]] && batch_read "$f" parse_fpm_line
done < <(fpm_log_files)
