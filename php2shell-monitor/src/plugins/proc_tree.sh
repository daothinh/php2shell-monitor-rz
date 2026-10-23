#!/usr/bin/env bash
# proc_tree.sh - /proc scan: web-worker parent spawning shells/interpreters
# (P2S-024 HIGH) and suspicious cmdlines (P2S-025 CRITICAL). Root only.
set -u
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_batch_common.sh"

plugin_name=proc_tree

PARENT_RE='(^|/)(php-fpm|php-cgi|lsphp|frankenphp|httpd|apache2)[0-9.]*$'
CHILD_RE='(^|/)(sh|bash|dash|zsh|busybox|python3?|perl|nc|ncat|socat|curl|wget)$'

proc_cmdline() { # <pid> -> NUL-separated args joined with space
  tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null | sed 's/ $//'
}

plugin_run() {
  [[ ${PROC_SCAN:-1} == 1 ]] || return 0
  [[ $(id -u) -eq 0 ]] || return 0
  local pid ppid pname cname ccmdline line
  # single pass over /proc: build pid->comm map, then child scan
  local -A COMM=()
  for pid in /proc/[0-9]*; do
    local p=${pid##*/}
    COMM[$p]=$(cat "$pid/comm" 2>/dev/null || true)
  done
  for pid in "${!COMM[@]}"; do
    [[ -r /proc/$pid/stat ]] || continue
    ppid=$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null) || continue
    pname=${COMM[$ppid]:-}
    cname=${COMM[$pid]:-}
    [[ -z $pname || -z $cname ]] && continue
    # P2S-024: web worker -> shell/interpreter
    if printf '%s' "$pname" | grep -Pq "$PARENT_RE" && printf '%s' "$cname" | grep -Pq "$CHILD_RE"; then
      ccmdline=$(proc_cmdline "$pid")
      P2S_TS=$(utc_now); P2S_PID=$pid
      emit_record proc "" "" "" "" "" "" "$pid" "" "" "P2S-024" "parent=$pname child=$cname cmd=$ccmdline"
      # P2S-025: suspicious cmdline patterns
      if printf '%s' "$ccmdline" | grep -Pq '/dev/tcp/|mkfifo|base64 -d|bash -i|sh -i|nc -e|python.*socket|/tmp/|/dev/shm/'; then
        emit_record proc "" "" "" "" "" "" "$pid" "" "" "P2S-025" "suspicious cmdline: $ccmdline (parent=$pname)"
      fi
    fi
  done
  return 0
}

plugin_run
exit 0
