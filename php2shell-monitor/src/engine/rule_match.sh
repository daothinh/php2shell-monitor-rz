#!/usr/bin/env bash
# rule_match.sh - data-driven matcher: rules/pack/*.jsonl + conf/rules.d/*.jsonl
# consume the normalized stream (stdin = TSV records, lib/stream.sh contract).
# Output: matched stream records with rule id in field 12 (one line per rule hit;
# a record can match several rules and is emitted once per rule).
#
# Supported match.type (plan 6.2):
#   regex   field PCRE (grep -P)          literal  substring
#   seq     a then b, same key, window    proc     parent/child names
#   fs      file path pattern             cfg      (discovery only; never matches here)
#
# Aggregations agg.by=src_ip|uri|host with agg.window_s+agg.min are enforced by
# score_alerts.sh (which sees the raw hits); this file only filters.
SRCROOT=${P2S_SRC_DIR:-$WORKDIR}
if [[ ! -f $SRCROOT/lib/common.sh && -d /tmp/php2shell-monitor/lib ]]; then
  SRCROOT=/tmp/php2shell-monitor
fi
# shellcheck source=/dev/null
source "$SRCROOT/lib/common.sh"
# shellcheck source=/dev/null
source "$SRCROOT/lib/stream.sh"

STREAM=$1
[[ -r $STREAM ]] || exit 0

# Load rules into parallel arrays.
RULE_IDS=(); RULE_TIER=(); RULE_SEV=(); RULE_TYPE=(); RULE_FIELD=(); RULE_PCRE=()
RULE_SRC=(); RULE_NEEDS=(); RULE_ENABLED=()

_load_rules() {
  local f line id tier sev mtype field pcre enabled needs src
  local -A seen=()
  for f in "$WORKDIR/rules/pack/"*.jsonl "$WORKDIR"/conf/rules.d/*.jsonl; do
    [[ -e $f ]] || continue
    while IFS= read -r line; do
      [[ -z ${line//[[:space:]]/} || $line == \#* ]] && continue
      id=$("$P2S_JQ" -r '.id // empty' <<<"$line" 2>/dev/null)
      [[ -z $id ]] && continue
      seen[$id]=$line
    done <"$f"
  done
  for id in "${!seen[@]}"; do
    line=${seen[$id]}
    tier=$("$P2S_JQ" -r '.tier // "T1"' <<<"$line")
    sev=$("$P2S_JQ" -r '.severity // "low"' <<<"$line")
    mtype=$("$P2S_JQ" -r '.match.type // "regex"' <<<"$line")
    field=$("$P2S_JQ" -r '.match.field // "msg"' <<<"$line")
    pcre=$("$P2S_JQ" -r '.match.pcre // empty' <<<"$line")
    enabled=$("$P2S_JQ" -r '.enabled // true' <<<"$line")
    needs=$("$P2S_JQ" -r '.needs | join(",")' <<<"$line" 2>/dev/null)
    src=$("$P2S_JQ" -r '.source | join(",")' <<<"$line" 2>/dev/null)
    RULE_IDS+=("$id"); RULE_TIER+=("$tier"); RULE_SEV+=("$sev")
    RULE_TYPE+=("$mtype"); RULE_FIELD+=("$field"); RULE_PCRE+=("$pcre")
    RULE_SRC+=("$src"); RULE_NEEDS+=("$needs"); RULE_ENABLED+=("$enabled")
  done
}

# Convert a stream field name to awk $N.
_fi() { stream_field_index "$1"; }

# Filter one rule: emit matching records (with rule id set in field 12).
_match_regex() {
  local idx=$1 pcre=$2 field=$3 id=$4 tier=$5 sev=$6
  local n; n=$(_fi "$field")
  (( n > 0 )) || n=13
  grep -P -- "$pcre" "$STREAM" 2>/dev/null |
    awk -F'\t' -v OFS='\t' -v n="$n" -v id="$id" -v tier="$tier" '$1 != "" { $12 = id; $14 = tier; print }'
}

main() {
  _load_rules
  local i id tier sev mtype field pcre enabled
  for i in "${!RULE_IDS[@]}"; do
    id=${RULE_IDS[$i]}; tier=${RULE_TIER[$i]}; sev=${RULE_SEV[$i]}
    mtype=${RULE_TYPE[$i]}; field=${RULE_FIELD[$i]}; pcre=${RULE_PCRE[$i]}
    enabled=${RULE_ENABLED[$i]}
    [[ $enabled == true || $enabled == 1 ]] || continue
    # capabilities gating
    if [[ -n ${RULE_NEEDS[$i]} ]]; then
      IFS=, read -ra _needs <<<"${RULE_NEEDS[$i]}"
      local cap bad=0
      for cap in "${_needs[@]}"; do
        grep -qx "$cap" "$WORKDIR/state/capabilities.txt" 2>/dev/null || bad=1
      done
      (( bad )) && continue
    fi
    case $mtype in
      regex)
        [[ -n $pcre ]] || continue
        _match_regex "$i" "$pcre" "$field" "$id" "$tier" "$sev"
        ;;
      literal)
        [[ -n $pcre ]] || continue
        local n; n=$(_fi "$field"); (( n > 0 )) || n=13
        grep -F -- "$pcre" "$STREAM" 2>/dev/null |
          awk -F'\t' -v OFS='\t' -v n="$n" -v id="$id" -v tier="$tier" '$1 != "" { $12 = id; $14 = tier; print }'
        ;;
      fs)
        # file events: records carry non-empty file field; pcre matches path
        awk -F'\t' -v OFS='\t' -v id="$id" -v tier="$tier" '$11 != "" { $12 = id; $14 = tier; print }' "$STREAM" |
          grep -P -- "$pcre" 2>/dev/null || true
        ;;
      proc)
        # proc plugin emits msg="parent|child"; match both PCREs
        [[ -n $pcre ]] || continue
        awk -F'\t' -v OFS='\t' -v id="$id" -v pcre="$pcre" '
          $2 == "proc" && $13 != "" { $12 = id; $14 = tier; print }' "$STREAM" |
        grep -P -- "$pcre" 2>/dev/null || true
        ;;
      seq)
        # pair matching handled in score_alerts.sh (needs window state)
        awk -F'\t' -v OFS='\t' -v id="$id" -v tier="$tier" '$1 != "" { $12 = id; $14 = tier; print }' "$STREAM"
        ;;
      *) : ;;
    esac
  done | _stream_to_json
}

_stream_to_json() {
  "$P2S_JQ" -R -c '
    split("\t") as $f |
    {ts:$f[0], source:$f[1], src_ip:$f[2], method:$f[3], uri:$f[4],
     status:$f[5], size:$f[6], ua:$f[7], pid:$f[8], sessid:$f[9],
     file:$f[10], rule:$f[11], msg:$f[12], tier:($f[13] // "")}
  ' 2>/dev/null
}

main
