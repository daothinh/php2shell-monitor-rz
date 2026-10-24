#!/usr/bin/env bash
# accesslog_nginx.sh - nginx access logs. Read-only tail by offset.
set -u
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_batch_common.sh"

plugin_name=accesslog_nginx
export plugin_name

nginx_access_files() {
  local -a out=()
  local f
  for f in ${NGINX_ACCESS:-} /var/log/nginx/access.log /var/log/nginx/*access*.log; do
    [[ -z $f ]] && continue
    [[ -f $f && -r $f ]] && out+=("$f")
  done
  ((${#out[@]})) && printf '%s\n' "${out[@]}"
  return 0
}

while IFS= read -r f; do
  [[ -n $f ]] && parse_access_file "$f" access_log
done < <(nginx_access_files)
