#!/usr/bin/env bash
# supervisor.sh - background loop: one batch every BATCH_INTERVAL seconds.
# No cron and no systemd unit required. PID file: <device>/run/supervisor.pid.
set -u
WORKDIR=${WORKDIR:-/opt/php2shell-monitor}
export WORKDIR
# shellcheck source=/dev/null
source "$WORKDIR/lib/common.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/log.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/paths.sh"
p2s_device_init || exit 1
[[ -f $WORKDIR/conf/default.conf ]] && source "$WORKDIR/conf/default.conf"
export BATCH_INTERVAL

PIDFILE=$P2S_DEVICE_RUN_DIR/supervisor.pid
LOCK=$P2S_DEVICE_RUN_DIR/supervisor.lock

_supervisor_alive() {
  local pid
  [[ -f $PIDFILE ]] || return 1
  pid=$(cat "$PIDFILE" 2>/dev/null)
  [[ $pid =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

# If conf/central.conf exists (already paired with a Central Alert Server),
# keep one forwarder agent running so every alert reaches Telegram.
_ensure_agent() {
  [[ -r $WORKDIR/conf/central.conf ]] || return 0
  ( umask 077; mkdir -p -- "$P2S_DEVICE_RUN_DIR" )
  local pid
  pid=$(cat "$P2S_DEVICE_RUN_DIR/agent/agent.pid" 2>/dev/null || echo 0)
  [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && return 0
  setsid bash "$WORKDIR/engine/central.sh" agent \
    >>"$P2S_DEVICE_RUN_DIR/agent.log" 2>&1 &
  log_info "central agent respawned for $PROJECT/$DEVICE"
}

case ${1:-} in
  loop)
    log_info "supervisor started (pid $$) for $PROJECT/$DEVICE"
    _ensure_agent
    while true; do
      nice -n 10 bash "$WORKDIR/engine/scan.sh" >>"$P2S_DEVICE_RUN_DIR/scan.log" 2>&1
      _ensure_agent
      sleep "${BATCH_INTERVAL:-300}"
    done
    ;;
  start)
    if _supervisor_alive; then
      echo "already running (pid $(cat "$PIDFILE")) for $PROJECT/$DEVICE"
      exit 0
    fi
    (
      exec 9>"$LOCK"
      flock -n 9 || { echo "supervisor lock held; refusing double start" >&2; exit 1; }
      setsid bash "$WORKDIR/engine/supervisor.sh" loop \
        >>"$P2S_DEVICE_RUN_DIR/supervisor.log" 2>&1 &
      echo $! >"$PIDFILE"
    )
    sleep 1
    if _supervisor_alive; then
      echo "supervisor started (pid $(cat "$PIDFILE")) — project=$PROJECT device=$DEVICE"
    else
      echo "supervisor failed to start; see $P2S_DEVICE_RUN_DIR/supervisor.log" >&2
      exit 1
    fi
    ;;
  stop)
    if ! _supervisor_alive; then
      echo "not running"
      rm -f -- "$PIDFILE"
      exit 0
    fi
    pid=$(cat "$PIDFILE")
    kill -TERM "$pid" 2>/dev/null
    for _ in 1 2 3 4 5; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    kill -9 "$pid" 2>/dev/null || true
    # stop any scan still running for this device
    for sp in $(pgrep -f "$WORKDIR/engine/" 2>/dev/null); do
      [[ $sp == "$$" ]] && continue
      kill -TERM "$sp" 2>/dev/null || true
    done
    # stop the central forwarder agent too
    apid=$(cat "$P2S_DEVICE_RUN_DIR/agent/agent.pid" 2>/dev/null || echo 0)
    if [[ $apid =~ ^[0-9]+$ ]] && kill -0 "$apid" 2>/dev/null; then
      kill -TERM "$apid" 2>/dev/null || true
    fi
    rm -f -- "$P2S_DEVICE_RUN_DIR/agent.pid"
    rm -f -- "$PIDFILE"
    echo "supervisor stopped"
    ;;
  status)
    if _supervisor_alive; then
      echo "running (pid $(cat "$PIDFILE")) — project=$PROJECT device=$DEVICE"
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
