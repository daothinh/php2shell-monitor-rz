#!/usr/bin/env bash
# _batch_common.sh - shared helpers for batch plugins: offset/inode-safe tail
# with line tracking, plus the fast access-log parser.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/stream.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/paths.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/state.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/time_utc.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/readcap.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/health.sh"

p2s_device_init || exit 1
# Each plugin process owns the offsets of the files it read; persist them on exit.
#
# Trap cũng phải cứu tiến độ của awk: `timeout` gửi TERM, bash chạy trap rồi
# thoát, nhưng process awk con đã chết theo và file tiến độ của nó chưa được
# đọc vào state. Đọc lại ở đây để phần đã quét không bị mất trắng.
P2S_AWK_PROGRESS=${P2S_AWK_PROGRESS:-}
P2S_AWK_FILE=${P2S_AWK_FILE:-}
P2S_AWK_INO=${P2S_AWK_INO:-}
P2S_AWK_BASE=${P2S_AWK_BASE:-0}
trap 'p2s_rescue_progress; state_save_offsets' EXIT

# Trần byte / trần thời gian cho MỘT nguồn trong MỘT batch. Đặt ở _batch_common
# để mọi plugin đọc file đều dùng chung một luật (xem lib/readcap.sh).
P2S_READ_CAP_BYTES=${P2S_READ_CAP_BYTES:-33554432}
P2S_READ_TIMEOUT=${P2S_READ_TIMEOUT:-45}

# Đọc mốc tiến độ awk còn sót lại (nếu plugin bị kill giữa chừng) vào state.
p2s_rescue_progress() {
  [[ -n ${P2S_AWK_PROGRESS:-} && -s ${P2S_AWK_PROGRESS:-} ]] || return 0
  [[ -n ${P2S_AWK_FILE:-} && -n ${P2S_AWK_INO:-} ]] || return 0
  local ppos pline
  IFS=$'\t' read -r ppos pline <"$P2S_AWK_PROGRESS" || return 0
  [[ $ppos =~ ^[0-9]+$ ]] || return 0
  state_offset_set "$P2S_AWK_FILE" "$P2S_AWK_INO" \
    "$(( ${P2S_AWK_BASE:-0} + ppos ))" "${pline:-0}"
  rm -f -- "$P2S_AWK_PROGRESS"
  return 0
}

# p2s_complete_bytes <file>
# Số BYTE của phần đã trọn dòng trong <file>, tức là cắt bỏ dòng dở cuối cùng
# (nếu file không kết thúc bằng newline). Kết quả dùng làm mốc offset mới.
#
# CÔNG THỨC CŨ SAI: `n - 1` với n = tổng (length($0)+1) chỉ đúng khi dòng cuối
# DÀI ĐÚNG 0 byte. Với "line1\nline2\npartial" nó trả 19 = cả file, tức là
# nuốt luôn dòng dở và đẩy offset vào GIỮA dòng. Batch sau đọc từ giữa dòng,
# dòng đầu tiên bị cắt làm đôi nên bóc field sai: ip rỗng, uri rỗng, ts lấy
# nhầm từ đoạn giữa. Đó chính là hiện tượng "no-hits" dù log đầy tấn công.
#
# Đúng phải là: tổng - (độ dài dòng dở) - (1 newline của dòng trước nó).
p2s_complete_bytes() {
  local f=$1
  [[ -f $f ]] || { printf '0'; return 0; }
  # Kết thúc bằng newline => mọi dòng đều trọn, không cắt gì.
  if [[ $(tail -c1 -- "$f" 2>/dev/null | wc -l) -ne 0 ]]; then
    stat -c '%s' -- "$f" 2>/dev/null || printf '0'
    return 0
  fi
  LC_ALL=C awk '
    { n += length($0) + 1; last = length($0) }
    END {
      # n - last - 1 = bỏ dòng dở và newline đứng trước nó
      v = n - last - 1
      print (v > 0 ? v : 0)
    }
  ' "$f" 2>/dev/null || printf '0'
}

