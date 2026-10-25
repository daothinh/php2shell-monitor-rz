#!/usr/bin/env bash
# export_json.sh - copy this device's alerts and evidence into export/.
# The monitor never pushes; the operator retrieves the files.
set -u
WORKDIR=${WORKDIR:-/opt/php2shell-monitor}
source "$WORKDIR/lib/common.sh"
source "$WORKDIR/lib/paths.sh"
p2s_device_init || exit 1

stamp=$(date -u +%Y%m%dT%H%M%SZ)
out="$P2S_EXPORT_DIR/${PROJECT}__${DEVICE}__${stamp}.jsonl"

[[ -s $P2S_ALERT_DIR/queue.jsonl ]] || { echo "no alerts to export"; exit 0; }
cat -- "$P2S_ALERT_DIR/queue.jsonl" >"$out"
echo "exported $(wc -l <"$out") alert(s) -> $out"
echo "evidence kept in $P2S_EVIDENCE_DIR"
