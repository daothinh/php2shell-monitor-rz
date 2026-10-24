#!/usr/bin/env bash
# common.sh - constants and small helpers (safe to source twice)
[[ -n ${P2S_COMMON_SH:-} ]] && return 0
P2S_COMMON_SH=1

P2S_US=$'\x1f'
export P2S_US

P2S_PROG=${P2S_PROG:-php2shell-monitor}
P2S_VERSION=${P2S_VERSION:-dev}

# Runtime layout. Code lives in WORKDIR; data lives in
# WORKDIR/projects/<project>/devices/<device>/ (see lib/paths.sh).
WORKDIR=${WORKDIR:-/opt/php2shell-monitor}
P2S_SRC_DIR=${P2S_SRC_DIR:-$WORKDIR}
P2S_LIB_DIR=${P2S_LIB_DIR:-$P2S_SRC_DIR/lib}
P2S_PLUGIN_DIR=${P2S_PLUGIN_DIR:-$P2S_SRC_DIR/plugins}
P2S_RULE_DIR=${P2S_RULE_DIR:-$P2S_SRC_DIR/rules}
P2S_ENGINE_DIR=${P2S_ENGINE_DIR:-$P2S_SRC_DIR/engine}
P2S_CONF_DIR=${P2S_CONF_DIR:-$P2S_SRC_DIR/conf}
P2S_RUN_DIR=${P2S_RUN_DIR:-$WORKDIR/run}
P2S_TMP_DIR=${P2S_TMP_DIR:-$WORKDIR/tmp}
P2S_EXPORT_DIR=${P2S_EXPORT_DIR:-$WORKDIR/export}

# Device-scoped paths; lib/paths.sh overwrites these after reading conf.
P2S_STATE_DIR=${P2S_STATE_DIR:-$WORKDIR/state}
P2S_ALERT_DIR=${P2S_ALERT_DIR:-$WORKDIR/alerts}
P2S_EVIDENCE_DIR=${P2S_EVIDENCE_DIR:-$WORKDIR/evidence}

if command -v jq >/dev/null 2>&1; then
  P2S_JQ=$(command -v jq)
elif command -v jaq >/dev/null 2>&1; then
  P2S_JQ=$(command -v jaq)
else
  P2S_JQ=""
fi
export P2S_JQ

have() { command -v "$1" >/dev/null 2>&1; }
is_root() { [[ ${EUID:-$(id -u)} -eq 0 ]]; }

utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
utc_epoch() { date -u +%s; }

epoch_to_utc() {
  date -u -d "@${1:?epoch required}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo ""
}

iso_to_epoch() {
  local ts=${1:-}
  [[ -z $ts ]] && return 1
  date -d "$ts" +%s 2>/dev/null
}

# Strip tabs/newlines so a value can live inside the stream TSV.
sanitize_field() {
  local s=${1-}
  s=${s//$'\t'/ }
  s=${s//$'\n'/ }
  s=${s//$'\r'/ }
  printf '%s' "$s"
}

csv_has() {
  local IFS=,
  local x
  for x in $1; do [[ $x == "$2" ]] && return 0; done
  return 1
}
