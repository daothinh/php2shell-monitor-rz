#!/usr/bin/env bash
# report.sh - turn one batch of rule hits into exactly ONE alert.
#
# Rules (the whole point of this file):
#   * at most one alert per batch, whatever matched;
#   * its severity is the highest severity among the hits;
#   * every raw hit line is preserved with its source file and line number.
#
# Writes, per batch:
#   evidence/<batch>.jsonl   one JSON object per hit (full raw line + file:line)
#   alerts/queue.jsonl       one alert line, only when the batch had hits
#   run/batches.log          one summary line, always
set -u
WORKDIR=${WORKDIR:-/opt/php2shell-monitor}
HITS=$1
BATCH=${2:-$(date -u +%Y%m%dT%H%M%SZ)}
WINDOW_START=${3:-0}
WINDOW_END=${4:-$(utc_epoch)}

source "$WORKDIR/lib/common.sh"
source "$WORKDIR/lib/json.sh"
source "$WORKDIR/lib/paths.sh"
p2s_device_init || exit 0
[[ -f $WORKDIR/conf/default.conf ]] && source "$WORKDIR/conf/default.conf"

MAX_INLINE=${MAX_EVIDENCE_INLINE:-500}

_rank() {
  case ${1^^} in
    CRITICAL) echo 5 ;; HIGH) echo 4 ;; MEDIUM) echo 3 ;; LOW) echo 2 ;; INFO) echo 1 ;;
    *) echo 0 ;;
  esac
}

_host=$(hostname 2>/dev/null || echo unknown)

# ---------------------------------------------------------------- no hits
if [[ ! -s $HITS ]]; then
  printf '%s\t%s\t%s\t%s\n' "$BATCH" "$PROJECT" "$DEVICE" "no-hits" \
    >>"$P2S_DEVICE_RUN_DIR/batches.log"
  exit 0
fi

EVIDENCE=$P2S_EVIDENCE_DIR/$BATCH.jsonl
ALERT=$P2S_ALERT_DIR/queue.jsonl

# ------------------------------------------------- 1. evidence (full, raw)
# One JSON object per event, written by a single awk process. The bash loop
# called json_obj (a subshell + fork) per hit: an 80k-hit batch took minutes
# and never finished inside the batch window.
COUNTS=$P2S_TMP_DIR/report.$BATCH.counts.tsv
: >"$COUNTS"
awk -f "$WORKDIR/lib/evidence.awk" -v outcounts="$COUNTS" "$HITS" >"$EVIDENCE"

total=0
top_sev=INFO
rce_hits=0
declare -A per_rule=()
declare -A per_sev=()
if [[ -s $COUNTS ]]; then
  while IFS=$'\t' read -r kind a b; do
    case $kind in
      R) per_rule[$a]=${b:-0} ;;
      S) per_sev[$a]=${b:-0} ;;
      *) total=${kind:-0}; top_sev=${a:-INFO}; rce_hits=${b:-0} ;;
    esac
  done <"$COUNTS"
fi
rm -f -- "$COUNTS"

# ------------------------------------------------- 2. counts (stable order)
_rule_counts_json() {
  local out='[' first=1 k n
  for k in $(printf '%s\n' "${!per_rule[@]}" | sort); do
    n=${per_rule[$k]}
    [[ $first -eq 1 ]] && first=0 || out+=','
    out+=$(json_obj "rule_id" "$(json_str "$k")" "hits" "$(json_num "$n")")
  done
  printf '%s]' "$out"
}
_sev_counts_json() {
  local out='[' first=1 k n
  for k in $(printf '%s\n' "${!per_sev[@]}" | sort); do
    n=${per_sev[$k]}
    [[ $first -eq 1 ]] && first=0 || out+=','
    out+=$(json_obj "severity" "$(json_str "${k^^}")" "hits" "$(json_num "$n")")
  done
  printf '%s]' "$out"
}

# ------------------------------------------------- 3. inline evidence (capped)
if (( total <= MAX_INLINE )); then
  inline="[$(paste -sd, -- "$EVIDENCE")]"
  truncated=false
else
  inline="[$(head -n "$MAX_INLINE" -- "$EVIDENCE" | paste -sd, -)]"
  truncated=true
fi

# ------------------------------------------------- 4. the single alert
alert=$(json_obj \
  "ts_utc" "$(json_str "$(utc_now)")" \
  "batch_id" "$(json_str "$BATCH")" \
  "project" "$(json_str "$PROJECT")" \
  "device" "$(json_str "$DEVICE")" \
  "host" "$(json_str "$DEVICE")" \
  "hostname" "$(json_str "$_host")" \
  "window_start" "$(json_str "$(epoch_to_utc "${WINDOW_START:-0}" 2>/dev/null || utc_now)")" \
  "window_end" "$(json_str "$(epoch_to_utc "$WINDOW_END")")" \
  "severity" "$(json_str "$top_sev")" \
  "rce" "$(json_num "$rce_hits")" \
  "hits" "$(json_num "$total")" \
  "rules" "$(_rule_counts_json)" \
  "severities" "$(_sev_counts_json)" \
  "evidence_file" "$(json_str "$EVIDENCE")" \
  "evidence_truncated" "$truncated" \
  "evidence" "$inline")

printf '%s\n' "$alert" >>"$ALERT"
printf '%s\t%s\t%s\t%s\t%d hit(s)\t%s\n' \
  "$BATCH" "$PROJECT" "$DEVICE" "$top_sev" "$total" "$EVIDENCE" \
  >>"$P2S_DEVICE_RUN_DIR/batches.log"

# ------------------------------------------------- 5. retention
KEEP=${EVIDENCE_KEEP:-2016}   # 7 days of 5-minute batches
count=$(find "$P2S_EVIDENCE_DIR" -maxdepth 1 -name '*.jsonl' -type f | wc -l)
if (( count > KEEP )); then
  find "$P2S_EVIDENCE_DIR" -maxdepth 1 -name '*.jsonl' -type f -printf '%T@ %p\n' 2>/dev/null |
    sort -n | head -n "$((count - KEEP))" | cut -d' ' -f2- |
    while IFS= read -r old; do rm -f -- "$old"; done
fi
