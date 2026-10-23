#!/usr/bin/env bash
# nginx_error.sh - nginx error log: upstream failures after POST (P2S-014).
set -u
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_batch_common.sh"

plugin_name=nginx_error

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
  local line=$1
  local ts
  # format: 2026/10/21 13:37:00 [error] 123#123: *456 upstream prematurely...
  ts=$(printf '%s' "$line" | grep -oP '^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}' | head -1)
  [[ -n $ts ]] && { ts=$(date -d "$ts" +%s 2>/dev/null) && ts=$(epoch_to_utc "$ts"); } || ts=""
  P2S_TS=${ts:-$(utc_now)}
  local rule=-
  case $line in
    *'upstream prematurely closed'*|*'recv() failed (104'*|*'upstream sent unexpected FastCGI record: 3'*) rule=P2S-014 ;;
  esac
  emit_record nginx_error "" "" "" "" "" "" "" "" "" "$rule" "$line"
}

plugin_run() {
  local f
  while IFS= read -r f; do
    [[ -n $f ]] && batch_read "$f" parse_nginx_error_line
  done < <(nginx_error_files)
}

plugin_run
exit 0
