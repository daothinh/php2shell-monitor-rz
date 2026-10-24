#!/usr/bin/env bash
# scan.sh - one batch: plugins -> matcher -> single alert.
# Read-only on the host; writes only under WORKDIR/projects/<project>/devices/<device>.
set -u
WORKDIR=${WORKDIR:-/opt/php2shell-monitor}
export WORKDIR
# shellcheck source=/dev/null
source "$WORKDIR/lib/common.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/log.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/paths.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/state.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/stream.sh"

p2s_device_init || exit 1
if [[ -f $WORKDIR/conf/default.conf ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$WORKDIR/conf/default.conf"
  set +a
fi

BATCH_ID=$(date -u +%Y%m%dT%H%M%SZ)
WINDOW_END=$(utc_epoch)
WINDOW_START=$(state_last_batch)
[[ $WINDOW_START -gt 0 ]] || WINDOW_START=$((WINDOW_END - ${BATCH_INTERVAL:-300}))

LOCK=$P2S_DEVICE_RUN_DIR/scan.lock
exec 9>"$LOCK"
flock -n 9 || { log_info "scan already running; batch skipped"; exit 0; }

STREAM=$P2S_TMP_DIR/stream.$BATCH_ID.tsv
HITS=$P2S_TMP_DIR/hits.$BATCH_ID.tsv
: >"$STREAM"
: >"$HITS"

# ------------------------------------------------------------- 1. plugin stream
log_info "batch $BATCH_ID: $PROJECT/$DEVICE: running plugins"
bash "$WORKDIR/engine/plugins.sh" >>"$STREAM" 2>>"$P2S_DEVICE_RUN_DIR/plugins.err"

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
