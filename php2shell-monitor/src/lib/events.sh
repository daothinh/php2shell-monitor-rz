#!/usr/bin/env bash
# events.sh - event record contract shared by all plugins.
#
# Canonical event format: one JSON object per line (JSONL), fields:
#   ts       ISO8601 UTC (required)
#   source   plugin name (access_nginx|access_apache|fpm|apache_error|nginx_error|
#            kernel|auditd|sessions|webroot|modsec|waf_ingest|proc|appcms)
#   tier     T1|T2|T3 (tier of the raw signal class)
#   rule     rule id this raw line contributed to (e.g. P2S-010) or "" when generic
#   src_ip   best client ip or "" when unknown
#   uri      request uri or ""
#   status   http status or ""
#   method   http method or ""
#   ua       user agent or ""
#   pid      worker pid when the source provides one (FPM catch_workers_output) or ""
#   sessid   session id length anomaly payload or ""
#   file     filesystem path for FS events or ""
#   size     numeric size when relevant or ""
#   line_ref "inode:offset" style reference for evidence (optional)
#   msg      sanitized evidence line (single line)
# Events are written to $P2S_EVENT_DIR/events-<tag>.jsonl by the engine; plugins
# only emit on stdout. A plugin MUST never fail the scan (plan 0.3).
[[ -n ${P2S_EVENTS_SH:-} ]] && return 0
P2S_EVENTS_SH=1
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/json.sh"

# Emit one event on stdout. Args: source tier rule src_ip uri status method ua
# Optional context via env: P2S_PID P2S_SESSID P2S_FILE P2S_SIZE P2S_LINE_REF P2S_MSG P2S_TS_OVERRIDE
emit_event() {
  local source=$1 tier=$2 rule=$3 src_ip=$4 uri=$5 status=$6 method=$7 ua=$8
  local ts
  ts=${P2S_TS_OVERRIDE:-$(utc_now)}
  json_obj \
    "ts" "$(json_str "$ts")" \
    "source" "$(json_str "$source")" \
    "tier" "$(json_str "$tier")" \
    "rule" "$(json_str "$rule")" \
    "src_ip" "$(json_str "$src_ip")" \
    "uri" "$(json_str "$uri")" \
    "status" "$(json_str "$status")" \
    "method" "$(json_str "$method")" \
    "ua" "$(json_str "$ua")" \
    "pid" "$(json_str "${P2S_PID:-}")" \
    "sessid" "$(json_str "${P2S_SESSID:-}")" \
    "file" "$(json_str "${P2S_FILE:-}")" \
    "size" "$(json_num "${P2S_SIZE:-}")" \
    "line_ref" "$(json_str "${P2S_LINE_REF:-}")" \
    "msg" "$(json_str "${P2S_MSG:-}")"
  printf '\n'
}
