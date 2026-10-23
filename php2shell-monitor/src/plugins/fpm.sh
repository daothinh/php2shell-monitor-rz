#!/usr/bin/env bash
# fpm.sh - PHP-FPM master/pool error logs (plan 3.2.C, strongest T2 source).
# Patterns per plan 6.1: P2S-010 (memory), P2S-011 (signal 11), P2S-018 (exit
# codes 70/137), P2S-019 (worker churn - count fed to aggregator).
set -u
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_batch_common.sh"

plugin_name=fpm

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
  local line=$1
  local ts pid
  ts=$(t_extract_fpm_ts "$line")
  P2S_TS=${ts:-$(utc_now)}
  # pid appears in WARNING: [pool www] child 12345 said...
  pid=$(printf '%s' "$line" | grep -oP 'child \K[0-9]+' | head -1)
  P2S_PID=$pid
  local rule
  case $line in
    *'Allowed memory size of'*|*'Out of memory'*|*'Hard memory limit'*|*'in Unknown on line 0'*)
      rule=P2S-010 ;;
    *'exited on signal'*|*'signal 11'*|*'SIGSEGV'*|*'SIGBUS'*|*'SIGABRT'*)
      rule=P2S-011 ;;
    *'exit code 70'*|*'exit code 137'*|*'execution timed out'*)
      rule=P2S-018 ;;
    *)
      rule=- ;;
  esac
  emit_record fpm_error "" "" "" "" "" "" "$pid" "" "" "$rule" "$line"
}

plugin_run() {
  local f
  while IFS= read -r f; do
    [[ -n $f ]] && batch_read "$f" parse_fpm_line
  done < <(fpm_log_files)
}

plugin_run
exit 0
