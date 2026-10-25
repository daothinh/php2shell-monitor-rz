#!/usr/bin/env bash
# modsec.sh - ingest lines that ModSecurity / njs / Suricata already logged.
# The monitor does not run WAF rules; it only reads their output.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/_batch_common.sh"

plugin_name=modsec
export plugin_name

MODSEC_IDS='9109618|9109619|9109620|20260001|20260004|20260006|20260007|20260008|1009618|1009619|1009620'
NJS_MSGS='PHP multipart request without usable Content-Length|PHP upload-progress rule could not parse multipart form|PHP upload-progress field with body session id|PHP upload-progress field with session cookie|PHP upload-progress field with large multipart body'
SURI_SIDS='910961801|910961802|910961803|20260001|20260004|20260006'

emit_waf() { # <line> <file> <line_no>
  local line=$1 file=$2 no=$3 ts ip
  ts=$(t_extract_access_ts "$line" || t_extract_journal_ts "$line" || utc_now)
  P2S_TS=$ts; export P2S_TS
  ip=''
  if [[ $line =~ \[client\ ([0-9a-f:.]+) ]]; then ip=${BASH_REMATCH[1]}; fi
  emit_record modsec "$file" "$no" "$ip" "" "" "" "" "" "$line" "-"
}

# 1. ModSecurity audit log
for f in /var/log/apache2/modsec_audit.log /var/log/httpd/modsec_audit.log; do
  [[ -f $f && -r $f ]] && batch_read "$f" emit_waf
done

# 2. ModSecurity / njs lines inside web-server error logs
for f in /var/log/apache2/error.log /var/log/httpd/error_log /var/log/nginx/error.log; do
  [[ -f $f && -r $f ]] || continue
  grep -nP "ModSecurity: .*(Id \"($MODSEC_IDS)\")|($NJS_MSGS)" "$f" 2>/dev/null |
  while IFS=: read -r no line; do
    emit_waf "$line" "$f" "$no"
  done
done

# 3. Suricata eve.json alerts
f=/var/log/suricata/eve.json
if [[ -f $f && -r $f ]]; then
  grep -nP "\"signature_id\": *($SURI_SIDS)\b" "$f" 2>/dev/null |
  while IFS=: read -r no line; do
    P2S_TS=$(utc_now); export P2S_TS
    ip=""
    [[ -n ${P2S_JQ:-} ]] && ip=$(printf '%s' "$line" | "$P2S_JQ" -r '.src_ip // empty' 2>/dev/null)
    emit_record modsec "$f" "$no" "$ip" "" "" "" "" "" "$line" "-"
  done
fi
