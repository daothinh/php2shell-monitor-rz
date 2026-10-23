#!/usr/bin/env bash
# scan.sh - one batch: resolve sources -> plugin streams -> rule eval ->
# score -> alert queue. Read-only on the host; writes only under WORKDIR.
set -u
WORKDIR=${WORKDIR:-/tmp/php2shell-monitor}
BATCH_ID=$(date -u +%Y%m%dT%H%M%SZ)
export P2S_EVENT_DIR=$WORKDIR/run/events-$BATCH_ID

# shellcheck source=/dev/null
source "$WORKDIR/lib/common.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/log.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/safe_fs.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/stream.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/state.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/sql.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/time_utc.sh"
# shellcheck source=/dev/null
source "$WORKDIR/engine/rules.sh"
# shellcheck source=/dev/null
source "$WORKDIR/engine/correlator.sh"
# shellcheck source=/dev/null
source "$WORKDIR/engine/scoring.sh"
# shellcheck source=/dev/null
source "$WORKDIR/engine/baseline.sh"
# shellcheck source=/dev/null
source "$WORKDIR/engine/alert.sh"
# shellcheck source=/dev/null
source "$WORKDIR/engine/plugins.sh"

mkdir -p -- "$P2S_EVENT_DIR" "$P2S_STATE_DIR/agg"
LOCK=$WORKDIR/run/scan.lock
exec 9>"$LOCK"
flock -n 9 || { log_info "scan already running; batch skipped"; exit 0; }

# ------------------------------------------------------------- config
[[ -f $WORKDIR/conf/default.conf ]] && source "$WORKDIR/conf/default.conf"
[[ -f $WORKDIR/conf/rules.conf ]] && true   # JSONL overrides handled by rules.sh

P2S_STREAM=$P2S_STATE_DIR/stream.tsv
P2S_MATCHED=$P2S_STATE_DIR/matched.jsonl
: >"$P2S_STREAM"
: >"$P2S_MATCHED"

# ------------------------------------------------------------- 1. plugin streams
log_info "batch $BATCH_ID: running plugins"
P2S_PLUGINS_DISABLED=$(grep -oP '(?<=^PLUGINS_DISABLED=).+' "$WORKDIR/conf/default.conf" 2>/dev/null | tr -d '"' || true)
export P2S_PLUGINS_DISABLED
run_all_plugins

# Concatenate plugin outputs into one stream (they all print stream TSV).
cat "$P2S_EVENT_DIR"/events-*.jsonl 2>/dev/null >"$P2S_STREAM" || true
rm -rf -- "$P2S_EVENT_DIR"

# Apply whitelist suppression (conf/whitelist.conf PCREs on whole record).
local_wl=$WORKDIR/conf/whitelist.conf
if [[ -s $local_wl ]]; then
  grep -v -f <(grep -vE '^[[:space:]]*(#|$)' "$local_wl") "$P2S_STREAM" >"$P2S_STREAM.f" 2>/dev/null || true
  [[ -s $P2S_STREAM.f ]] && mv -f -- "$P2S_STREAM.f" "$P2S_STREAM"
  rm -f -- "$P2S_STREAM.f"
fi

# ------------------------------------------------------------- 2. rule eval
# rule_match.sh consumes the pack + stream, emits matched stream records with
# rule id set (field 12 rewritten) -> matched.jsonl via stream_to_json.
bash "$WORKDIR/engine/rule_match.sh" "$P2S_STREAM" >"$P2S_MATCHED" || true

# ------------------------------------------------------------- 3. correlate + score
# Build IP->T1 index and per-rule hits, then classify into alerts.
bash "$WORKDIR/engine/score_alerts.sh" "$P2S_MATCHED" || true

# ------------------------------------------------------------- 4. housekeeping
state_prune_offsets
state_save_offsets
dedup_prune
corr_prune 1800
baseline_tick
enforce_caps
p2s_status_write "batch_done"

log_info "batch $BATCH_ID complete: $(wc -l <"$P2S_STREAM") records, $(wc -l <"$P2S_MATCHED") matched"
