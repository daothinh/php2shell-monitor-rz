#!/usr/bin/env bash
# sessions.sh - session dir scan for upload_progress anomalies (P2S-013).
# NEVER stores session contents (user data) — only key names, sizes, counts.
set -u
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_batch_common.sh"

plugin_name=sessions

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

plugin_run() {
  local d f key sz upcnt total
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    upcnt=0
    for f in "$d"/sess_*; do
      [[ -f $f && -r $f ]] || continue
      sz=$(stat -c '%s' -- "$f" 2>/dev/null) || continue
      # count upload_progress keys and check size anomalies without dumping contents
      if grep -q 'upload_progress_' "$f" 2>/dev/null; then
        upcnt=$((upcnt + 1))
        # anomalous: upload_progress key inside a session file larger than 1MB
        if (( sz >= 1048576 )); then
          P2S_TS=$(utc_now)
          P2S_SIZE=$sz
          P2S_FILE=$f
          emit_record sessions "" "" "" "" "" "$sz" "" "size>=1MB with upload_progress key" "$f" "P2S-013" "session file $f size=$sz contains upload_progress"
        fi
      fi
      # oversized session file (memory disclosure residue)
      if (( sz >= 8388608 )); then
        P2S_TS=$(utc_now)
        P2S_SIZE=$sz
        P2S_FILE=$f
        emit_record sessions "" "" "" "" "" "$sz" "" "session file unusually large" "$f" "P2S-013" "session file $f size=$sz"
      fi
    done
    # mass upload_progress activity in one dir
    if (( upcnt >= 50 )); then
      P2S_TS=$(utc_now)
      P2S_SIZE=$upcnt
      emit_record sessions "" "" "" "" "" "$upcnt" "" "mass upload_progress keys" "$d" "P2S-013" "$upcnt session files contain upload_progress keys in $d"
    fi
  done < <(session_dirs)
}

plugin_run
exit 0
