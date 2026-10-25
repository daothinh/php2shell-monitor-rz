#!/usr/bin/env bash
# kernel.sh - kernel segfault/OOM via journald or rsyslog files.
# Prefilter is deliberately broad: the rule pack decides severity and id.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/_batch_common.sh"

plugin_name=kernel
export plugin_name
KERNEL_RE='segfault at|Out of memory|Killed process|exited on signal|signal 11'

parse_kernel_line() { # <line> (P2S_FILE/P2S_LINE set by batch_read)
  local line=$1 ts
  printf '%s' "$line" | grep -qP "$KERNEL_RE" || return 0
  ts=$(t_extract_journal_ts "$line" || t_syslog_noyear_to_utc "${line:0:15}" || utc_now)
  P2S_TS=$ts; export P2S_TS
  local kpid=''
  if [[ $line =~ \[([0-9]+)\] ]]; then kpid=${BASH_REMATCH[1]}; fi
  emit_record kernel "$P2S_FILE" "$P2S_LINE" "" "" "" "" "" \
    "$kpid" "$line" "-"
}

last=$(state_last_batch)
if have journalctl && [[ -d /var/log/journal ]]; then
  if (( last > 0 )); then
    since=$(epoch_to_utc "$last")
  else
    since="-30min"
  fi
  n=0
  journalctl -k --since "$since" --output=short-iso --no-pager 2>/dev/null |
  while IFS= read -r line; do
    n=$((n + 1))
    printf '%s' "$line" | grep -qP "$KERNEL_RE" || continue
    ts=$(t_extract_journal_ts "$line" || utc_now)
    P2S_TS=$ts; export P2S_TS
    emit_record kernel "journalctl -k" "$n" "" "" "" "" "" "" "$line" "-"
  done
  exit 0
fi

for f in /var/log/kern.log /var/log/messages /var/log/syslog; do
  [[ -f $f && -r $f ]] || continue
  batch_read "$f" parse_kernel_line
done
