#!/usr/bin/env bash
# status.sh - human status report (plan 5.4): supervisor, plugins ON/OFF (+why),
# rules ON/OFF (+why), 10 latest alerts.
set -u
WORKDIR=${WORKDIR:-/tmp/php2shell-monitor}
# shellcheck source=/dev/null
source "$WORKDIR/lib/common.sh"

echo "== supervisor =="
pid=$(cat "$P2S_RUN_DIR/supervisor.pid" 2>/dev/null || echo 0)
if [[ $pid != 0 ]] && kill -0 "$pid" 2>/dev/null; then
  echo "running (pid $pid)"
else
  echo "NOT running"
fi
[[ -f $P2S_RUN_DIR/status.json ]] && cat "$P2S_RUN_DIR/status.json"

echo ""
echo "== plugins (last scan) =="
if [[ -f $P2S_RUN_DIR/plugin_status.tsv ]]; then
  tail -20 "$P2S_RUN_DIR/plugin_status.tsv" | column -t -s $'\t' 2>/dev/null || tail -20 "$P2S_RUN_DIR/plugin_status.tsv"
else
  echo "no scan has run yet"
fi

echo ""
echo "== capabilities =="
if [[ -f $P2S_STATE_DIR/capabilities.txt ]]; then
  tr '\n' ' ' <"$P2S_STATE_DIR/capabilities.txt"; echo ""
else
  echo "run -- discover first"
fi

echo ""
echo "== rules =="
if [[ -f $P2S_STATE_DIR/rules.loaded.tsv ]]; then
  awk -F'\t' '{ printf "%-8s %-3s %-9s %-6s %s\n", $1, $2, $3, ($6==1?"ON":"OFF"), $7 }' "$P2S_STATE_DIR/rules.loaded.tsv"
else
  echo "rules not loaded yet (run -- run or -- discover)"
fi

echo ""
echo "== last 10 alerts =="
if [[ -s $P2S_ALERT_DIR/queue.jsonl ]]; then
  tail -10 "$P2S_ALERT_DIR/queue.jsonl" | "$P2S_JQ" -r '[.ts_utc,.severity,.rule_id,.tier,(.src_ip_candidates[0].ip // "-"),.uri] | @tsv' 2>/dev/null
else
  echo "(none)"
fi
