#!/usr/bin/env bash
# stream.sh - normalized record stream contract between plugins and engine.
#
# Every plugin prints TAB-separated records, one per line, fields in this order:
#   1 ts        ISO8601 UTC ("2026-10-23T10:12:00Z")
#   2 source    access_log|fpm_error|apache_error|nginx_error|syslog|journal|
#               auditd|sessions|webroot|modsec|waf_ingest|proc|appcms
#   3 src_ip
#   4 method
#   5 uri
#   6 status
#   7 size      bytes ("" when unknown)
#   8 ua        user agent
#   9 pid       worker pid ("" when unknown)
#  10 sessid    session id / anomaly payload ("" when unknown)
#  11 file      filesystem path for FS events
#  12 rule_hint rule id the parser is CERTAIN about, else "-"
#  13 msg       single-line evidence text (tabs/newlines stripped)
#
# Rules:
#   - plugins MUST strip tabs/newlines from free text (sanitize_field)
#   - plugins MUST NOT fail the scan; return 0 even when source is missing
#   - records with unparseable timestamps use the file mtime (never empty ts)
[[ -n ${P2S_STREAM_SH:-} ]] && return 0
P2S_STREAM_SH=1
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

STREAM_FIELDS=(ts source src_ip method uri status size ua pid sessid file rule_hint msg)
# 0-based awk field index per name (awk $1 == field index 1)
stream_field_index() {
  case $1 in
    ts) echo 1 ;; source) echo 2 ;; src_ip) echo 3 ;; method) echo 4 ;;
    uri) echo 5 ;; status) echo 6 ;; size) echo 7 ;; ua) echo 8 ;;
    pid) echo 9 ;; sessid) echo 10 ;; file) echo 11 ;; rule) echo 12 ;;
    msg) echo 13 ;;
    *) echo 0 ;;
  esac
}

# emit_record <source> <src_ip> <method> <uri> <status> <size> <ua> <pid> <sessid> <file> <rule_hint> <msg>
# Timestamp comes from P2S_TS (caller sets per line).
emit_record() {
  local source=$1 src_ip=$2 method=$3 uri=$4 status=$5 size=$6 ua=$7 pid=$8 sessid=$9 file=${10} rule=${11} msg=${12}
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${P2S_TS:-$(utc_now)}" "$(_s "$source")" "$(_s "$src_ip")" "$(_s "$method")" \
    "$(_s "$uri")" "$(_s "$status")" "$(_s "$size")" "$(_s "$ua")" "$(_s "$pid")" \
    "$(_s "$sessid")" "$(_s "$file")" "$(_s "$rule")" "$(_s "$msg")"
}

_s() { s=${1-}; s=${s//$'\t'/ }; s=${s//$'\n'/ }; s=${s//$'\r'/ }; printf '%s' "$s"; }
