#!/usr/bin/env bash
# status.sh - project/device overview: supervisor state, plugins, rules, last batches.
set -u
WORKDIR=${WORKDIR:-/opt/php2shell-monitor}
# shellcheck source=/dev/null
source "$WORKDIR/lib/common.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/paths.sh"
p2s_device_init || exit 1

pid=$(cat "$P2S_DEVICE_RUN_DIR/supervisor.pid" 2>/dev/null || echo 0)
if [[ $pid != 0 ]] && kill -0 "$pid" 2>/dev/null; then
  echo "supervisor: running (pid $pid)"
else
  echo "supervisor: NOT running"
fi
echo "project:    $PROJECT"
echo "device:     $DEVICE"
echo "data dir:   $P2S_DATA_DIR"
echo "batch:      every ${BATCH_INTERVAL:-300}s"
if [[ -r $WORKDIR/conf/central.conf ]]; then
  # shellcheck disable=SC1090
  source "$WORKDIR/conf/central.conf"
  echo "central:    paired -> $SERVER_URL (project: ${PROJECT_NAME:-$PROJECT})"
  apid=$(cat "$P2S_DEVICE_RUN_DIR/agent/agent.pid" 2>/dev/null || echo 0)
  if [[ $apid =~ ^[0-9]+$ ]] && kill -0 "$apid" 2>/dev/null; then
    echo "agent:      running (pid $apid)"
  else
    echo "agent:      NOT running (bật khi chạy '-- run')"
  fi
else
  echo "central:    not paired (sudo bash php2shell-monitor.sh -- pair --server <url>)"
fi
echo ""

echo "== plugins (last batch) =="
if [[ -f $P2S_DEVICE_RUN_DIR/plugin_status.tsv ]]; then
  tail -20 "$P2S_DEVICE_RUN_DIR/plugin_status.tsv" | column -t -s $'\t' 2>/dev/null ||
    tail -20 "$P2S_DEVICE_RUN_DIR/plugin_status.tsv"
else
  echo "no batch has run yet"
fi

echo ""
echo "== capabilities =="
if [[ -f $P2S_STATE_DIR/capabilities.txt ]]; then
  tr '\n' ' ' <"$P2S_STATE_DIR/capabilities.txt"; echo ""
else
  echo "run -- discover first"
fi

echo ""
echo "== last 5 batches =="
tail -5 "$P2S_DEVICE_RUN_DIR/batches.log" 2>/dev/null || echo "(none)"

echo ""
echo "== last alert =="
if [[ -s $P2S_ALERT_DIR/queue.jsonl ]]; then
  if [[ -n ${P2S_JQ:-} ]]; then
    "$P2S_JQ" -r '[.ts_utc,.severity,(.hits|tostring),(.rules|map(.rule_id)|join(",")),.evidence_file] | @tsv' \
      <(tail -1 "$P2S_ALERT_DIR/queue.jsonl")
  else
    tail -1 "$P2S_ALERT_DIR/queue.jsonl"
  fi
else
  echo "(none)"
fi
