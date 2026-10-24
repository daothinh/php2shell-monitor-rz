#!/usr/bin/env bash
# main.sh - CLI dispatcher. Runs with cwd=WORKDIR (bootstrap cd's).
#
# Storage model:
#   WORKDIR/projects/<project>/devices/<device>/{alerts,evidence,state,run}
# PROJECT and DEVICE come from conf/device.conf (one monitor install = one device).
set -u
export WORKDIR=${WORKDIR:-/opt/php2shell-monitor}
P2S_SRC_DIR=$WORKDIR
export P2S_SRC_DIR
# shellcheck source=/dev/null
source "$WORKDIR/lib/common.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/log.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/paths.sh"

usage() {
  cat <<'EOF'
php2shell-monitor — one alert per 5-minute batch, full raw evidence kept

Usage: sudo bash php2shell-monitor.sh -- <mode>

The archive unpacks into /opt/php2shell-monitor and every byte the tool writes
(code, config, offsets, alerts, evidence, temp files) stays under that directory.
Nothing else on the host is created or modified.

Modes:
  (mặc định) Mọi lần chạy đều tự bật supervisor nền: rà log mỗi 5 phút,
             alert sinh ra được đẩy Telegram nếu đã pair.
  once       Run a single batch now (same work the supervisor does every 5 min)
  run        Start the background supervisor (batch every BATCH_INTERVAL, default 300s)
  pair       Ghép nối project với Central Alert Server -> Telegram
             theo Chat ID (pair --server <url> [--chatid <id>]):
             nhắn /id cho bot để lấy Chat ID, rồi /confirm trong chat đó.
             Tên dự án lấy từ conf/device.conf (PROJECT); alert được
             đẩy tự động khi supervisor chạy
  test       Send one test alert to the paired central server
  status     Project/device, plugin health, last batches, last alert
  stop       Stop the supervisor (state preserved)
  discover   Read-only host discovery -> reports/log-map-actual.md
  retro      One-shot hunt over rotated logs (produces one alert for the window)
  export     Copy alert queue + evidence to export/ as JSON
  clean      stop + remove /opt/php2shell-monitor entirely

Alert model:
  * at most ONE alert per batch, severity = highest severity among the hits
  * every raw hit line is kept in <device>/evidence/<batch>.jsonl with file:line
  * the alert itself embeds those hits (capped by MAX_EVIDENCE_INLINE)
EOF
}

# makeself passes the script args verbatim, so callers may write `-- once`.
[[ ${1:-} == -- ]] && shift
mode=${1:-}
[[ -z $mode || $mode == help || $mode == -h || $mode == --help ]] && { usage; exit 0; }

p2s_device_init || { echo "cannot initialise data dirs under $WORKDIR" >&2; exit 1; }

# Auto-start: any invocation keeps the 5-minute monitor running (idempotent —
# a live supervisor is left alone, `stop`/`clean` below still win).
if [[ $mode != stop && $mode != clean ]]; then
  bash "$WORKDIR/engine/supervisor.sh" start >/dev/null 2>&1 || true
fi

case $mode in
  once)
    bash "$WORKDIR/engine/scan.sh"
    ;;
  run)
    bash "$WORKDIR/engine/supervisor.sh" start
    ;;
  pair)
    shift
    bash "$WORKDIR/engine/central.sh" pair "$@"
    ;;
  test)
    bash "$WORKDIR/engine/central.sh" test
    ;;
  status)
    bash "$WORKDIR/engine/status.sh"
    ;;
  stop)
    bash "$WORKDIR/engine/supervisor.sh" stop
    ;;
  discover)
    bash "$WORKDIR/discovery/discovery.sh" "${2:-}"
    ;;
  retro)
    bash "$WORKDIR/discovery/retro_hunt.sh" "${2:-}"
    ;;
  export)
    bash "$WORKDIR/export/export_json.sh"
    echo "export written to $P2S_EXPORT_DIR"
    ;;
  clean)
    bash "$WORKDIR/engine/supervisor.sh" stop 2>/dev/null
    rm -rf -- "$WORKDIR"
    echo "workdir removed: $WORKDIR"
    ;;
  *)
    echo "unknown mode: $mode" >&2
    usage
    exit 2
    ;;
esac
