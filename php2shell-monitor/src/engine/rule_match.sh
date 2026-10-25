#!/usr/bin/env bash
# rule_match.sh - match the rule pack against the stream.
#
# Rule: {id, severity, impact, source[], match{field,pcre,and[],neg,min}}.
# Matching runs on the FIELD VALUE, not the TSV line, so anchored patterns hold.
# Output: matched records, field 12 = rule id, 13 = severity, 14 = impact.
set -u
WORKDIR=${WORKDIR:-/opt/php2shell-monitor}
SRCROOT=${P2S_SRC_DIR:-$WORKDIR}
source "$SRCROOT/lib/common.sh"
source "$SRCROOT/lib/paths.sh"
source "$SRCROOT/lib/stream.sh"

STREAM=$1
[[ -r $STREAM ]] || exit 0
p2s_device_init || exit 0

TMP=$(mktemp -d "$P2S_TMP_DIR/rules.XXXXXX") || exit 1
MATCHED=$TMP/matched.tsv
: >"$MATCHED"
trap 'rm -rf -- "$TMP"' EXIT

# ---------------------------------------------------------------- rule pack
# Rule pack đọc bằng lib/jsonl.awk, KHÔNG bằng jq. jq không có trên mọi host
# (image bất biến, máy offline, container tối giản) và thiếu nó từng làm monitor
# báo "no-hits" trong khi thực tế không đọc được rule nào. awk thì luôn có.
# Kết quả parse giống hệt jq — xem tests/run_tests.sh (so sánh từng field).
RULES_TSV=$TMP/rules.tsv
ANDS_TSV=$TMP/ands.tsv
: >"$RULES_TSV"
: >"$ANDS_TSV"

