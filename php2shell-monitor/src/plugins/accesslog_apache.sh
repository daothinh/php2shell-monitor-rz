#!/usr/bin/env bash
# accesslog_apache.sh - apache access logs (plan 3.2.B). Read-only tail by offset.
set -u
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_batch_common.sh"

plugin_name=accesslog_apache

apache_access_files() {
  local -a out=()
  local f
  for f in ${APACHE_ACCESS:-} /var/log/apache2/access.log /var/log/apache2/other_vhosts_access.log \
           /var/log/httpd/access_log /var/log/httpd/*access_log*; do
    [[ -z $f ]] && continue
    [[ -f $f && -r $f ]] && out+=("$f")
  done
  ((${#out[@]})) && printf '%s\n' "${out[@]}"
  return 0
}

plugin_run() {
  local f
  while IFS= read -r f; do
    [[ -n $f ]] && parse_access_file "$f" access_log
  done < <(apache_access_files)
}

plugin_run
exit 0
