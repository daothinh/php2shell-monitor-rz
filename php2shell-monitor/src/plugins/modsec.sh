#!/usr/bin/env bash
# modsec.sh - P2S-040 ingest of ModSecurity / njs / Suricata / Zeek outputs.
# The monitor does NOT run WAF rules; it reads lines that third-party WAF/IDS
# already logged (plan 6.3). Source strings verified in repos (scout report).
set -u
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_batch_common.sh"

plugin_name=modsec
plugin_source=waf_ingest

# ModSec rule ids observed for php2shell: 9109618-620, 20260001/4/6/7/8, 1009618-620
MODSEC_IDS='9109618|9109619|9109620|20260001|20260004|20260006|20260007|20260008|1009618|1009619|1009620'
# njs r.log messages from php-multipart-signals.njs (exact strings)
NJS_MSGS='PHP multipart request without usable Content-Length|PHP upload-progress rule could not parse multipart form|PHP upload-progress field with body session id|PHP upload-progress field with session cookie|PHP upload-progress field with large multipart body'
# Suricata eve.json signature ids
SURI_SIDS='910961801|910961802|910961803|20260001|20260004|20260006'

parse_modsec_line() {
  local line=$1 src=$2
  local ts
  ts=$(t_extract_access_ts "$line" || t_extract_journal_ts "$line" || utc_now)
  P2S_TS=$ts
  local rule=P2S-040
  # try to extract client ip from modsec audit header [client 1.2.3.4]
  local ip
  ip=$(printf '%s' "$line" | grep -oP '\[client \K[0-9a-f:.]+' | head -1)
  emit_record waf_ingest "$ip" "" "" "" "" "" "" "" "" "$rule" "$line"
}

plugin_run() {
  local f
  # 1. modsec audit log (apache)
  for f in /var/log/apache2/modsec_audit.log /var/log/httpd/modsec_audit.log; do
    [[ -f $f && -r $f ]] || continue
    batch_read "$f" parse_modsec_line
  done
  # 2. modsec via apache/nginx error log lines mentioning our rule ids
  for f in /var/log/apache2/error.log /var/log/httpd/error_log /var/log/nginx/error.log; do
    [[ -f $f && -r $f ]] || continue
    grep -hP "ModSecurity: .*(Id \"($MODSEC_IDS)\")" "$f" 2>/dev/null |
    while IFS= read -r line; do
      P2S_TS=$(t_extract_access_ts "$line" || utc_now)
      emit_record waf_ingest "$(printf '%s' "$line" | grep -oP '\[client \K[0-9a-f:.]+' | head -1)" "" "" "" "" "" "" "" "" "P2S-040" "$line"
    done
  done
  # 3. njs signals in nginx error log
  for f in /var/log/nginx/error.log; do
    [[ -f $f && -r $f ]] || continue
    grep -hP "($NJS_MSGS)" "$f" 2>/dev/null |
    while IFS= read -r line; do
      P2S_TS=$(t_extract_access_ts "$line" || utc_now)
      emit_record waf_ingest "" "" "" "" "" "" "" "" "" "P2S-040" "$line"
    done
  done
  # 4. suricata eve.json alerts
  for f in /var/log/suricata/eve.json; do
    [[ -f $f && -r $f ]] || continue
    grep -hP "\"signature_id\": *($SURI_SIDS)\b" "$f" 2>/dev/null |
    while IFS= read -r line; do
      P2S_TS=$(utc_now)
      emit_record waf_ingest "$(printf '%s' "$line" | "$P2S_JQ" -r '.src_ip // empty' 2>/dev/null)" "" "" "" "" "" "" "" "" "P2S-040" "$line"
    done
  done
  return 0
}

plugin_run
exit 0
