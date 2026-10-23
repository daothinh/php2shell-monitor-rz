#!/usr/bin/env bash
# retro_hunt.sh - one-shot hunt over ALL existing logs incl. rotated (plan 6.6).
# Safe to re-run. Output: reports/retro-hunt-report.md + .json.
# Scope deliberately wide: since 2026-10-17 (first-attempt date is secondary source).
set -u
WORKDIR=${WORKDIR:-/tmp/php2shell-monitor}
# shellcheck source=/dev/null
source "$WORKDIR/lib/common.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/log.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/stream.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/time_utc.sh"

[[ -f $WORKDIR/conf/default.conf ]] && source "$WORKDIR/conf/default.conf"

SINCE=${RETRO_SINCE:-2026-10-17T00:00:00Z}
SINCE_EPOCH=$(iso_to_epoch "$SINCE")
REPORT_MD=$P2S_REPORT_DIR/retro-hunt-report.md
REPORT_JSON=$P2S_REPORT_DIR/retro-hunt-report.json
WORK=$P2S_STATE_DIR/retro
mkdir -p -- "$WORK" "$P2S_REPORT_DIR"

log_info "retro-hunt since $SINCE (epoch $SINCE_EPOCH)"

# Normalize any timestamp string from a log line; "" when nothing usable.
_line_ts() {
  t_extract_access_ts "$1" || t_extract_fpm_ts "$1" || t_extract_journal_ts "$1" ||
    t_syslog_noyear_to_utc "$(printf '%s' "$1" | cut -c1-15)" || echo ""
}

# filter a file stream by date >= SINCE using per-line ts; keeps unknown-ts lines
_filter_since() {
  local src=$1
  awk -F'\t' -v since="$SINCE_EPOCH" '{
    ts = $1
    if (ts ~ /^[0-9]{4}-[0-9][0-9]-[0-9][0-9]T/) {
      # compare ISO strings lexicographically after converting to epoch-less form:
      # substring to seconds is monotonic in ISO, so string compare works for UTC
      if (substr(ts,1,19) < strftime("%Y-%m-%dT%H:%M:%S", since, 1)) next
    }
    print
  }' 2>/dev/null
}

: >"$WORK/stream.all.tsv"

