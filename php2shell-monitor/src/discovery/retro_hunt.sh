#!/usr/bin/env bash
# retro_hunt.sh - one-shot hunt over existing logs including rotated/gzipped.
# Produces exactly ONE alert for the whole window (same model as a batch), with
# every raw hit line kept in evidence/.
set -u
WORKDIR=${WORKDIR:-/opt/php2shell-monitor}
source "$WORKDIR/lib/common.sh"
source "$WORKDIR/lib/log.sh"
source "$WORKDIR/lib/stream.sh"
source "$WORKDIR/lib/time_utc.sh"
source "$WORKDIR/lib/paths.sh"
p2s_device_init || exit 1
[[ -f $WORKDIR/conf/default.conf ]] && source "$WORKDIR/conf/default.conf"

SINCE=${RETRO_SINCE:-2026-10-17T00:00:00Z}
BATCH="retro-$(date -u +%Y%m%dT%H%M%SZ)"
WORK=$P2S_TMP_DIR/$BATCH
mkdir -p -- "$WORK"
STREAM=$WORK/stream.tsv
HITS=$WORK/hits.tsv
: >"$STREAM"
: >"$HITS"

log_info "retro-hunt since $SINCE"

# keep only lines whose normalized ts is >= SINCE (unknown ts are kept)
_filter_since() {
  awk -F'\t' -v since="${SINCE:0:19}" '
    $1 ~ /^[0-9][0-9][0-9][0-9]-/ && substr($1,1,19) < since { next }
    { print }
  '
}

_add_access() {
  local f out="$WORK/access.tsv"
  : >"$out"
  for f in ${NGINX_ACCESS:-} ${APACHE_ACCESS:-} \
           /var/log/nginx/access.log* /var/log/apache2/access.log* \
           /var/log/apache2/other_vhosts_access.log* /var/log/httpd/access_log* \
           /var/log/nginx/*access*.log*; do
    [[ -f $f && -r $f ]] || continue
    case $f in
      *.gz) zcat -- "$f" 2>/dev/null >"$WORK/plain.log" ;;
      *)    cat -- "$f" 2>/dev/null >"$WORK/plain.log" ;;
    esac
    awk -f "$P2S_SRC_DIR/lib/accesslog.awk" -v src=access_log \
        -v realfile="$f" "$WORK/plain.log" >>"$out"
  done
  cat -- "$out" >>"$STREAM"
}

_add_error_logs() {
  local f line no
  for f in ${FPM_LOG:-} ${APACHE_ERROR:-} ${NGINX_ERROR:-} \
           /var/log/php*-fpm*.log* /var/log/php-fpm/*.log* \
           /var/log/apache2/error.log* /var/log/httpd/error_log* /var/log/nginx/error.log*; do
    [[ -f $f && -r $f ]] || continue
    local src=fpm_error
    case $f in
      /var/log/nginx/*) src=nginx_error ;;
      /var/log/apache2/*|/var/log/httpd/*) src=apache_error ;;
    esac
    no=0
    case $f in
      *.gz) zcat -- "$f" 2>/dev/null ;;
      *)    cat -- "$f" 2>/dev/null ;;
    esac | while IFS= read -r line; do
      no=$((no + 1))
      ts=$(t_extract_fpm_ts "$line" || t_extract_access_ts "$line" || utc_now)
      P2S_TS=$ts emit_record "$src" "$f" "$no" "" "" "" "" "" "" "$line" "-"
    done >>"$STREAM"
  done
}

_add_auditd() {
  local f line no
  for f in /var/log/audit/audit.log*; do
    [[ -f $f && -r $f ]] || continue
    no=0
    case $f in
      *.gz) zcat -- "$f" 2>/dev/null ;;
      *)    cat -- "$f" 2>/dev/null ;;
    esac | while IFS= read -r line; do
      no=$((no + 1))
      printf '%s' "$line" | grep -qP 'type=EXECVE|type=PATH' || continue
      ts=$(printf '%s' "$line" | grep -oP '(?<=audit\()[0-9.]+' | head -1)
      [[ -n $ts ]] && ts=$(epoch_to_utc "${ts%%.*}") || ts=$(utc_now)
      P2S_TS=$ts emit_record auditd "$f" "$no" "" "" "" "" "" "" "$line" "-"
    done >>"$STREAM"
  done
}

_add_access
_add_error_logs
_add_auditd

_filter_since <"$STREAM" >"$WORK/stream.window.tsv"
mv -f -- "$WORK/stream.window.tsv" "$STREAM"

bash "$WORKDIR/engine/rule_match.sh" "$STREAM" >"$HITS" 2>/dev/null || true
bash "$WORKDIR/engine/report.sh" "$HITS" "$BATCH" "$(iso_to_epoch "$SINCE")" "$(utc_epoch)"

mkdir -p -- "$WORKDIR/reports"
report=$WORKDIR/reports/retro-hunt-$BATCH.md
{
  echo "# PHP2Shell retro-hunt"
  echo ""
  echo "- Generated: $(utc_now)"
  echo "- Project / device: $PROJECT / $DEVICE"
  echo "- Window: >= $SINCE"
  echo "- Records scanned: $(wc -l <"$STREAM")"
  echo "- Rule hits: $(wc -l <"$HITS")"
  echo ""
  echo "## Hits by rule"
  if [[ -n ${P2S_JQ:-} ]]; then
    "$P2S_JQ" -r '.rule' "$HITS" 2>/dev/null | sort | uniq -c | sort -rn | sed 's/^/    /'
  fi
  echo ""
  echo "## Raw hits (file:line)"
  awk -F'\t' '{ printf "    %s:%s  %s  %s\n", $3, $4, $12, substr($11,1,160) }' "$HITS" |
    head -200
  if [[ -s $HITS ]]; then
    echo ""
    echo "## Evidence file"
    echo "    $P2S_EVIDENCE_DIR/$BATCH.jsonl"
  else
    echo ""
    echo "## Evidence file"
    echo "    (none — no rule hits in this window)"
  fi
} >"$report"

rm -rf -- "$WORK"
echo "retro-hunt complete: $report"
if [[ -s $HITS ]]; then
  echo "alert written to $P2S_ALERT_DIR/queue.jsonl"
else
  echo "no hits: no alert produced"
fi
