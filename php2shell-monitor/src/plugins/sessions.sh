#!/usr/bin/env bash
# sessions.sh - session dir anomalies (upload_progress keys, oversized files).
# Never stores session contents: only key names, sizes and counts.
set -u
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_batch_common.sh"

plugin_name=sessions
export plugin_name

session_dirs() {
  local -a out=()
  local d
  for d in ${SESSION_DIRS:-} /var/lib/php/sessions /var/lib/php/session /var/cpanel/php/sessions/*; do
    [[ -z $d ]] && continue
    [[ -d $d && -r $d ]] && out+=("$d")
  done
  ((${#out[@]})) && printf '%s\n' "${out[@]}"
  return 0
}

while IFS= read -r d; do
  [[ -n $d ]] || continue
  upcnt=0
  for f in "$d"/sess_*; do
    [[ -f $f && -r $f ]] || continue
    sz=$(stat -c '%s' -- "$f" 2>/dev/null) || continue
    grep -q 'upload_progress_' "$f" 2>/dev/null || continue
    upcnt=$((upcnt + 1))
    (( sz >= 1048576 )) || continue
    P2S_TS=$(utc_now); export P2S_TS
    emit_record sessions "$f" 0 "" "" "" "" "" "" \
      "session file $f size=$sz contains upload_progress keys" "-"
  done
  if (( upcnt >= 50 )); then
    P2S_TS=$(utc_now); export P2S_TS
    emit_record sessions "$d" 0 "" "" "" "" "" "" \
      "$upcnt session files contain upload_progress keys in $d" "-"
  fi
done < <(session_dirs)