# 1. access logs incl. rotated (.1, .2, -YYYYMMDD, .gz)
add_access_logs() {
  local f
  for f in /var/log/nginx/access.log* /var/log/apache2/access.log* /var/log/apache2/other_vhosts_access.log* \
           /var/log/httpd/access_log* /var/log/nginx/*access*.log*; do
    [[ -f $f && -r $f ]] || continue
    case $f in
      *.gz) zcat -- "$f" 2>/dev/null | awk -f "$P2S_SRC_DIR/lib/accesslog.awk" -v src=access_log ;;
      *)    awk -f "$P2S_SRC_DIR/lib/accesslog.awk" -v src=access_log "$f" ;;
    esac
  done
}

# 2. error logs (fpm/apache/nginx) incl. rotated
add_error_logs() {
  local f
  for f in /var/log/php*-fpm*.log* /var/log/php-fpm/*.log* \
           /var/log/apache2/error.log* /var/log/httpd/error_log* /var/log/nginx/error.log*; do
    [[ -f $f && -r $f ]] || continue
    local base=${f##*/}
    local src=fpm_error rule=P2S-010
    case $base in
      error*|*error_log*) src=apache_error ;;
    esac
    case $f in
      /var/log/nginx/*) src=nginx_error; rule=P2S-014 ;;
      /var/log/php*) src=fpm_error; rule=P2S-010 ;;
    esac
    if [[ $f == *.gz ]]; then
      zcat -- "$f" 2>/dev/null | grep -P 'Allowed memory size of|Out of memory|Hard memory limit|Unknown on line|exited on signal|exit signal|segfault|upstream prematurely|recv\(\) failed \(104|exit code (70|137)' |
      while IFS= read -r l; do
        ts=$(_line_ts "$l"); [[ -z $ts ]] && ts=$(utc_now)
        P2S_TS=$ts emit_record "$src" "" "" "" "" "" "" "$(printf '%s' "$l" | grep -oP 'child \K[0-9]+|pid \K[0-9]+' | head -1)" "" "" "$rule" "$l"
      done
    else
      grep -P 'Allowed memory size of|Out of memory|Hard memory limit|Unknown on line|exited on signal|exit signal|segfault|upstream prematurely|recv\(\) failed \(104|exit code (70|137)' "$f" 2>/dev/null |
      while IFS= read -r l; do
        ts=$(_line_ts "$l"); [[ -z $ts ]] && ts=$(utc_now)
        P2S_TS=$ts emit_record "$src" "" "" "" "" "" "" "$(printf '%s' "$l" | grep -oP 'child \K[0-9]+|pid \K[0-9]+' | head -1)" "" "" "$rule" "$l"
      done
    fi
  done
}

# 3. kernel/journal since window
add_kernel() {
  if have journalctl; then
    journalctl -k --since "$SINCE" --output=short-iso --no-pager 2>/dev/null |
      grep -P 'segfault at|Out of memory|Killed process' |
      while IFS= read -r l; do
        ts=$(t_extract_journal_ts "$l"); [[ -z $ts ]] && ts=$(utc_now)
        P2S_TS=$ts emit_record kernel "" "" "" "" "" "" "" "" "" "P2S-011" "$l"
      done
    for unit in 'php*-fpm' nginx apache2 httpd; do
      journalctl -u "$unit" --since "$SINCE" --output=short-iso --no-pager 2>/dev/null |
        grep -P 'exited on signal|segfault|Allowed memory size|exit code (70|137)' |
        while IFS= read -r l; do
          ts=$(t_extract_journal_ts "$l"); [[ -z $ts ]] && ts=$(utc_now)
          P2S_TS=$ts emit_record journal "" "" "" "" "" "" "" "" "" "P2S-011" "$l"
        done
    done
  fi
  local f
  for f in /var/log/kern.log* /var/log/messages* /var/log/syslog*; do
    [[ -f $f && -r $f ]] || continue
    case $f in
      *.gz) zcat -- "$f" 2>/dev/null ;;
      *) cat -- "$f" 2>/dev/null ;;
    esac | grep -P 'segfault at|Out of memory|Killed process' |
      while IFS= read -r l; do
        ts=$(_line_ts "$l"); [[ -z $ts ]] && ts=$(utc_now)
        P2S_TS=$ts emit_record kernel "" "" "" "" "" "" "" "" "" "P2S-011" "$l"
      done
  done
}

# 4. auditd rotated
add_auditd() {
  local f
  for f in /var/log/audit/audit.log*; do
    [[ -f $f && -r $f ]] || continue
    case $f in
      *.gz) zcat -- "$f" 2>/dev/null ;;
      *) cat -- "$f" 2>/dev/null ;;
    esac | grep -P 'type=EXECVE|type=PATH' |
      while IFS= read -r l; do
        ts=$(printf '%s' "$l" | grep -oP '(?<=audit\()[0-9.]+' | head -1)
        [[ -n $ts ]] && { ts=${ts%%.*}; ts=$(epoch_to_utc "$ts"); } || ts=$(utc_now)
        P2S_TS=$ts emit_record auditd "" "" "" "" "" "" "" "" "" "P2S-021" "$l"
      done
  done
}

{
  add_access_logs
  add_error_logs
  add_kernel
  add_auditd
} >"$WORK/stream.raw.tsv" 2>/dev/null

# 5. filter by window + run matcher + scoring
awk -F'\t' -v since="$SINCE" '{
  ts = $1
  if (ts ~ /^[0-9][0-9][0-9][0-9]-/) {
    if (substr(ts,1,19) < substr(since,1,19)) next
  }
  print
}' "$WORK/stream.raw.tsv" >"$WORK/stream.all.tsv"

log_info "retro: $(wc -l <"$WORK/stream.all.tsv") records in window"

bash "$P2S_SRC_DIR/engine/rule_match.sh" "$WORK/stream.all.tsv" >"$WORK/matched.jsonl" 2>/dev/null || true
bash "$P2S_SRC_DIR/engine/score_alerts.sh" "$WORK/matched.jsonl" 2>/dev/null || true

# 6. webroot sweep by mtime/ctime since window
sweep_webroot() {
  local d out="$WORK/webroot-sweep.tsv"
  : >"$out"
  local since_day=${SINCE%%T*}
  for d in ${WEBROOTS:-} /var/www /var/www/html /usr/share/nginx/html /home/*/public_html; do
    [[ -d $d && -r $d ]] || continue
    find "$d" -xdev -type f \
      \( -name '*.php' -o -name '*.phtml' -o -name '*.phar' -o -name '*.php5' -o -name '*.inc' \
         -o -name '.user.ini' -o -name '.htaccess' -o -name '*.sh' \) \
      -newermt "$since_day" -printf '%TY-%Tm-%TdT%TH:%TM:%TSZ\t%p\t%s\t%U\n' 2>/dev/null >>"$out"
  done
  wc -l <"$out" 2>/dev/null || echo 0
}

