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
  (mặc định / pair) Ghép nối với Central Alert Server (đã hardcode:
             http://45.124.93.136:8000) — chỉ cần:
               sudo php2shell-monitor.sh --chatid <chat-id> [--project <tên>]
             --server có thể ghi đè; --device được bỏ qua (tự detect hostname);
             nhắn /id cho bot để lấy Chat ID, rồi /confirm trong chat đó.
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

# Single-command mode (không cần mode tường minh):
#   sudo php2shell-monitor.sh --chatid <chat-id> [--project <tên>]
#   = pair với server hardcode bên dưới, DEVICE luôn tự detect (hostname).
# `--device` được chấp nhận nhưng BỎ QUA (auto-detect). Nếu mode không phải
# `|--chatid|--server|--project|--device|--...` thì dùng như mode cũ.
P2S_DEFAULT_SERVER=${P2S_DEFAULT_SERVER:-http://45.124.93.136:8000}

first=${1:-}
if [[ -z $first || $first == -* ]]; then mode=pair; else mode=$first; fi
[[ $mode == help || $mode == -h || $mode == --help ]] && mode=help

pair_args=() want_project=
if [[ $mode == pair ]]; then
  if [[ -n $first && $first != -* ]]; then shift; fi
  while (($#)); do
    case $1 in
      --chatid)  pair_args+=(--chatid "${2:-}"); shift 2 ;;
      --server)  pair_args+=(--server "${2:-}"); shift 2 ;;
      --project) want_project=${2:-}; shift 2 ;;
      --device)  shift 2 ;;   # bỏ qua — device luôn tự detect qua hostname
      --detach)  pair_args+=(--detach); shift ;;
      *) echo "tham số không hợp lệ: $1" >&2; usage; exit 2 ;;
    esac
  done
  # server mặc định: chỉ thêm khi caller không truyền --server
  has_server=0
  for a in "${pair_args[@]}"; do [[ $a == --server ]] && has_server=1; done
  ((has_server)) || pair_args=(--server "$P2S_DEFAULT_SERVER" "${pair_args[@]}")
  # --project: ghi vào conf/device.conf trước khi p2s_device_init đọc nó
  if [[ -n $want_project ]]; then
    conf=$WORKDIR/conf/device.conf
    if [[ -e $conf ]] && grep -q '^PROJECT=' "$conf" && [[ $(grep '^PROJECT=' "$conf") != "PROJECT=\"$want_project\"" ]]; then
      sed -i "s|^PROJECT=.*|PROJECT=\"$want_project\"|" "$conf"
    else
      printf '# php2shell-monitor — device identity\nPROJECT="%s"\nDEVICE="$(hostname 2>/dev/null || echo unknown)"\n' "$want_project" >"$conf"
    fi
  fi
fi

[[ $mode == help ]] && { usage; exit 0; }

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
    bash "$WORKDIR/engine/central.sh" pair ${pair_args+"${pair_args[@]}"}
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
