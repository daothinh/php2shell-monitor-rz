#!/usr/bin/env bash
# apache_error.sh - apache error log: mod_php crashes and fatal errors.
set -u
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_batch_common.sh"

plugin_name=apache_error
export plugin_name

apache_error_files() {
  local -a out=()
  local f
  for f in ${APACHE_ERROR:-} /var/log/apache2/error.log /var/log/httpd/error_log; do
    [[ -z $f ]] && continue
    [[ -f $f && -r $f ]] && out+=("$f")
  done
  ((${#out[@]})) && printf '%s\n' "${out[@]}"
  return 0
}

parse_apache_error_line() {
  local line=$1 ts
  # [Wed Oct 21 13:37:00.123456 2026] [core:error] [pid 1234] ...
  ts=$(printf '%s' "$line" | grep -oP '^\[[A-Za-z]{3} [A-Za-z]{3} \d{2} \d{2}:\d{2}:\d{2}\.\d+ \d{4}\]' | head -1)
  if [[ -n $ts ]]; then
    ts=$(date -d "${ts:1:${#ts}-2}" +%s 2>/dev/null) && ts=$(epoch_to_utc "$ts") || ts=""
  fi
  P2S_TS=${ts:-$(utc_now)}; export P2S_TS
  emit_record apache_error "$P2S_FILE" "$P2S_LINE" "" "" "" "" "" \
    "$(printf '%s' "$line" | grep -oP 'pid \K[0-9]+' | head -1)" "$line" "-"
}

while IFS= read -r f; do
  [[ -n $f ]] && batch_read "$f" parse_apache_error_line
done < <(apache_error_files)
