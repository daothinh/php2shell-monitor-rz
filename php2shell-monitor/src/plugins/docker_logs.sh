#!/usr/bin/env bash
# docker_logs.sh - container stdout/stderr via `docker logs`. Read-only.
set -u
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_batch_common.sh"

plugin_name=docker_logs
export plugin_name

DOCKER_RE='Allowed memory size of|Out of memory|Hard memory limit|in Unknown on line 0|exited on signal|exit signal|segfault|SIGSEGV|SIGBUS|SIGABRT|upstream prematurely|recv\(\) failed \(104|exit code (70|137)|execution timed out'

have docker || exit 0
docker ps --format '{{.Names}}' 2>/dev/null |
while IFS= read -r c; do
  [[ -z $c ]] && continue
  n=0
  docker logs --since "${DOCKER_LOG_SINCE:-10m}" "$c" 2>&1 |
  while IFS= read -r line; do
    n=$((n + 1))
    printf '%s' "$line" | grep -qP "$DOCKER_RE" || continue
    P2S_TS=$(utc_now); export P2S_TS
    emit_record docker "docker:$c" "$n" "" "" "" "" "" "" "[$c] $line" "-"
  done
done
