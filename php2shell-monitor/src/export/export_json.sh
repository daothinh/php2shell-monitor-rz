#!/usr/bin/env bash
# export_json.sh - copy alert queue to export/ in SIEM-ready shape (plan P3:
# NO push; user retrieves the file). Adds a source marker + export ts.
set -u
WORKDIR=${WORKDIR:-/tmp/php2shell-monitor}
# shellcheck source=/dev/null
source "$WORKDIR/lib/common.sh"

QUEUE=$P2S_ALERT_DIR/queue.jsonl
OUT=$P2S_EXPORT_DIR/alerts-$(date -u +%Y%m%dT%H%M%SZ).json

[[ -s $QUEUE ]] || { echo "no alerts to export"; exit 0; }

while IFS= read -r line; do
  [[ -z $line ]] && continue
  ts=$(utc_now)
  host=$(hostname 2>/dev/null || echo unknown)
  # jq for valid JSON composition; fallback raw line
  if [[ -n ${P2S_JQ:-} ]]; then
    "$P2S_JQ" -c --arg ts "$ts" --arg host "$host" '. + {exported_at:$ts, exporter:"php2shell-monitor", host:$host}' <<<"$line" 2>/dev/null || printf '%s\n' "$line"
  else
    printf '%s\n' "$line"
  fi
done <"$QUEUE" >"$OUT"

echo "exported $(wc -l <"$OUT") alerts -> $OUT"
