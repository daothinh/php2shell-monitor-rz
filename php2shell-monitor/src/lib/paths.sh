#!/usr/bin/env bash
# paths.sh - project/device identity and the data layout.
#
#   $WORKDIR/projects/<project>/devices/<device>/
#   ├── alerts/queue.jsonl     one line per batch that produced hits
#   ├── evidence/<batch>.jsonl every raw hit line (file + line + raw)
#   ├── state/offsets/         per-log-file read offsets (inode, byte, line)
#   └── run/batches.log        one summary line per batch, including empty ones
#
# A device is one monitored host. PROJECT/DEVICE come from conf/device.conf.
[[ -n ${P2S_PATHS_SH:-} ]] && return 0
P2S_PATHS_SH=1
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Keep ids filesystem-safe: letters, digits, dot, underscore, dash.
_slug() {
  local s=${1-}
  s=$(printf '%s' "$s" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-64)
  s=${s#_}; s=${s%_}
  printf '%s' "${s:-unknown}"
}

p2s_device_init() {
  [[ -n ${P2S_DATA_DIR:-} ]] && return 0
  local conf="$P2S_CONF_DIR/device.conf"
  if [[ -r $conf ]]; then
    # shellcheck disable=SC1090
    source "$conf"
  fi
  PROJECT=$(_slug "${PROJECT:-default}")
  DEVICE=$(_slug "${DEVICE:-$(hostname 2>/dev/null || echo unknown)}")

  P2S_DATA_DIR=$WORKDIR/projects/$PROJECT/devices/$DEVICE
  P2S_ALERT_DIR=$P2S_DATA_DIR/alerts
  P2S_EVIDENCE_DIR=$P2S_DATA_DIR/evidence
  P2S_STATE_DIR=$P2S_DATA_DIR/state
  P2S_DEVICE_RUN_DIR=$P2S_DATA_DIR/run

  local d
  for d in "$P2S_ALERT_DIR" "$P2S_EVIDENCE_DIR" "$P2S_STATE_DIR/offsets" \
           "$P2S_DEVICE_RUN_DIR" "$P2S_RUN_DIR" "$P2S_TMP_DIR"; do
    _mkdir_private "$d" || return 1
  done
  return 0
}

# mkdir -p with 0700 on every created level (umask alone is not enough because
# mkdir -p -m only chmods the deepest component).
_mkdir_private() {
  local d=$1
  [[ -d $d ]] && return 0
  (umask 077 && mkdir -p -- "$d") || return 1
  local p
  p=$(dirname -- "$d")
  while [[ $p != / && $p != . && $p != "$WORKDIR" && ! -d $p ]]; do
    (umask 077 && mkdir -p -- "$p") || return 1
    p=$(dirname -- "$p")
  done
  chmod 0700 -- "$d" 2>/dev/null
  return 0
}

# Last completed batch epoch (0 when unknown).
state_last_batch() {
  local f="$P2S_STATE_DIR/last_batch"
  [[ -r $f ]] || { printf '0'; return 0; }
  cat "$f" 2>/dev/null || printf '0'
}

state_set_last_batch() {
  printf '%s\n' "${1:-$(utc_epoch)}" >"$P2S_STATE_DIR/last_batch"
}
