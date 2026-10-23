#!/usr/bin/env bash
# rules.sh - load rule pack (JSONL) + local overrides, resolve enable state.
# Output: $P2S_STATE_DIR/rules.loaded.tsv  (id, tier, severity, source_csv, needs_csv, enabled, reason)
[[ -n ${P2S_RULES_SH:-} ]] && return 0
P2S_RULES_SH=1
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
P2S_STATE_DIR=${P2S_STATE_DIR:-$WORKDIR/state}
P2S_RULE_DIR=${P2S_RULE_DIR:-$WORKDIR/rules}
P2S_CONF_DIR=${P2S_CONF_DIR:-$WORKDIR/conf}

# JSON string field extractor without jq (jq used when present for correctness).
_rule_field() {
  local json=$1 key=$2
  if [[ -n ${P2S_JQ:-} ]]; then
    "$P2S_JQ" -r --arg k "$key" '.[$k] // empty' <<<"$json" 2>/dev/null
  else
    # fall back: "key":"value" (string fields only)
    printf '%s' "$json" | grep -oP "\"$key\"\s*:\s*\"\K[^\"]*" | head -1
  fi
}

# Load all rule lines: pack + overrides (last wins per id). Reason notes why off.
rules_load() {
  local -A seen=()
  local f id line json enabled reason
  : >"$P2S_STATE_DIR/rules.loaded.tsv"
  for f in "$P2S_RULE_DIR/pack/"*.jsonl "$P2S_CONF_DIR"/rules.d/*.jsonl; do
    [[ -e $f ]] || continue
    while IFS= read -r line; do
      [[ -z ${line//[[:space:]]/} || $line == \#* ]] && continue
      json=$line
      id=$("$P2S_JQ" -r '.id // empty' <<<"$json" 2>/dev/null)
      [[ -z $id ]] && continue
      seen[$id]=$json
      seen["$id:file"]=$f
    done <"$f"
  done
  local id json tier sev src needs enabled_j needs_list
  for id in "${!seen[@]}"; do
    [[ $id == *:file ]] && continue
    json=${seen[$id]}
    tier=$("$P2S_JQ" -r '.tier // "T1"' <<<"$json" 2>/dev/null)
    sev=$("$P2S_JQ" -r '.severity // "low"' <<<"$json" 2>/dev/null)
    src=$("$P2S_JQ" -r '.source | join(",")' <<<"$json" 2>/dev/null)
    needs_list=$("$P2S_JQ" -r '.needs | join(",")' <<<"$json" 2>/dev/null)
    enabled_j=$("$P2S_JQ" -r '.enabled // true' <<<"$json" 2>/dev/null)
    enabled=1; reason=""
    if [[ $enabled_j == false ]]; then
      enabled=0; reason="disabled in pack/config"
    fi
    # needs resolution vs host capabilities (written by discovery/scan)
    local need missing=0
    if [[ -n $needs_list ]]; then
      IFS=, read -ra _needs_arr <<<"$needs_list"
      for need in "${_needs_arr[@]}"; do
        [[ -z $need ]] && continue
        if ! grep -qx "$need" "$P2S_STATE_DIR/capabilities.txt" 2>/dev/null; then
          missing=1; reason="missing capability: $need"
        fi
      done
      [[ $missing -eq 1 ]] && enabled=0
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$id" "$tier" "$sev" "$src" "$needs_list" "$enabled" "$reason" >>"$P2S_STATE_DIR/rules.loaded.tsv"
  done
  sort -o "$P2S_STATE_DIR/rules.loaded.tsv" "$P2S_STATE_DIR/rules.loaded.tsv"
}

rules_enabled_ids() {
  awk -F'\t' '$6 == 1 { print $1 }' "$P2S_STATE_DIR/rules.loaded.tsv"
}

rule_field_by_id() { # <id> <column 1..7>
  awk -F'\t' -v id="$1" -v c="$2" '$1 == id { print $c; exit }' "$P2S_STATE_DIR/rules.loaded.tsv"
}
