#!/usr/bin/env bash
# main.sh - CLI dispatcher (plan 5.4). Always runs with cwd=WORKDIR (bootstrap cd's).
# Modes: discover | retro | run | status | stop | export | clean | help
set -u
export WORKDIR=/tmp/php2shell-monitor

P2S_SRC_DIR=$WORKDIR
export P2S_SRC_DIR
# shellcheck source=/dev/null
source "$WORKDIR/lib/common.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/log.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/safe_fs.sh"

usage() {
  cat <<'EOF'
php2shell-monitor — detection for CVE-2026-109618 / CVE-2026-109619 exploitation

Usage: sudo bash php2shell-monitor.sh -- <mode>

Modes:
  discover   Read-only discovery: log map, patch status -> reports/log-map-actual.md
  retro      One-shot retro-hunt over rotated logs since 2026-10-17 -> reports/
  run        Start background supervisor (5-min batch + realtime watcher)
  status     Supervisor/plugin/rule status + last 10 alerts
  stop       Stop supervisor (state preserved)
  export     Write SIEM JSON + SQL to export/
  clean      stop + remove the whole workdir
EOF
}

need_dirs() {
  local d
  for d in state alerts export reports run tmp state/agg; do
    [[ -d "$WORKDIR/$d" ]] || (umask 077 && mkdir -m 0700 -p -- "$WORKDIR/$d")
  done
}

# ---- mode dispatch ----------------------------------------------------------
mode=${1:-}
[[ -z $mode || $mode == help || $mode == -h || $mode == --help ]] && { usage; exit 0; }

case $mode in
  discover)
    need_dirs
    bash "$WORKDIR/discovery/discovery.sh" "${2:-}"
    ;;
  retro)
    need_dirs
    bash "$WORKDIR/discovery/retro_hunt.sh" "${2:-}"
    ;;
  run)
    need_dirs
    bash "$WORKDIR/engine/supervisor.sh" start
    ;;
  status)
    need_dirs
    bash "$WORKDIR/engine/status.sh"
    ;;
  stop)
    need_dirs
    bash "$WORKDIR/engine/supervisor.sh" stop
    ;;
  export)
    need_dirs
    bash "$WORKDIR/export/export_json.sh"
    bash "$WORKDIR/export/export_sql.sh"
    echo "export written to $WORKDIR/export/"
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
