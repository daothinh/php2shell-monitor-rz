#!/usr/bin/env bash
# kernel.sh - kernel segfault/OOM via journald or rsyslog files (P2S-011 T3).
# Prefers journalctl --since on persistent journal; falls back to syslog/kern.
set -u
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_batch_common.sh"

plugin_name=kernel

emit_kernel_line() { # <line> [source]
  local line=$1 src=${2:-syslog}
  local ts
  ts=$(t_extract_journal_ts "$line" || t_syslog_noyear_to_utc "$(printf '%s' "$line" | cut -c1-15)" || utc_now)
  P2S_TS=$ts
  emit_record kernel "" "" "" "" "" "" "$(printf '%s' "$line" | grep -oP '\[\K[0-9]+(?=\])' | head -1)" "" "" "P2S-011" "$line"
}

plugin_run() {
  # journald persistent (since attack window start)
  if have journalctl && [[ -d /var/log/journal ]]; then
    local since
    since=$(iso_to_epoch "${BASELINE_EXCLUDE_SINCE:-2026-10-17T00:00:00Z}" 2>/dev/null)
    if [[ -n $since ]]; then
      journalctl -k --since "@$since" --output=short-iso --no-pager 2>/dev/null |
      grep -P 'segfault at|Out of memory|Killed process' |
      while IFS= read -r line; do
        emit_kernel_line "$line" journal
      done
      return 0
    fi
  fi
  # rsyslog fallback files (both distros)
  local f
  for f in /var/log/kern.log /var/log/messages /var/log/syslog; do
    [[ -f $f && -r $f ]] || continue
    grep -hP 'segfault at|Out of memory|Killed process' "$f" 2>/dev/null |
    while IFS= read -r line; do
      emit_kernel_line "$line" syslog
    done
  done
}

plugin_run
exit 0
