#!/usr/bin/env bash
# state.sh - per-log-file read offsets: inode, byte position and line number.
# The line number is what makes an alert traceable back to `file:line`.
[[ -n ${P2S_STATE_SH:-} ]] && return 0
P2S_STATE_SH=1
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

P2S_OFFSETS_FILE=${P2S_OFFSETS_FILE:-}

# Device dirs are created by p2s_device_init() after this file is sourced, so
# the offsets path is resolved on use.
_offsets_file() {
  [[ -n $P2S_OFFSETS_FILE ]] && { printf '%s' "$P2S_OFFSETS_FILE"; return 0; }
  printf '%s/offsets.tsv' "$P2S_STATE_DIR"
}

declare -A P2S_OFF_INO=()
declare -A P2S_OFF_POS=()
declare -A P2S_OFF_LINE=()
declare -A P2S_OFF_TOUCHED=()
P2S_OFF_LOADED=0

state_load_offsets() {
  [[ $P2S_OFF_LOADED -eq 1 ]] && return 0
  P2S_OFF_LOADED=1
  [[ -r $(_offsets_file) ]] || return 0
  local f ino pos line
  while IFS=$'\t' read -r f ino pos line; do
    [[ -z $f ]] && continue
    P2S_OFF_INO["$f"]=$ino
    P2S_OFF_POS["$f"]=$pos
    P2S_OFF_LINE["$f"]=${line:-0}
  done <"$(_offsets_file)"
}

state_save_offsets() {
  local f tmp off
  off=$(_offsets_file)
  [[ -d ${off%/*} ]] || return 0
  tmp="$off.tmp.$$"
  {
    # Only rows this process advanced: siblings own the rest of the file.
    for f in "${!P2S_OFF_TOUCHED[@]}"; do
      printf '%s\t%s\t%s\t%s\n' "$f" "${P2S_OFF_INO[$f]:-0}" "${P2S_OFF_POS[$f]:-0}" \
        "${P2S_OFF_LINE[$f]:-0}"
    done
  } >"$tmp" || return 1
  # Plugins run as separate processes and each keeps its own in-memory view, so
  # a naive rewrite would drop the rows written by its siblings. Merge instead.
  (
    flock -w 5 8 || exit 0
    if [[ -s $off ]]; then
      cat -- "$tmp" "$off" | awk -F'\t' '!seen[$1]++' >"$tmp.merged" &&
        mv -f -- "$tmp.merged" "$off"
      rm -f -- "$tmp"
    else
      mv -f -- "$tmp" "$off"
    fi
  ) 8>"$off.lock"
  return 0
}

# state_offset_get <path> <current_inode> -> "<byte>\t<line>"
# Inode change (rotation/truncation) restarts at 0/0.
state_offset_get() {
  local path=$1 ino=$2
  state_load_offsets
  if [[ ${P2S_OFF_INO[$path]:-} != "$ino" ]]; then
    printf '0\t0'
    return 0
  fi
  printf '%s\t%s' "${P2S_OFF_POS[$path]:-0}" "${P2S_OFF_LINE[$path]:-0}"
}

state_offset_set() { # <path> <inode> <byte> <line>
  state_load_offsets
  P2S_OFF_INO["$1"]=$2
  P2S_OFF_POS["$1"]=$3
  P2S_OFF_LINE["$1"]=$4
  P2S_OFF_TOUCHED["$1"]=1
}

# Drop entries for files that no longer exist (and have no rotated successor).
state_prune_offsets() {
  local k
  for k in "${!P2S_OFF_POS[@]}"; do
    [[ -e $k ]] && continue
    compgen -G "${k}.*" >/dev/null && continue
    unset 'P2S_OFF_INO[$k]' 'P2S_OFF_POS[$k]' 'P2S_OFF_LINE[$k]'
  done
}
