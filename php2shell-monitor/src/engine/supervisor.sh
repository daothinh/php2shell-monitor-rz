#!/usr/bin/env bash
# supervisor.sh - start/stop the background supervisor (plan 5.4: no cron, no
# systemd; 1 supervisor loops batch every BATCH_INTERVAL seconds and runs the
# realtime watcher as a child). PID file: run/supervisor.pid. flock prevents
# double start.
set -u
WORKDIR=${WORKDIR:-/tmp/php2shell-monitor}
# shellcheck source=/dev/null
source "$WORKDIR/lib/common.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/log.sh"

PIDFILE=$WORKDIR/run/supervisor.pid
LOCK=$WORKDIR/run/supervisor.lock

_supervisor_alive() {
  local pid
  [[ -f $PIDFILE ]] || return 1
  pid=$(cat "$PIDFILE" 2>/dev/null)
  [[ $pid =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

_supervisor_loop() {
  trap 'pkill -P $$ 2>/dev/null; exit 0' TERM INT
  log_info "supervisor started (pid $$)"
  p2s_status_write "supervisor_started"
  # realtime watcher as child
  bash "$WORKDIR/engine/watch.sh" &
  WATCHER_PID=$!
  while true; do
    nice -n 10 bash "$WORKDIR/engine/scan.sh" >>"$P2S_RUN_DIR/scan.log" 2>&1
    sleep "${BATCH_INTERVAL:-300}" &
    SLEEP_PID=$!
    wait "$SLEEP_PID" 2>/dev/null || true
  done
}

p2s_status_write() { # <phase>
  local phase=${1:-unknown} now
  now=$(utc_now)
  local host
  host=$(hostname 2>/dev/null || echo unknown)
  cat >"$P2S_RUN_DIR/status.json" <<EOF
{"ts_utc":"$now","host":"$host","phase":"$phase","pid":$(cat "$PIDFILE" 2>/dev/null || echo 0),"watcher_pid":${WATCHER_PID:-0}}
EOF
}

case ${1:-} in
  start)
    if _supervisor_alive; then
      echo "php2shell-monitor already running (pid $(cat "$PIDFILE"))"
      exit 0
    fi
    # source config for BATCH_INTERVAL
    [[ -f $WORKDIR/conf/default.conf ]] && source "$WORKDIR/conf/default.conf"
    export BATCH_INTERVAL
    (
      exec 9>"$LOCK"
      if ! flock -n 9; then
        echo "supervisor lock held; refusing double start" >&2
        exit 1
      fi
      setsid bash -c 'declare -f _supervisor_loop p2s_status_write >/dev/null 2>&1; source /dev/stdin <<"P2S_EOF"
'"$(declare -f _supervisor_loop p2s_status_write)"'
P2S_EOF
_supervisor_loop' >>"$P2S_RUN_DIR/supervisor.log" 2>&1 &
      echo $! >"$PIDFILE"
    )
    sleep 1
    if _supervisor_alive; then
      echo "supervisor started (pid $(cat "$PIDFILE"))"
    else
      echo "supervisor failed to start; see $P2S_RUN_DIR/supervisor.log" >&2
      exit 1
    fi
    ;;
  stop)
    if ! _supervisor_alive; then
      echo "not running"
      rm -f -- "$PIDFILE"
      exit 0
    fi
    local_pid=$(cat "$PIDFILE")
    kill -TERM "$local_pid" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$local_pid" 2>/dev/null || break
      sleep 1
    done
    kill -9 "$local_pid" 2>/dev/null || true
    # kill any stragglers running engine code (watcher tails, scoring loops);
    # exclude our own pid so this stop script is not TERMed mid-run
    for sp in $(pgrep -f "$WORKDIR/engine/" 2>/dev/null); do
      [[ $sp == $$ ]] && continue
      kill -TERM "$sp" 2>/dev/null || true
    done
    rm -f -- "$PIDFILE"
    p2s_status_write stopped
    echo "supervisor stopped"
    ;;
  status)
    if _supervisor_alive; then
      echo "running (pid $(cat "$PIDFILE"))"
    else
      echo "not running"
      exit 1
    fi
    ;;
  *)
    echo "usage: supervisor.sh {start|stop|status}" >&2
    exit 2
    ;;
esac
