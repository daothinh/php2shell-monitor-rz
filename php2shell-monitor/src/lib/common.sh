#!/usr/bin/env bash
# common.sh - constants, guards, small helpers (safe to source twice)
[[ -n ${P2S_COMMON_SH:-} ]] && return 0
P2S_COMMON_SH=1

P2S_US=$'\x1f'          # unit separator: event record delimiter
export P2S_US

P2S_PROG=${P2S_PROG:-php2shell-monitor}
P2S_VERSION=${P2S_VERSION:-dev}

# Runtime layout (all under WORKDIR; see plan 5.2)
WORKDIR=${WORKDIR:-/tmp/php2shell-monitor}
P2S_SRC_DIR=${P2S_SRC_DIR:-$WORKDIR}  # code dir (workdir after bootstrap)
P2S_LIB_DIR=${P2S_LIB_DIR:-$P2S_SRC_DIR/lib}
P2S_PLUGIN_DIR=${P2S_PLUGIN_DIR:-$P2S_SRC_DIR/plugins}
P2S_RULE_DIR=${P2S_RULE_DIR:-$P2S_SRC_DIR/rules}
P2S_ENGINE_DIR=${P2S_ENGINE_DIR:-$P2S_SRC_DIR/engine}
P2S_CONF_DIR=${P2S_CONF_DIR:-$P2S_SRC_DIR/conf}
P2S_STATE_DIR=${P2S_STATE_DIR:-${WORKDIR:-}/state}
P2S_ALERT_DIR=${P2S_ALERT_DIR:-${WORKDIR:-}/alerts}
P2S_EXPORT_DIR=${P2S_EXPORT_DIR:-${WORKDIR:-}/export}
P2S_REPORT_DIR=${P2S_REPORT_DIR:-${WORKDIR:-}/reports}
P2S_RUN_DIR=${P2S_RUN_DIR:-${WORKDIR:-}/run}
P2S_TMP_DIR=${P2S_TMP_DIR:-${WORKDIR:-}/tmp}

# JSON query engine: jq preferred, jaq is drop-in for our usage
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

# UTC now, ISO8601 with Z
utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
utc_epoch() { date -u +%s; }

# Epoch -> ISO UTC (portable; GNU date)
epoch_to_utc() {
  date -u -d "@${1:?epoch required}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo ""
}

# Parse an ISO8601 timestamp (with offset or Z) to epoch. Returns empty on failure.
iso_to_epoch() {
  local ts=${1:-}
  [[ -z $ts ]] && return 1
  date -d "$ts" +%s 2>/dev/null
}

# Strip control chars and the record separator from a free-form value.
sanitize_field() {
  local s=${1-}
  s=${s//$'\r'/ }
  s=${s//$'\n'/ }
  s=${s//$P2S_US/ }
  printf '%s' "$s"
}

csv_has() { # csv_has "a,b,c" "b"
  local IFS=,
  local x
  for x in $1; do [[ $x == "$2" ]] && return 0; done
  return 1
}

# List of words -> json array of strings
json_array_from_words() {
  local out='[' first=1 w
  for w in $1; do
    [[ $first -eq 1 ]] && first=0 || out+=','
    out+="\"$(json_escape "$w")\""
  done
  printf '%s]' "$out"
}