# 7. session dir anomalies (key names + size only)
sweep_sessions() {
  local d f sz
  local out="$WORK/session-sweep.tsv"
  : >"$out"
  for d in ${SESSION_DIRS:-} /var/lib/php/sessions /var/lib/php/session; do
    [[ -d $d && -r $d ]] || continue
    for f in "$d"/sess_*; do
      [[ -f $f ]] || continue
      sz=$(stat -c '%s' -- "$f" 2>/dev/null) || continue
      (( sz >= 1048576 )) || continue
      grep -q 'upload_progress_' "$f" 2>/dev/null || continue
      printf '%s\t%s\t%s\n' "$f" "$sz" "$(date -u -r "$f" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" >>"$out"
    done
  done
  wc -l <"$out" 2>/dev/null || echo 0
}

wr_count=$(sweep_webroot)
sess_count=$(sweep_sessions)

# 8. IP candidates from retro matches
declare -A IPCOUNT=()
while IFS= read -r ev; do
  ip=$("$P2S_JQ" -r '.src_ip // empty' <<<"$ev" 2>/dev/null)
  [[ -z $ip ]] && continue
  IPCOUNT[$ip]=$(( ${IPCOUNT[$ip]:-0} + 1 ))
done <"$WORK/matched.jsonl"

# 9. reports
{
  echo "# PHP2Shell retro-hunt report"
  echo ""
  echo "- Generated: $(utc_now)"
  echo "- Window: >= $SINCE"
  echo "- Records scanned: $(wc -l <"$WORK/stream.all.tsv")"
  echo "- Matched events: $(wc -l <"$WORK/matched.jsonl")"
  echo "- Webroot files touched since window: $wr_count"
  echo "- Session files with upload_progress >=1MB: $sess_count"
  echo ""
  echo "## Rule hits"
  "$P2S_JQ" -r '.rule' "$WORK/matched.jsonl" 2>/dev/null | sort | uniq -c | sort -rn | sed 's/^/    /'
  echo ""
  echo "## Candidate IPs (ranked)"
  for ip in "${!IPCOUNT[@]}"; do printf '    %s\t%s\n' "${IPCOUNT[$ip]}" "$ip"; done | sort -rn | head -20
  echo ""
  echo "## Webroot sweep (new/changed executables)"
  head -50 "$WORK/webroot-sweep.tsv" 2>/dev/null | sed 's/^/    /'
  echo ""
  echo "## Session anomalies"
  head -20 "$WORK/session-sweep.tsv" 2>/dev/null | sed 's/^/    /'
  echo ""
  echo "## Alerts produced (queue: alerts/queue.jsonl)"
  tail -20 "$P2S_ALERT_DIR/queue.jsonl" 2>/dev/null | sed 's/^/    /'
} >"$REPORT_MD"

# JSON summary
jq -n \
  --arg ts "$(utc_now)" \
  --arg since "$SINCE" \
  --argjson records "$(wc -l <"$WORK/stream.all.tsv")" \
  --argjson matched "$(wc -l <"$WORK/matched.jsonl")" \
  --argjson webroot "$wr_count" \
  --argjson sessions "$sess_count" \
  --argjson ips "$(for ip in "${!IPCOUNT[@]}"; do jq -n --arg ip "$ip" --argjson n "${IPCOUNT[$ip]}" '{ip:$ip,hits:$n}'; done | jq -s 'sort_by(-.hits)')" \
  '{ts_utc:$ts, window_start:$since, records:$records, matched_events:$matched,
    webroot_touched:$webroot, session_anomalies:$sessions, candidates:$ips}' >"$REPORT_JSON" 2>/dev/null

echo "retro-hunt complete:"
echo "  $REPORT_MD"
echo "  $REPORT_JSON"
