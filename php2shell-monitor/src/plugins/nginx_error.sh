#!/usr/bin/env bash
# nginx_error.sh - nginx error log: upstream failures after POST.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/_batch_common.sh"

plugin_name=nginx_error
export plugin_name

nginx_error_files() {
  local -a out=()
  local f
  for f in ${NGINX_ERROR:-} /var/log/nginx/error.log; do
    [[ -z $f ]] && continue
    [[ -f $f && -r $f ]] && out+=("$f")
  done
  ((${#out[@]})) && printf '%s\n' "${out[@]}"
  return 0
}

parse_nginx_error_line() {
  local line=$1 ts
  # 2026/10/21 13:37:00 [error] 123#123: *456 upstream prematurely...
  ts=''
  if [[ $line =~ ^[0-9]{4}/[0-9]{2}/[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2} ]]; then
    ts=${BASH_REMATCH[0]}
  fi
  [[ -n $ts ]] && { ts=$(date -d "$ts" +%s 2>/dev/null) && ts=$(epoch_to_utc "$ts"); } || ts=""
  P2S_TS=${ts:-$(utc_now)}; export P2S_TS
  emit_record nginx_error "$P2S_FILE" "$P2S_LINE" "" "" "" "" "" "" "$line" "-"
}

while IFS= read -r f; do
  [[ -n $f ]] && batch_parse_awk "$f" nginx_error fpmlog.awk
done < <(nginx_error_files)
