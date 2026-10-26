#!/usr/bin/env bash
# supervisor.sh - background loop: one batch every BATCH_INTERVAL seconds.
# No cron and no systemd unit required. PID file: <device>/run/supervisor.pid.
set -u
WORKDIR=${WORKDIR:-/opt/php2shell-monitor}
export WORKDIR
source "$WORKDIR/lib/common.sh"
source "$WORKDIR/lib/log.sh"
source "$WORKDIR/lib/paths.sh"
p2s_device_init || exit 1
[[ -f $WORKDIR/conf/default.conf ]] && source "$WORKDIR/conf/default.conf"
export BATCH_INTERVAL

PIDFILE=$P2S_DEVICE_RUN_DIR/supervisor.pid
LOCK=$P2S_DEVICE_RUN_DIR/supervisor.lock

# PID numbers get reused. A stale pidfile must never be trusted: killing a
# recycled PID (or its process group) can take down an unrelated process — even
# the shell that invoked us. Verify the process really is our supervisor loop.
_supervisor_pid() { # in PID nếu pidfile trỏ đúng loop của device này
  local pid cmd
  [[ -f $PIDFILE ]] || return 1
  pid=$(cat "$PIDFILE" 2>/dev/null)
  [[ $pid =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null) || return 1
  # phải là supervisor.sh loop VÀ đúng device này
  [[ $cmd == *"supervisor.sh"*"loop"* ]] || return 1
  [[ $cmd == *"$WORKDIR"* ]] || return 1
  printf '%s' "$pid"
}

_supervisor_alive() {
  _supervisor_pid >/dev/null
}

# Keep one forwarder agent alive when the device is paired, so every alert
# reaches Telegram. The pidfile is verified like the supervisor's: a recycled
# PID must never be signalled.
_agent_pid() {
  local pid cmd
  pid=$(cat "$P2S_DEVICE_RUN_DIR/agent/agent.pid" 2>/dev/null) || return 1
  [[ $pid =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null) || return 1
  [[ $cmd == *"central.sh"*"agent"* ]] || return 1
  [[ $cmd == *"$WORKDIR"* ]] || return 1
  printf '%s' "$pid"
}

_ensure_agent() {
  [[ -r $WORKDIR/conf/central.conf ]] || return 0
  ( umask 077; mkdir -p -- "$P2S_DEVICE_RUN_DIR" )
  _agent_pid >/dev/null && return 0
  setsid bash "$WORKDIR/engine/central.sh" agent \
    >>"$P2S_DEVICE_RUN_DIR/agent.log" 2>&1 9>&- &
  log_info "central agent respawned for $PROJECT/$DEVICE"
}

case ${1:-} in
  loop)
    # The loop owns the lock: the starter exits at once, so a lock held by it
    # would be released immediately.
    exec 9>"$LOCK"
    flock -n 9 || { log_info "another supervisor holds $LOCK; exiting"; exit 0; }
    echo $$ >"$PIDFILE"
    log_info "supervisor started (pid $$) for $PROJECT/$DEVICE"

    interval=${BATCH_INTERVAL:-300}
    [[ $interval =~ ^[0-9]+$ ]] && (( interval >= 10 )) || interval=300
    # A scan must never outlive its own window: if it hangs, the next tick is
    # skipped forever and no alert is ever produced. Kill it well before the
    # next tick so the schedule stays clean.
    scan_timeout=${SCAN_TIMEOUT:-$((interval - 30))}
    (( scan_timeout > 0 )) || scan_timeout=$((interval / 2))

    _rotate() { # <file> <max_bytes> — keep one previous copy
      local f=$1 max=${2:-10485760}
      [[ -f $f ]] || return 0
      local sz
      sz=$(stat -c %s -- "$f" 2>/dev/null || echo 0)
      (( sz > max )) || return 0
      mv -f -- "$f" "$f.1" 2>/dev/null || true
    }

    _ensure_agent
    trap 'log_info "supervisor dừng (pid $$)"; exit 0' INT TERM

    while true; do
      # Fixed-rate schedule: sleep until the NEXT tick on the epoch grid, so the
      # scan duration does not accumulate as drift. The old `sleep $interval`
      # after the scan gave 319s / 308s / 307s cycles instead of 300s, and the
      # alert window silently stretched with it.
      tick_start=$(utc_epoch)

      if [[ -e $P2S_DEVICE_RUN_DIR/scan.lock ]]; then
        _stale=$(find "$P2S_DEVICE_RUN_DIR/scan.lock" -newermt "-$((scan_timeout + 60)) seconds" 2>/dev/null)
        if [[ -z $_stale ]]; then
          log_warn "scan.lock cũ hơn $((scan_timeout + 60))s — coi như treo, xoá"
          rm -f -- "$P2S_DEVICE_RUN_DIR/scan.lock"
        fi
      fi

      # timeout(1) + </dev/null: a plugin that blocks on stdin or hangs can no
      # longer freeze the loop. 124 = timed out.
      nice -n 10 timeout -k 10 "$scan_timeout" \
        bash "$WORKDIR/engine/scan.sh" </dev/null 9>&- \
        >>"$P2S_DEVICE_RUN_DIR/scan.log" 2>&1
      rc=$?
      case $rc in
        0) ;;
        124|137)
          log_error "batch vượt quá ${scan_timeout}s — đã kill; xem scan.log"
          rm -f -- "$P2S_DEVICE_RUN_DIR/scan.lock"
          ;;
        *)
          log_warn "batch kết thúc với mã $rc"
          ;;
      esac

      _ensure_agent
      _rotate "$P2S_DEVICE_RUN_DIR/scan.log" "${SCAN_LOG_MAX:-10485760}"
      _rotate "$P2S_RUN_DIR/engine.log" "${ENGINE_LOG_MAX:-10485760}"

      # next tick on the grid, never in the past
      now=$(utc_epoch)
      next=$(( (now / interval + 1) * interval ))
      delay=$(( next - now ))
      (( delay > 0 )) || delay=$interval
      log_info "batch xong sau $((now - tick_start))s; tick kế tiếp sau ${delay}s"

      # Wait for the next tick, but do not sleep through a dead forwarder: the
      # agent carries every alert to the server, so a crash between ticks left
      # alerts sitting in queue.jsonl for up to a full interval. Wake up every
      # AGENT_CHECK seconds and respawn it immediately.
      check=${AGENT_CHECK:-20}
      [[ $check =~ ^[0-9]+$ ]] && (( check >= 5 )) || check=20
      remaining=$delay
      while (( remaining > 0 )); do
        nap=$(( remaining < check ? remaining : check ))
        sleep "$nap" 9>&-
        remaining=$(( remaining - nap ))
        _ensure_agent
      done
    done
    ;;
  start)
    if _supervisor_alive; then
      echo "already running (pid $(cat "$PIDFILE")) for $PROJECT/$DEVICE"
      exit 0
    fi
    # stale pidfile from a crash: drop it so the lock check below is meaningful
    rm -f -- "$PIDFILE"
    setsid bash "$WORKDIR/engine/supervisor.sh" loop \
      >>"$P2S_DEVICE_RUN_DIR/supervisor.log" 2>&1 9>&- &
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
    # _supervisor_pid đã xác minh PID này đúng là loop của device — chỉ khi đó
    # mới được kill theo process group (loop là session leader nên PGID == PID).
    pid=$(_supervisor_pid) || { echo "not running"; rm -f -- "$PIDFILE"; exit 0; }
    kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
    for _ in 1 2 3 4 5; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    kill -9 -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
    # stop the central forwarder agent too (chỉ khi PID đã xác minh)
    apid=$(_agent_pid) || apid=''
    [[ -n $apid ]] && kill -TERM "$apid" 2>/dev/null || true
    rm -f -- "$P2S_DEVICE_RUN_DIR/agent/agent.pid"
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
  kick-agent)
    # Sau khi pair lại (vd dự án bị /unlink rồi ghép mới): agent đang chạy vẫn
    # giữ API key cũ trong bộ nhớ. Giết agent (PID đã xác minh) — vòng loop
    # respawn nó trong ≤AGENT_CHECK giây và agent mới đọc conf mới, drain spool.
    apid=$(_agent_pid) || { echo "no agent running"; exit 0; }
    kill -TERM "$apid" 2>/dev/null || true
    rm -f -- "$P2S_DEVICE_RUN_DIR/agent/agent.pid"
    echo "agent (pid $apid) stopped — supervisor sẽ respawn với conf mới"
    ;;
  *)
    echo "usage: supervisor.sh {start|stop|status|kick-agent}" >&2
    exit 2
    ;;
esac
