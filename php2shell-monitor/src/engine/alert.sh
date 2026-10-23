#!/usr/bin/env bash
# alert.sh - alert construction, dedup, queue write (plan 5, 7 schema)
[[ -n ${P2S_ALERT_SH:-} ]] && return 0
P2S_ALERT_SH=1
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/../lib/json.sh"
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/../lib/state.sh"

ALERT_QUEUE=${ALERT_QUEUE:-$P2S_ALERT_DIR/queue.jsonl}
ALERT_SUMMARY=${ALERT_SUMMARY:-$P2S_RUN_DIR/watcher.log}

# alert_emit <rule> <tier> <severity> <confidence> <uri> <candidates_json> \
#             <evidence_json> <notes>
alert_emit() {
  local rule=$1 tier=$2 sev=$3 conf=$4 uri=$5 cands=$6 evid=$7 notes=${8:-}
  local ip="" first_cand
  first_cand=$("$P2S_JQ" -r '.[0].ip // empty' <<<"$cands" 2>/dev/null)
  ip=$first_cand

  if ! dedup_should_emit "$rule" "$ip" "$uri" "${DEDUP_WINDOW:-900}"; then
    log_debug "deduped $rule $ip $uri"
    return 0
  fi
  dedup_mark "$rule" "$ip" "$uri"

  local ts host mode
  ts=$(utc_now)
  host=$(hostname 2>/dev/null || echo unknown)
  mode=$(baseline_mode 2>/dev/null || echo learning)

  local alert
  alert=$(json_obj \
    "ts_utc" "$(json_str "$ts")" \
    "host" "$(json_str "$host")" \
    "rule_id" "$(json_str "$rule")" \
    "tier" "$(json_str "$tier")" \
    "severity" "$(json_str "$sev")" \
    "confidence" "$(json_str "$conf")" \
    "src_ip_candidates" "$cands" \
    "uri" "$(json_str "$uri")" \
    "evidence" "$evid" \
    "baseline_mode" "$(json_str "$mode")" \
    "notes" "$(json_str "$notes")")

  printf '%s\n' "$alert" >>"$ALERT_QUEUE"
  printf '%s %s %s %s ip=%s uri=%s\n' "$ts" "$sev" "$rule" "$tier" "${ip:-unknown}" "$uri" >>"$ALERT_SUMMARY"
  log_info "ALERT $sev $rule ($tier) ip=${ip:-unknown} uri=$uri"
}

# Build candidates JSON from correlated T1 IPs; empty array when none.
candidates_json() { # [max]
  local max=${1:-5} out='[' first=1 ip hits last uri
  while IFS=$'\t' read -r ip hits last uri; do
    [[ -z $ip ]] && continue
    [[ $first -eq 1 ]] && first=0 || out+=','
    out+=$(json_obj "ip" "$(json_str "$ip")" "score" "$(json_num "$hits")" "via" '"direct"')
  done < <(corr_candidates "$max")
  printf '%s]' "$out"
}

# Evidence array for a single source line.
evidence_json() { # <source> <file> <line_ref> <msg>
  local src=$1 file=$2 ref=$3 msg=$4
  local one
  one=$(json_obj \
    "source" "$(json_str "$src")" \
    "file" "$(json_str "$file")" \
    "line_ref" "$(json_str "$ref")" \
    "msg" "$(json_str "$msg")")
  printf '[%s]' "$one"
}
