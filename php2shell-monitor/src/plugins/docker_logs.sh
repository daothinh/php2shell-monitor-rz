#!/usr/bin/env bash
# docker_logs.sh - docker container stdout/stderr via `docker logs` when the
# host runs containers with php-fpm (plan 6.1 source docker_logs). Read-only.
set -u
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_batch_common.sh"

plugin_name=docker_logs

plugin_run() {
  have docker || return 0
  docker ps --format '{{.Names}}' 2>/dev/null |
  while IFS= read -r c; do
    [[ -z $c ]] && continue
    docker logs --since 10m "$c" 2>&1 |
    grep -P 'Allowed memory size of|Out of memory|exited on signal|segfault|PHP Fatal error' |
    while IFS= read -r line; do
      P2S_TS=$(utc_now)
      emit_record docker_logs "" "" "" "" "" "" "" "" "" "P2S-010" "[$c] $line"
    done
  done
  return 0
}

plugin_run
exit 0
