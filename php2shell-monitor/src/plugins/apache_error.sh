#!/usr/bin/env bash
# apache_error.sh - apache error log: mod_php crashes and fatal errors.
set -u
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
  local line=$1 ts='' apid=''
  # [Wed Oct 21 13:37:00.123456 2026] [core:error] [pid 1234] ...
  # bash builtin regex: forking grep+head per line costs ~1ms, which turns a
  # large error log into a plugin timeout.
  if [[ $line =~ ^\[[A-Za-z]{3}\ [A-Za-z]{3}\ [0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+\ [0-9]{4}\] ]]; then
    ts=${BASH_REMATCH[0]}
  fi
  [[ $line =~ pid\ ([0-9]+) ]] && apid=${BASH_REMATCH[1]}
  if [[ -n $ts ]]; then
    ts=$(date -d "${ts:1:${#ts}-2}" +%s 2>/dev/null) && ts=$(epoch_to_utc "$ts") || ts=""
  fi
  P2S_TS=${ts:-$(utc_now)}; export P2S_TS
  emit_record apache_error "$P2S_FILE" "$P2S_LINE" "" "" "" "" "" \
    "$apid" "$line" "-"
}

while IFS= read -r f; do
  [[ -n $f ]] && batch_parse_awk "$f" apache_error fpmlog.awk
done < <(apache_error_files)
