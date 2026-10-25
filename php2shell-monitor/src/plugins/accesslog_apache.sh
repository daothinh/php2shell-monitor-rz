#!/usr/bin/env bash
# accesslog_apache.sh - apache access logs. Read-only tail by offset.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/_batch_common.sh"

plugin_name=accesslog_apache
export plugin_name

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

while IFS= read -r f; do
  [[ -n $f ]] && parse_access_file "$f" access_log
done < <(apache_access_files)
