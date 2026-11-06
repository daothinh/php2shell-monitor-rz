#!/usr/bin/env bash
# scan.sh - one batch: plugins -> matcher -> single alert.
# Read-only on the host; writes only under WORKDIR/projects/<project>/devices/<device>.
set -u
WORKDIR=${WORKDIR:-/opt/php2shell-monitor}
export WORKDIR
source "$WORKDIR/lib/common.sh"
source "$WORKDIR/lib/log.sh"
source "$WORKDIR/lib/paths.sh"
source "$WORKDIR/lib/state.sh"
source "$WORKDIR/lib/stream.sh"
source "$WORKDIR/lib/health.sh"

p2s_device_init || exit 1
# env thắng conf (xem p2s_source_conf trong lib/common.sh)
p2s_source_conf "$WORKDIR/conf/default.conf"

# BATCH_ID phải DUY NHẤT. Trước đây chỉ dùng giây UTC, nên hai batch trong cùng
# một giây (scan chạy tay `once` ngay sau tick của supervisor, hoặc retro-hunt
# cùng giây) sinh CÙNG batch_id. Hệ quả không phải "chỉ một tin bị trùng" mà là
# một alert BỊ MẤT: server khoá UNIQUE(device_id, batch_id) nên alert thứ hai bị
# INSERT OR IGNORE nuốt, trong khi Telegram vẫn gửi tin thứ hai — chat có tin mà
# DB không có, mất luôn evidence và khả năng tra cứu.
#
# Hậu tố thứ tự: nếu batch_id vừa tính đã tồn tại (queue hoặc evidence), tăng
# đuôi -1, -2... cho tới khi chưa ai dùng.
BATCH_ID=$(date -u +%Y%m%dT%H%M%SZ)
_p2s_batch_taken() {
  local id=$1
  [[ -s $P2S_ALERT_DIR/queue.jsonl ]] &&
    grep -qF "\"batch_id\":\"$id\"" "$P2S_ALERT_DIR/queue.jsonl" 2>/dev/null && return 0
  [[ -e $P2S_EVIDENCE_DIR/$id.jsonl ]] && return 0
  return 1
}
_p2s_base=$BATCH_ID
_seq=0
while _p2s_batch_taken "$BATCH_ID"; do
  _seq=$((_seq + 1))
  (( _seq > 99 )) && break
  BATCH_ID="$_p2s_base-$_seq"
done
unset _p2s_base _seq
WINDOW_END=$(utc_epoch)
WINDOW_START=$(state_last_batch)
[[ $WINDOW_START -gt 0 ]] || WINDOW_START=$((WINDOW_END - ${BATCH_INTERVAL:-300}))

# jq không bắt buộc (rule pack đọc bằng lib/jsonl.awk). Có thì cài/ dùng cho
# phần hiển thị; thiếu vẫn chạy bình thường.
p2s_want_jq --quiet || true

LOCK=$P2S_DEVICE_RUN_DIR/scan.lock
# catchup.sh đã giữ scan.lock và truyền fd 9 xuống (P2S_LOCK_HELD=1). Mở lại
# fd trên cùng file sẽ tạo open-file-description MỚI, và flock tính theo
# open-file-description chứ không theo inode — flock -n ở đây sẽ thất bại vì
# chính khoá của cha, và lượt quét bù tự chặn nó. Kiểm fd thật (không tin biến
# môi trường suông): fd 9 phải còn mở mới được bỏ qua bước lấy khoá.
if [[ ${P2S_LOCK_HELD:-0} == 1 && -e /proc/self/fd/9 ]]; then
  :
else
  exec 9>"$LOCK"
  flock -n 9 || { log_info "scan already running; batch skipped"; exit 0; }
fi

STREAM=$P2S_TMP_DIR/stream.$BATCH_ID.tsv
HITS=$P2S_TMP_DIR/hits.$BATCH_ID.tsv
: >"$STREAM"
: >"$HITS"

# ------------------------------------------------------------- 1. plugin stream
log_info "batch $BATCH_ID: $PROJECT/$DEVICE: running plugins"
bash "$WORKDIR/engine/plugins.sh" >>"$STREAM" 2>>"$P2S_DEVICE_RUN_DIR/plugins.err"

# 1b. Sức khoẻ của CHÍNH monitor. Plugin ghi state/health.tsv khi một nguồn
# liên tiếp thất bại (timeout đọc, không phải regular file, journal không đọc
# được). Tới ngưỡng thì health.events có dòng, và ở đây nó được chuyển thành
# record stream source=health để rule P2S-090 bắt — nghĩa là "monitor bị mù"
# cũng đi lên Telegram như một cảnh báo, thay vì thất bại im lặng.
p2s_health_sweep >>"$STREAM" 2>>"$P2S_DEVICE_RUN_DIR/plugins.err"

# Whitelist: one PCRE per line, applied to the whole record (which ends with the raw line).
WL=$WORKDIR/conf/whitelist.conf
if [[ -s $WL ]] && grep -qvE '^[[:space:]]*(#|$)' "$WL"; then
  grep -vE -f <(grep -vE '^[[:space:]]*(#|$)' "$WL") "$STREAM" >"$STREAM.wl" 2>/dev/null || true
  [[ -f $STREAM.wl ]] && mv -f -- "$STREAM.wl" "$STREAM"
fi

# ------------------------------------------------------------- 2. rule matching
bash "$WORKDIR/engine/rule_match.sh" "$STREAM" >"$HITS" 2>>"$P2S_DEVICE_RUN_DIR/engine.err"

# ------------------------------------------------------------- 3. one alert
bash "$WORKDIR/engine/report.sh" "$HITS" "$BATCH_ID" "$WINDOW_START" "$WINDOW_END"

# ------------------------------------------------------------- 4. housekeeping
records=$(wc -l <"$STREAM" 2>/dev/null || echo 0)
hits=$(wc -l <"$HITS" 2>/dev/null || echo 0)
state_prune_offsets
state_save_offsets
state_set_last_batch "$WINDOW_END"
rm -f -- "$STREAM" "$HITS"

log_info "batch $BATCH_ID complete: $records record(s), $hits hit(s)"
