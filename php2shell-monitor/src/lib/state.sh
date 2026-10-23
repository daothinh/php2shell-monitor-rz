#!/usr/bin/env bash
# state.sh - persistent state: log offsets (inode-safe), dedup, sliding aggregation
[[ -n ${P2S_STATE_SH:-} ]] && return 0
P2S_STATE_SH=1
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

P2S_OFFSETS_FILE=${P2S_OFFSETS_FILE:-$P2S_STATE_DIR/offsets.tsv}
P2S_DEDUP_FILE=${P2S_DEDUP_FILE:-$P2S_STATE_DIR/dedup.tsv}

declare -A P2S_OFF_INO=()
declare -A P2S_OFF_POS=()
P2S_OFF_LOADED=0

state_load_offsets() {
  [[ $P2S_OFF_LOADED -eq 1 ]] && return 0
  P2S_OFF_LOADED=1
  [[ -r $P2S_OFFSETS_FILE ]] || return 0
  local path ino pos _rest
  while IFS=$'\t' read -r path ino pos _rest; do
    [[ -z $path || $path == \#* ]] && continue
    [[ $ino =~ ^[0-9]+$ && $pos =~ ^[0-9]+$ ]] || continue
    P2S_OFF_INO["$path"]=$ino
    P2S_OFF_POS["$path"]=$pos
  done <"$P2S_OFFSETS_FILE"
}

state_save_offsets() {
  local tmp="$P2S_OFFSETS_FILE.tmp.$$" k
  (
    umask 077
    printf '# path\tinode\toffset\n'
    for k in "${!P2S_OFF_POS[@]}"; do
      printf '%s\t%s\t%s\n' "$k" "${P2S_OFF_INO[$k]}" "${P2S_OFF_POS[$k]}"
    done | sort
  ) >"$tmp" && mv -f -- "$tmp" "$P2S_OFFSETS_FILE"
}

# Returns stored offset; inode mismatch -> 0 and signals rotation via stdout prefix.
# Usage: state_offset <path> <current_inode>
state_offset() {
  local path=$1 ino=$2
  state_load_offsets
  local prev_ino=${P2S_OFF_INO[$path]:-} prev_pos=${P2S_OFF_POS[$path]:-0}
  if [[ -n $prev_ino && $prev_ino != "$ino" ]]; then
    printf '0'
    return 0
  fi
  printf '%s' "${prev_pos:-0}"
}

state_offset_set() {
  local path=$1 ino=$2 pos=$3
  state_load_offsets
  P2S_OFF_INO["$path"]=$ino
  P2S_OFF_POS["$path"]=$pos
}

# Remove offset entries for files that vanished AND have no rotated successor.
state_prune_offsets() {
  local k keep
  for k in "${!P2S_OFF_POS[@]}"; do
    keep=0
    [[ -e $k ]] && keep=1
    if [[ $keep -eq 0 ]]; then
      compgen -G "${k}.*" >/dev/null && keep=1
    fi
    [[ $keep -eq 0 ]] && unset 'P2S_OFF_INO[$k]' 'P2S_OFF_POS[$k]'
  done
}

# ---------------------------------------------------------------- dedup
# dedup_should_emit <rule> <ip> <uri> [window]
dedup_should_emit() {
  local rule=$1 ip=$2 uri=$3 win=${4:-${DEDUP_WINDOW:-900}}
  local now key
  now=$(utc_epoch)
  key="$rule|$ip|$uri"
  [[ -f $P2S_DEDUP_FILE ]] || return 0
  awk -F'\t' -v now="$now" -v win="$win" -v k="$key" -v f="$P2S_DEDUP_FILE" '
    $4 >= now - win && ($1 "|" $2 "|" $3) == k { found=1 }
    END { exit(found ? 1 : 0) }
  ' "$P2S_DEDUP_FILE"
}

dedup_mark() {
  local rule=$1 ip=$2 uri=$3
  local now
  now=$(utc_epoch)
  printf '%s\t%s\t%s\t%s\n' "$rule" "$ip" "$uri" "$now" >>"$P2S_DEDUP_FILE"
}

# Prune expired dedup rows and cap the file.
dedup_prune() {
  local win=${DEDUP_WINDOW:-900} now tmp
  [[ -f $P2S_DEDUP_FILE ]] || return 0
  now=$(utc_epoch)
  tmp="$P2S_DEDUP_FILE.tmp.$$"
  awk -F'\t' -v now="$now" -v win="$win" '$4 >= now - win' "$P2S_DEDUP_FILE" >"$tmp" &&
    mv -f -- "$tmp" "$P2S_DEDUP_FILE"
}

# ---------------------------------------------------------------- aggregation
# agg_note <rule> <key> <epoch>: append a hit
agg_note() {
  local rule=$1 key=$2 ts=$3
  printf '%s\t%s\n' "$ts" "$key" >>"$P2S_STATE_DIR/agg/$rule.tsv"
}

# agg_prune <rule> <window_s>
agg_prune() {
  local rule=$1 win=$2 f="$P2S_STATE_DIR/agg/$1.tsv" now tmp
  [[ -f $f ]] || return 0
  now=$(utc_epoch)
  tmp="$f.tmp.$$"
  awk -F'\t' -v now="$now" -v win="$win" '$1 >= now - win' "$f" >"$tmp" && mv -f -- "$tmp" "$f"
}

# agg_count <rule> <key> <window_s> -> count within window
agg_count() {
  local rule=$1 key=$2 win=$3 f="$P2S_STATE_DIR/agg/$1.tsv" now
  [[ -f $f ]] || { echo 0; return 0; }
  now=$(utc_epoch)
  awk -F'\t' -v now="$now" -v win="$win" -v k="$key" \
    '$1 >= now - win && $2 == k { c++ } END { print c + 0 }' "$f"
}

# agg_seen_recent <rule> <key> <window_s> -> 0 when an ALERT was already emitted
agg_alert_mark() {
  printf '%s\t%s\n' "$(utc_epoch)" "$2" >>"$P2S_STATE_DIR/agg/$1.alerts.tsv"
}
agg_alert_recent() {
  local rule=$1 key=$2 win=$3 f="$P2S_STATE_DIR/agg/$1.alerts.tsv" now
  [[ -f $f ]] || return 1
  now=$(utc_epoch)
  awk -F'\t' -v now="$now" -v win="$win" -v k="$key" \
    '$1 >= now - win && $2 == k { found=1 } END { exit(found ? 0 : 1) }' "$f"
}

# ---------------------------------------------------------------- seq state
# seq_note <rule> <key> <rule_a> <epoch>
seq_note() {
  printf '%s\t%s\t%s\n' "$2" "$3" "$4" >>"$P2S_STATE_DIR/agg/seq_$1.tsv"
}

# seq_match <rule> <key> <rule_a> <within_s> -> 0 if A happened for key in window
seq_match() {
  local rule=$1 key=$2 ra=$3 win=$4 f="$P2S_STATE_DIR/agg/seq_$1.tsv" now
  [[ -f $f ]] || return 1
  now=$(utc_epoch)
  awk -F'\t' -v now="$now" -v win="$win" -v k="$key" -v ra="$ra" \
    '$1 == k && $2 == ra && $3 >= now - win { found=1 } END { exit(found ? 0 : 1) }' "$f"
}

# ---------------------------------------------------------------- ip event index (correlation)
ip_note() { # <ip> <tier> <rule> [uri]
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >>"$P2S_STATE_DIR/ip_events.tsv"
}

ip_prune() {
  local win=${5:-900} f="$P2S_STATE_DIR/ip_events.tsv" now tmp
  [[ -f $f ]] || return 0
  now=$(utc_epoch)
  tmp="$f.tmp.$$"
  awk -F'\t' -v now="$now" -v win="$win" '$1 != "" { print now "\t" $0 }' /dev/null >/dev/null 2>&1
  # rows are stored with epoch as 5th column; prune by it
  awk -F'\t' -v now="$now" -v win="$win" '($5 + 0) >= now - win' "$f" >"$tmp" &&
    mv -f -- "$tmp" "$f"
}
