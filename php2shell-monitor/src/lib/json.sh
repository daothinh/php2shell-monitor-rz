#!/usr/bin/env bash
# json.sh - minimal JSON emission without a subprocess per value.
[[ -n ${P2S_JSON_SH:-} ]] && return 0
P2S_JSON_SH=1

json_escape() {
  local s=${1-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  s=${s//$'\b'/\\b}
  s=${s//$'\f'/\\f}
  local out='' i c
  if [[ $s == *[$'\x01'-$'\x1f']* ]]; then
    local LC_ALL=C
    for ((i = 0; i < ${#s}; i++)); do
      c=${s:i:1}
      case $c in
        [$'\x01'-$'\x1f']) out+=$(printf '\\u%04x' "'$c") ;;
        *) out+=$c ;;
      esac
    done
    s=$out
  fi
  printf '%s' "$s"
}

json_str() { printf '"%s"' "$(json_escape "${1-}")"; }

json_num() {
  local v=${1-}
  if [[ $v =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
    printf '%s' "$v"
  else
    printf 'null'
  fi
}

# json_obj key1 value1_json key2 value2_json ...
json_obj() {
  local out='{' first=1 k v
  while [[ $# -ge 2 ]]; do
    k=$1; v=$2; shift 2
    [[ $first -eq 1 ]] && first=0 || out+=','
    out+="\"$(json_escape "$k")\":$v"
  done
  printf '%s}' "$out"
}
