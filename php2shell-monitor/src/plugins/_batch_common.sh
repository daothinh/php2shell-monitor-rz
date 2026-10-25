#!/usr/bin/env bash
# _batch_common.sh - shared helpers for batch plugins: offset/inode-safe tail
# with line tracking, plus the fast access-log parser.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/stream.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/paths.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/state.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/time_utc.sh"

p2s_device_init || exit 1
# Each plugin process owns the offsets of the files it read; persist them on exit.
trap 'state_save_offsets' EXIT

# batch_read <file> <parse_fn>
# Reads bytes after the stored offset, calls parse_fn with (line, line_number),
# and advances the offset to the last complete newline. Rotation restarts at 0.
batch_read() {
  local file=$1 parse_fn=$2
  [[ -f $file && -r $file ]] || return 0
  local ino size pos line_no
  ino=$(stat -c '%i' -- "$file") || return 0
  size=$(stat -c '%s' -- "$file") || return 0
  IFS=$'\t' read -r pos line_no <<<"$(state_offset_get "$file" "$ino")"
  (( pos <= size )) || { pos=0; line_no=0; }
  (( size > pos )) || return 0

  local chunk="$P2S_TMP_DIR/batch.chunk.$$"
  tail -c +"$((pos + 1))" -- "$file" 2>/dev/null >"$chunk"
  local complete_bytes newpos
  if [[ $(tail -c1 -- "$chunk" 2>/dev/null | wc -l) -eq 0 ]]; then
    # last line has no newline yet: keep it for the next batch.
    # LC_ALL=C: length() must count BYTES to match head -c (UTF-8 locale counts chars).
    complete_bytes=$(LC_ALL=C awk '{ n += length($0) + 1 } END { print n - 1 }' "$chunk" 2>/dev/null)
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

  # No per-batch event cap: breaking out of this loop advanced the offset to
  # `newpos` anyway, so every line past the cap was skipped forever. Reading the
  # whole chunk is the only way no log line is silently lost.
  local count=0 line
  while IFS= read -r line; do
    [[ -z $line ]] && continue
    count=$((count + 1))
    line_no=$((line_no + 1))
    P2S_FILE=$file
    P2S_LINE=$line_no
    export P2S_FILE P2S_LINE
    "$parse_fn" "$line" || true
  done <"$chunk"

  state_offset_set "$file" "$ino" "$newpos" "$line_no"
  rm -f -- "$chunk"
  return 0
}

# parse_access_file <file> <source>
# Bulk-parses new access-log bytes through lib/accesslog.awk, preserving both
# the byte offset and the absolute line number of every emitted record.
parse_access_file() {
  local file=$1 src=$2
  [[ -f $file && -r $file ]] || return 0
  local ino size pos line_no
  ino=$(stat -c '%i' -- "$file") || return 0
  size=$(stat -c '%s' -- "$file") || return 0
  IFS=$'\t' read -r pos line_no <<<"$(state_offset_get "$file" "$ino")"
  (( pos <= size )) || { pos=0; line_no=0; }
  (( size > pos )) || return 0

  local chunk="$P2S_TMP_DIR/access.chunk.$$"
  tail -c +"$((pos + 1))" -- "$file" 2>/dev/null >"$chunk"
  local newpos
  if [[ $(tail -c1 -- "$chunk" 2>/dev/null | wc -l) -eq 0 ]]; then
    local complete_bytes
    # LC_ALL=C: length() must count BYTES to match head -c (UTF-8 counts chars).
    complete_bytes=$(LC_ALL=C awk '{ n += length($0) + 1 } END { print n - 1 }' "$chunk" 2>/dev/null)
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

  local emitted=0
  if [[ -s $chunk ]]; then
    # accesslog.awk prints FILENAME/FNR; override both with the real path and
    # an absolute line number derived from the stored counter.
    awk -f "$P2S_SRC_DIR/lib/accesslog.awk" -v src="$src" \
        -v realfile="$file" -v startline="$line_no" "$chunk" | tee "$chunk.out"
    emitted=$(wc -l <"$chunk.out")
  fi
  rm -f -- "$chunk" "$chunk.out"

  state_offset_set "$file" "$ino" "$newpos" "$((line_no + emitted))"
  return 0
}

# batch_parse_awk <file> <source> <awkfile>
# Bulk-parses new bytes of an error-style log through a pure-awk parser.
# The per-line bash path (batch_read + parse_fn) forks ~2.5ms per line, so a
# 100k-line FPM log after an attack burst ran past the plugin timeout and the
# batch never finished. awk does the same work in one process.
batch_parse_awk() {
  local file=$1 src=$2 awkf=$3
  [[ -f $file && -r $file ]] || return 0
  local ino size pos line_no
  ino=$(stat -c '%i' -- "$file") || return 0
  size=$(stat -c '%s' -- "$file") || return 0
  IFS=$'\t' read -r pos line_no <<<"$(state_offset_get "$file" "$ino")"
  (( pos <= size )) || { pos=0; line_no=0; }
  (( size > pos )) || return 0

  local chunk="$P2S_TMP_DIR/awk.chunk.$$"
  tail -c +"$((pos + 1))" -- "$file" 2>/dev/null >"$chunk"
  local newpos
  if [[ $(tail -c1 -- "$chunk" 2>/dev/null | wc -l) -eq 0 ]]; then
    # last line has no newline yet: leave it for the next batch
    local complete_bytes
    complete_bytes=$(LC_ALL=C awk '{ n += length($0) + 1 } END { print n - 1 }' "$chunk" 2>/dev/null)
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

  local emitted=0
  if [[ -s $chunk ]]; then
    awk -f "$P2S_SRC_DIR/lib/$awkf" -v src="$src" \
        -v realfile="$file" -v startline="$line_no" "$chunk" | tee "$chunk.out"
    emitted=$(wc -l <"$chunk.out")
  fi
  rm -f -- "$chunk" "$chunk.out"

  state_offset_set "$file" "$ino" "$newpos" "$((line_no + emitted))"
  return 0
}
