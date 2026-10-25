#!/usr/bin/env bash
# stream.sh - normalized record stream between plugins and the matcher.
#
# One record per line, TAB separated, exactly 12 fields:
#   1  ts         ISO8601 UTC
#   2  source     access_log|fpm_error|apache_error|nginx_error|journal|auditd|
#                 sessions|webroot|modsec|docker|proc|appcms|kernel
#   3  file       path of the log/artifact the line came from ("" if none)
#   4  line       line number inside that file (0 when not a line-oriented file)
#   5  ip         client address when known
#   6  method     HTTP method
#   7  uri        request URI
#   8  status     HTTP status
#   9  ua         user agent
#  10  pid        worker pid
#  11  msg        the RAW line, verbatim (tabs/newlines replaced by spaces)
#  12  rule_hint  rule id the parser is certain about, else "-"
#
# msg carries the raw line so an alert can quote exactly what matched.
[[ -n ${P2S_STREAM_SH:-} ]] && return 0
P2S_STREAM_SH=1
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

STREAM_FIELDS=(ts source file line ip method uri status ua pid msg rule)
export STREAM_FIELDS

stream_field_index() {
  case $1 in
    ts) echo 1 ;; source) echo 2 ;; file) echo 3 ;; line) echo 4 ;;
    ip) echo 5 ;; method) echo 6 ;; uri) echo 7 ;; status) echo 8 ;;
    ua) echo 9 ;; pid) echo 10 ;; msg|raw) echo 11 ;; rule) echo 12 ;;
    *) echo 0 ;;
  esac
}

# emit_record <source> <file> <line> <ip> <method> <uri> <status> <ua> <pid> <msg> <rule_hint>
# Timestamp comes from P2S_TS.
emit_record() {
  local source=$1 file=$2 line=$3 ip=$4 method=$5 uri=$6 status=$7 ua=$8 pid=$9
  local msg=${10} rule=${11}
  # Sanitize in place. `$(...)` forks a subshell, and 12 of them per record made
  # a 100k-line log take minutes — long enough to trip the plugin timeout.
  _s source; _s file; _s line; _s ip; _s method; _s uri
  _s status; _s ua; _s pid; _s msg; _s rule
  local ts=${P2S_TS:-}
  [[ -n $ts ]] || ts=$(utc_now)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$ts" "$source" "$file" "$line" "$ip" "$method" "$uri" \
    "$status" "$ua" "$pid" "$msg" "${rule:--}"
}

# _s <varname> — sanitize a variable in place (no subshell, no fork).
_s() {
  local __v=${!1-}
  __v=${__v//$'\t'/ }
  __v=${__v//$'\n'/ }
  __v=${__v//$'\r'/ }
  printf -v "$1" '%s' "$__v"
}