# batch_read <file> <parse_fn>
# Reads bytes after the stored offset, calls parse_fn with (line, line_number),
# and advances the offset to the last complete newline. Rotation restarts at 0.
batch_read() {
  local file=$1 parse_fn=$2
  [[ -f $file && -r $file ]] || return 0
  [[ $(p2s_file_kind "$file") == regular ]] || return 0
  local ino size pos line_no
  ino=$(stat -Lc '%i' -- "$file" 2>/dev/null) || return 0
  size=$(stat -Lc '%s' -- "$file" 2>/dev/null) || return 0
  IFS=$'\t' read -r pos line_no <<<"$(state_offset_get "$file" "$ino")"
  (( pos <= size )) || { pos=0; line_no=0; }
  (( size > pos )) || return 0

  local chunk="$P2S_TMP_DIR/batch.chunk.$$"
  p2s_read_chunk "$file" "$pos" "$size" \
    "${P2S_READ_CAP_BYTES:-33554432}" "${P2S_READ_TIMEOUT:-45}" "$chunk" || {
    rm -f -- "$chunk"; return 0; }
  local base=$P2S_RD_BASE newpos line_used
  newpos=$((base + P2S_TRIM_BYTES))
  if (( P2S_RD_TIMEOUT )); then
    # Bị cắt vì trần thời gian: giữ phần đã đọc, batch sau đọc tiếp từ newpos.
    echo "readcap: timeout đọc $file tại byte $newpos (${P2S_READ_TIMEOUT}s)" >&2
  fi
  if (( P2S_RD_JUMPED )); then
    echo "readcap: $file lớn hơn trần — bỏ qua phần đầu, bắt đầu từ byte $base" >&2
  fi

  # No per-batch event cap: breaking out of this loop advanced the offset to
  # `newpos` anyway, so every line past the cap was skipped forever. Reading the
  # whole chunk is the only way no log line is silently lost.
  #
  # Checkpoint giữa vòng lặp: offset từng được ghi SAU khi đọc hết chunk. Với
  # log lớn (container 76 MB = 600k dòng, ~2.4 ms/dòng ở đường bash) plugin bị
  # PLUGIN_TIMEOUT kill trước khi tới dòng cuối, nên không có offset nào được
  # lưu và batch sau đọc lại từ byte 0 — lặp vô hạn, mỗi batch đều rc=124.
  # Cứ mỗi CHECKPOINT_LINES dòng lại ghi tiến độ vào state; trap EXIT của
  # _batch_common.sh sẽ persist nốt khi bị TERM.
  #
  # LC_ALL=C để ${#line} đếm BYTE (khớp head -c / tail -c); ở UTF-8 nó đếm ký
  # tự và offset sẽ trôi với log có tiếng Việt hoặc emoji.
  local count=0 line consumed=0 ckpt=${BATCH_CHECKPOINT_LINES:-1000}
  local LC_ALL=C
  line_used=$line_no
  while IFS= read -r line; do
    [[ -z $line ]] && continue
    count=$((count + 1))
    line_used=$((line_used + 1))
    consumed=$((consumed + ${#line} + 1))
    P2S_FILE=$file
    P2S_LINE=$line_used
    export P2S_FILE P2S_LINE
    "$parse_fn" "$line" || true
    if (( count % ckpt == 0 )); then
      state_offset_set "$file" "$ino" "$((base + consumed))" "$line_used"
    fi
  done <"$chunk"

  state_offset_set "$file" "$ino" "$newpos" "$line_used"
  rm -f -- "$chunk"
  return 0
}

# parse_access_file <file> <source>
# Bulk-parses new access-log bytes through lib/accesslog.awk, preserving both
# the byte offset and the absolute line number of every emitted record.
parse_access_file() {
  local file=$1 src=$2
  [[ -f $file && -r $file ]] || return 0
  [[ $(p2s_file_kind "$file") == regular ]] || return 0
  local ino size pos line_no
  ino=$(stat -Lc '%i' -- "$file" 2>/dev/null) || return 0
  size=$(stat -Lc '%s' -- "$file" 2>/dev/null) || return 0
  IFS=$'\t' read -r pos line_no <<<"$(state_offset_get "$file" "$ino")"
  (( pos <= size )) || { pos=0; line_no=0; }
  (( size > pos )) || return 0

  local chunk="$P2S_TMP_DIR/access.chunk.$$"
  p2s_read_chunk "$file" "$pos" "$size" \
    "${P2S_READ_CAP_BYTES:-33554432}" "${P2S_READ_TIMEOUT:-45}" "$chunk" || {
    rm -f -- "$chunk"; return 0; }
  local newpos=$((P2S_RD_BASE + P2S_TRIM_BYTES))

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

# batch_parse_awk <file> <source> <awkfile> [-v name=value ...]
# Bulk-parses new bytes of an error-style log through a pure-awk parser.
# The per-line bash path (batch_read + parse_fn) forks ~2.5ms per line, so a
# 100k-line FPM log after an attack burst ran past the plugin timeout and the
# batch never finished. awk does the same work in one process.
#
# Tham số sau <awkfile> được chuyển nguyên sang awk (ví dụ -v name=lab-1), để
# plugin truyền regex/tham số riêng mà không cần file awk riêng cho từng nguồn.
batch_parse_awk() {
  local file=$1 src=$2 awkf=$3
  shift 3
  [[ -f $file && -r $file ]] || return 0
  [[ $(p2s_file_kind "$file") == regular ]] || return 0
  local ino size pos line_no
  ino=$(stat -Lc '%i' -- "$file" 2>/dev/null) || return 0
  size=$(stat -Lc '%s' -- "$file" 2>/dev/null) || return 0
  IFS=$'\t' read -r pos line_no <<<"$(state_offset_get "$file" "$ino")"
  (( pos <= size )) || { pos=0; line_no=0; }
  (( size > pos )) || return 0

  local chunk="$P2S_TMP_DIR/awk.chunk.$$"
  p2s_read_chunk "$file" "$pos" "$size" \
    "${P2S_READ_CAP_BYTES:-33554432}" "${P2S_READ_TIMEOUT:-45}" "$chunk" || {
    rm -f -- "$chunk"; return 0; }
  local newpos=$((P2S_RD_BASE + P2S_TRIM_BYTES))

  local emitted=0
  if [[ -s $chunk ]]; then
    # File tiến độ: awk ghi "<byte_tương_đối_trong_chunk>\t<dòng_tương_đối>"
    # định kỳ. Nếu plugin bị PLUGIN_TIMEOUT cắt giữa chừng, trap EXIT gọi
    # p2s_rescue_progress đọc nốt mốc này — phần đã quét không bị mất trắng.
    # Mốc là TƯƠNG ĐỐI vì base có thể đã nhảy (readcap); P2S_AWK_BASE cộng lại.
    local prog="$P2S_TMP_DIR/awk.prog.$$"
    : >"$prog"
    P2S_AWK_PROGRESS=$prog
    P2S_AWK_FILE=$file
    P2S_AWK_INO=$ino
    P2S_AWK_BASE=$P2S_RD_BASE
    awk -f "$P2S_SRC_DIR/lib/$awkf" -v src="$src" \
        -v realfile="$file" -v startline="$line_no" \
        -v basepos=0 -v progressfile="$prog" \
        -v progress_every="${BATCH_CHECKPOINT_LINES:-2000}" \
        "$@" "$chunk" | tee "$chunk.out"
    emitted=$(wc -l <"$chunk.out")
    if [[ -s $prog ]]; then
      local ppos pline
      IFS=$'\t' read -r ppos pline <"$prog"
      if [[ $ppos =~ ^[0-9]+$ ]] && (( P2S_RD_BASE + ppos > pos )); then
        state_offset_set "$file" "$ino" "$((P2S_RD_BASE + ppos))" "$pline"
      fi
    fi
    rm -f -- "$prog"
    P2S_AWK_PROGRESS=''
  fi

  # emitted = số DÒNG ĐÃ PHÁT, không phải số dòng đã đọc. Với parser có lọc
  # (docker: chỉ giữ dòng khớp marker) hai số này khác nhau, nên đếm riêng số
  # dòng đã đọc để line_no tuyệt đối vẫn đúng.
  local read_lines=0
  [[ -s $chunk ]] && read_lines=$(LC_ALL=C awk 'END { print NR }' "$chunk" 2>/dev/null)
  [[ -n $read_lines ]] || read_lines=$emitted

  rm -f -- "$chunk" "$chunk.out"

  state_offset_set "$file" "$ino" "$newpos" "$((line_no + read_lines))"
  return 0
}
