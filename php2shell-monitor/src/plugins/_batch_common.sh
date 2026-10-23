#!/usr/bin/env bash
# shared helpers for batch plugins (offset/inode-safe tail + fast access parser).
set -u
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/../lib/stream.sh"
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/../lib/state.sh"
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/../lib/time_utc.sh"

# batch_read <file> <parse_fn>
# Reads bytes after the stored offset; passes each line to parse_fn; updates
# offset to the last complete newline. Rotation (inode change) restarts at 0.
batch_read() {
  local file=$1 parse_fn=$2
  [[ -f $file && -r $file ]] || return 0
  local ino size pos
  ino=$(stat -c '%i' -- "$file") || return 0
  size=$(stat -c '%s' -- "$file") || return 0
  pos=$(state_offset "$file" "$ino")
  (( pos <= size )) || pos=0
  (( size > pos )) || return 0
  local chunk="$P2S_STATE_DIR/batch.chunk.$$"
  tail -c +"$((pos + 1))" -- "$file" 2>/dev/null >"$chunk"
  local complete_bytes
  if [[ $(tail -c1 -- "$chunk" 2>/dev/null | wc -l) -eq 0 ]]; then
    # incomplete last line: trim to last newline
    complete_bytes=$(awk '{ n += length($0) + 1 } END { print n - 1 }' "$chunk" 2>/dev/null)
    [[ -z $complete_bytes || $complete_bytes -le 0 ]] && complete_bytes=0
    if (( complete_bytes > 0 )); then
      head -c "$complete_bytes" -- "$chunk" >"$chunk.full"
      mv -f -- "$chunk.full" "$chunk"
    else
      : >"$chunk"
    fi
    newpos=$((pos + complete_bytes))
  else
    newpos=$size
  fi
  local count=0 line
  while IFS= read -r line; do
    [[ -z $line ]] && continue
    count=$((count + 1))
    (( count > ${MAX_EVENTS_PER_BATCH:-50000} )) && break
    "$parse_fn" "$line" || true
  done <"$chunk"
  state_offset_set "$file" "$ino" "$newpos"
  rm -f -- "$chunk"
  return 0
}

# Fast access-log parse: whole file at once through awk (no per-line forks).
# Used by access plugins; respects offsets via a temp slice.
parse_access_file() { # <file> <source> [offset] [end]
  local file=$1 src=$2 pos=${3:-0} end=${4:-}
  local -a awk_args=(-f "$P2S_SRC_DIR/lib/accesslog.awk" -v src="$src")
  if (( end > pos )); then
    tail -c +"$((pos + 1))" -- "$file" 2>/dev/null | awk "${awk_args[@]}" | head -c "$((end - pos))" >/dev/null 2>&1
    tail -c +"$((pos + 1))" -- "$file" 2>/dev/null | awk "${awk_args[@]}"
  else
    awk "${awk_args[@]}" "$file"
  fi
}
