#!/usr/bin/env bash
# log.sh - monitor-internal logging (never writes outside WORKDIR)
[[ -n ${P2S_LOG_SH:-} ]] && return 0
P2S_LOG_SH=1

P2S_LOG_LEVEL=${P2S_LOG_LEVEL:-info}

_p2s_level_num() {
  case $1 in
    debug) echo 0 ;;
    info)  echo 1 ;;
    warn)  echo 2 ;;
    error) echo 3 ;;
    *)     echo 1 ;;
  esac
}

_p2s_log() {
  local lvl=$1; shift
  local msg=$*
  [[ $(_p2s_level_num "$lvl") -ge $(_p2s_level_num "${P2S_LOG_LEVEL:-info}") ]] || return 0
  local line
  line="$(utc_now) [$lvl] $msg"
  if [[ -n ${P2S_RUN_DIR:-} && -d ${P2S_RUN_DIR:-} ]]; then
    printf '%s\n' "$line" >>"$P2S_RUN_DIR/engine.log" 2>/dev/null
  fi
  if [[ ${P2S_LOG_STDERR:-0} == 1 ]]; then
    printf '%s\n' "$line" >&2
  fi
}
log_debug() { _p2s_log debug "$@"; }
log_info()  { _p2s_log info "$@"; }
log_warn()  { _p2s_log warn "$@"; }
log_error() { _p2s_log error "$@"; }

die() {
  log_error "$*"
  printf '%s: %s\n' "$P2S_PROG" "$*" >&2
  exit 1
}
