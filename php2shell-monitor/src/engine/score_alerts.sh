#!/usr/bin/env bash
# score_alerts.sh - consume matched JSONL events; correlate candidates; classify;
# write alerts to the queue (plan 4 scoring + 7 alert schema).
#
# NOTE: bash `read` collapses consecutive IFS whitespace chars (incl. tab), so
# empty TSV fields vanish. All field extraction here goes through awk.
set -u
WORKDIR=${WORKDIR:-/tmp/php2shell-monitor}
MATCHED=$1
[[ -r $MATCHED ]] || exit 0

# shellcheck source=/dev/null
source "$WORKDIR/lib/common.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/log.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/state.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/json.sh"
# shellcheck source=/dev/null
source "$WORKDIR/engine/correlator.sh"
# shellcheck source=/dev/null
source "$WORKDIR/engine/scoring.sh"
# shellcheck source=/dev/null
source "$WORKDIR/engine/baseline.sh"
# shellcheck source=/dev/null
source "$WORKDIR/engine/alert.sh"
# shellcheck source=/dev/null
source "$WORKDIR/engine/rules.sh"

[[ -f $WORKDIR/conf/default.conf ]] && source "$WORKDIR/conf/default.conf"
rules_load

P2S_STATE_DIR=${P2S_STATE_DIR:-$WORKDIR/state}
: >"$P2S_STATE_DIR/hits.tsv"   # rule \t tier \t sev \t ip \t uri \t ts \t ev_json

_f() { awk -F'\t' -v c="$2" '{print $c}' <<<"$1"; }

# ------------------------------------------------- pass 1: index events
while IFS= read -r ev; do
  [[ -z $ev ]] && continue
  rule=$("$P2S_JQ" -r '.rule // empty' <<<"$ev" 2>/dev/null)
  tier=$("$P2S_JQ" -r '.tier // empty' <<<"$ev" 2>/dev/null)
  [[ -z $rule || -z $tier ]] && continue
  sev=$(rule_field_by_id "$rule" 3)
  ip=$("$P2S_JQ" -r '.src_ip // empty' <<<"$ev" 2>/dev/null)
  uri=$("$P2S_JQ" -r '.uri // empty' <<<"$ev" 2>/dev/null)
  ts=$("$P2S_JQ" -r '.ts // empty' <<<"$ev" 2>/dev/null)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rule" "$tier" "$sev" "$ip" "$uri" "$ts" "$ev" >>"$P2S_STATE_DIR/hits.tsv"
  corr_note "$tier" "$rule" "$ip" "$uri"
done <"$MATCHED"

# ------------------------------------------------- pass 2: aggregate rules
_agg_fire() { # <rule> <tier> <sev> <by> <win> <min>
  local rule=$1 tier=$2 sev=$3 by=$4 win=$5 min=$6
  local -A keys=()
  local line r ip uri te
  while IFS= read -r line; do
    r=$(_f "$line" 1)
    [[ $r == "$rule" ]] || continue
    ip=$(_f "$line" 4); uri=$(_f "$line" 5)
    te=$(iso_to_epoch "$(_f "$line" 6)" 2>/dev/null); [[ -n $te ]] || te=$(utc_epoch)
    case $by in
      src_ip) [[ -n $ip ]] && { keys[$ip]=1; agg_note "$rule" "$ip" "$te"; } ;;
      uri)    [[ -n $uri ]] && { keys[$uri]=1; agg_note "$rule" "$uri" "$te"; } ;;
      host)   { keys[host]=1; agg_note "$rule" "host" "$te"; } ;;
    esac
  done <"$P2S_STATE_DIR/hits.tsv"
  agg_prune "$rule" "$win"
  local k
  for k in "${!keys[@]}"; do
    local n
    n=$(agg_count "$rule" "$k" "$win")
    (( n >= min )) || continue
    agg_alert_recent "$rule" "$k" "$win" && continue
    agg_alert_mark "$rule" "$k"
    local cands evid
    cands=$(candidates_json 5)
    evid=$(printf '[{"source":"aggregate","file":"","line_ref":"","msg":"%s hits of %s in %ss (key=%s)"}]' "$n" "$rule" "$win" "$(json_escape "$k")")
    alert_emit "$rule" "$tier" "$sev" "medium" "$k" "$cands" "$evid" "agg ${n}/${min} in ${win}s"
  done
}

# ------------------------------------------------- pass 3: per-hit rules
_each_fire() { # <rule> <tier> <sev>
  local rule=$1 tier=$2 sev=$3 line r uri ev
  while IFS= read -r line; do
    r=$(_f "$line" 1)
    [[ $r == "$rule" ]] || continue
    uri=$(_f "$line" 5)
    ev=$(awk -F'\t' '{ $1=$2=$3=$4=$5=$6=""; sub(/^\t+/, ""); print }' <<<"$line")
    local cands
    cands=$(candidates_json 5)
    alert_emit "$rule" "$tier" "$sev" "high" "$uri" "$cands" \
      "$("$P2S_JQ" -c '[{source:.source,file:(.file // ""),line_ref:(.line_ref // ""),msg:(.msg // "")}]' <<<"$ev" 2>/dev/null)" ""
  done <"$P2S_STATE_DIR/hits.tsv"
}

while IFS= read -r _line; do
  _id=$(_f "$_line" 1)
  _tier=$(_f "$_line" 2)
  _sev=$(_f "$_line" 3)
  _enabled=$(_f "$_line" 6)
  [[ $_enabled == 1 ]] || continue
  case $_id in
    P2S-010) _agg_fire "$_id" "$_tier" "$_sev" host "${P2S010_WINDOW:-300}" "${P2S010_MIN:-5}" ;;
    P2S-016) _agg_fire "$_id" "$_tier" "$_sev" src_ip "${P2S016_WINDOW:-600}" "${P2S016_MIN:-5}" ;;
    *)       _each_fire "$_id" "$_tier" "$_sev" ;;
  esac
done <"$P2S_STATE_DIR/rules.loaded.tsv"

# ------------------------------------------------- pass 5: correlation upgrade
# T2+T3 in same window means active exploitation chain; log for analyst.
if corr_recent_tier T2 "${CORR_WINDOW:-5}" && corr_recent_tier T3 "${CORR_WINDOW:-5}"; then
  log_info "T2+T3 in same window: correlation CRITICAL candidates present"
fi

exit 0