_rule_files() {
  local f
  for f in "$P2S_RULE_DIR/pack/"*.jsonl "$P2S_CONF_DIR"/rules.d/*.jsonl; do
    [[ -e $f ]] || continue
    printf '%s\n' "$f"
  done
}

if _rf=$(_rule_files) && [[ -n $_rf ]]; then
  # shellcheck disable=SC2086
  awk -f "$SRCROOT/lib/jsonl.awk" \
    rules="$RULES_TSV" ands="$ANDS_TSV" $_rf 2>/dev/null
fi

# Không parse được rule nào = monitor mù. Nói thẳng thay vì lặng lẽ no-hits.
if [[ ! -s $RULES_TSV ]]; then
  log_error "không đọc được rule pack trong $P2S_RULE_DIR/pack — batch bỏ qua"
  printf 'rule-error\tno-rules-parsed\t0 hit(s)\n' >>"$P2S_DEVICE_RUN_DIR/batches.log"
  exit 1
fi

# Field name -> awk column.
_fi() { stream_field_index "$1"; }

# Line numbers (1-based, into $STREAM) whose field <n> matches <pcre>.
_field_hits() { # <field_name> <pcre> <out> [invert]
  local field=$1 pcre=$2 out=$3 invert=${4:-0} n
  n=$(_fi "$field")
  : >"$out"
  (( n > 0 )) || return 0
  awk -F'\t' -v n="$n" '{ print $n }' "$STREAM" >"$TMP/col"
  if (( invert )); then
    grep -nvP -- "$pcre" "$TMP/col" 2>/dev/null | cut -d: -f1 >"$out" || true
  else
    grep -nP -- "$pcre" "$TMP/col" 2>/dev/null | cut -d: -f1 >"$out" || true
  fi
  return 0
}

# Line numbers whose source is in <csv> (empty csv = all sources).
_source_hits() { # <csv> <out>
  local csv=$1 out=$2
  : >"$out"
  [[ -z $csv ]] && return 0
  awk -F'\t' -v csv="$csv" '
    BEGIN { n = split(csv, a, ","); for (i = 1; i <= n; i++) want[a[i]] = 1 }
    want[$2] { print NR }
  ' "$STREAM" >"$out"
  return 0
}

# Intersect two newline-separated line-number files in place.
# comm compares byte order, so both inputs must be sorted the same way (LC_ALL=C,
# lexicographic) — numeric sort would break comm for >=10 lines.
_intersect() { # <base> <other>
  LC_ALL=C sort -u "$1" -o "$1"
  LC_ALL=C sort -u "$2" -o "$2"
  comm -12 "$1" "$2" >"$TMP/i" && mv -f -- "$TMP/i" "$1"
}

_hit_count() { wc -l <"$1" | tr -d ' '; }

# Emit the matching records for one rule.
# One rule can match the same stream line several ways (and several rules can
# match the same line), which inflates "hits" without adding information. A
# hit is unique per (source, file, line, rule) — the same raw log line is
# reported once per rule that fired on it.
_emit_rule() { # <hitsfile> <rule> <severity> <impact>
  local hits=$1 rule=$2 sev=$3 impact=${4:-}
  awk -F'\t' -v OFS='\t' -v rule="$rule" -v sev="$sev" -v impact="$impact" '
    NR == FNR { want[$1] = 1; next }
    FNR in want { $12 = rule; $13 = sev; $14 = impact; print }
  ' "$hits" "$STREAM" >>"$MATCHED"
}

# Collapse to ONE event per raw log line. The same access-log line can satisfy
# several rules (LFI path + php:// wrapper, etc.); counting it twice inflates
# the event total and the Telegram message. Rules are merged into a comma list
# and the highest severity wins.
_dedup_events() { # <in> <out>
  awk -F'\t' -v OFS='\t' '
    function rank(s) {
      if (s == "CRITICAL") return 4
      if (s == "HIGH") return 3
      if (s == "MEDIUM") return 2
      if (s == "LOW") return 1
      return 0
    }
    {
      key = $2 SUBSEP $3 SUBSEP $4
      if (key in sev) {
        if (index("," rules[key] ",", "," $12 ",") == 0) rules[key] = rules[key] "," $12
        if (rank($13) > rank(sev[key])) sev[key] = $13
        # impact is sticky: one line proving RCE marks the whole event
        if ($14 == "rce") impact[key] = "rce"
        next
      }
      order[++n] = key
      sev[key] = $13
      rules[key] = $12
      impact[key] = $14
      line[key] = $0
    }
    END {
      for (i = 1; i <= n; i++) {
        k = order[i]
        nf = split(line[k], f, "\t")
        f[12] = rules[k]
        f[13] = sev[k]
        f[14] = impact[k]
        nf = (nf < 14) ? 14 : nf
        out = f[1]
        for (j = 2; j <= nf; j++) out = out "\t" f[j]
        print out
      }
    }
  ' "$1" >"$2"
}

rules_run() {
  local id sev impact enabled needs src mtype field pcre min
  local -A seen=()

  # Rule pack đã được parse thành TSV ở trên. Dòng sau ghi đè dòng trước cùng id
  # (rules.d/ thắng pack/), giữ đúng thứ tự xuất hiện để log dễ đọc.
  local -a order=()
  while IFS=$'\037' read -r id sev impact enabled needs src mtype field pcre min; do
    [[ -z $id ]] && continue
    [[ -n ${seen[$id]+x} ]] || order+=("$id")
    seen[$id]="$sev"$'\037'"$impact"$'\037'"$enabled"$'\037'"$needs"$'\037'"$src"$'\037'"$mtype"$'\037'"$field"$'\037'"$pcre"$'\037'"$min"
  done <"$RULES_TSV"

  local key
  for key in "${order[@]}"; do
    IFS=$'\037' read -r sev impact enabled needs src mtype field pcre min <<<"${seen[$key]}"
    id=$key

    [[ $enabled == true || $enabled == 1 ]] || continue

    # capability gate: every listed need must be present
    if [[ -n $needs ]]; then
      local need bad=0
      IFS=, read -ra _needs <<<"$needs"
      for need in "${_needs[@]}"; do
        [[ -z $need ]] && continue
        grep -qx "$need" "$P2S_STATE_DIR/capabilities.txt" 2>/dev/null || bad=1
      done
      (( bad )) && continue
    fi

    sev=${sev^^}
    [[ -n $sev ]] || sev=MEDIUM
    [[ -n $min ]] || min=1
    [[ -z $pcre ]] && continue
    [[ $mtype == regex || $mtype == literal || $mtype == fs || $mtype == proc ]] || continue

    local hits="$TMP/hits.$id" cur="$TMP/cur.$id"
    : >"$hits"
    if [[ -n $src ]]; then
      _source_hits "$src" "$hits"
    else
      seq 1 "$(wc -l <"$STREAM")" >"$hits"
    fi

    _field_hits "$field" "$pcre" "$cur" 0
    _intersect "$hits" "$cur"

    # additional AND conditions, each possibly negated
    local cfield cpcre cneg inv
    while IFS=$'\037' read -r _aid cfield cpcre cneg; do
      [[ $_aid == "$id" ]] || continue
      [[ -z $cfield || -z $cpcre ]] && continue
      inv=0
      [[ $cneg == 1 ]] && inv=1
      _field_hits "$cfield" "$cpcre" "$cur" "$inv"
      _intersect "$hits" "$cur"
    done <"$ANDS_TSV"

    local n
    n=$(_hit_count "$hits")
    (( n == 0 )) && continue
    if (( n < min )); then
      printf 'suppressed\t%s\t%d hit(s) < min %s\n' "$id" "$n" "$min" \
        >>"$P2S_DEVICE_RUN_DIR/batches.log"
      continue
    fi
    _emit_rule "$hits" "$id" "$sev" "$impact"
  done

  # de-dup: 1 dòng log = 1 event, severity cao nhất, rule gộp bằng dấu phẩy
  _dedup_events "$MATCHED" "$TMP/events.tsv"
  cat -- "$TMP/events.tsv"
}

rules_run
