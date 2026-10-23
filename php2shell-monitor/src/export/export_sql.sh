#!/usr/bin/env bash
# export_sql.sh - plain .sql INSERT statements (no DB client dependency).
# Values escaped via lib/sql.sh to prevent injection on import (plan 5.1).
# Target schema (documented in header comment of the produced file):
#   CREATE TABLE IF NOT EXISTS p2s_alerts (
#     ts_utc TEXT, host TEXT, rule_id TEXT, tier TEXT, severity TEXT,
#     confidence TEXT, src_ip TEXT, uri TEXT, baseline_mode TEXT,
#     notes TEXT, evidence TEXT);
# Escape convention: standard SQL — single quotes doubled; backslashes are
# literal (Postgres default, MySQL needs NO_BACKSLASH_ESCAPES).
set -u
WORKDIR=${WORKDIR:-/tmp/php2shell-monitor}
# shellcheck source=/dev/null
source "$WORKDIR/lib/common.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/sql.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/json.sh"

QUEUE=$P2S_ALERT_DIR/queue.jsonl
OUT=$P2S_EXPORT_DIR/alerts-$(date -u +%Y%m%dT%H%M%SZ).sql

[[ -s $QUEUE ]] || { echo "no alerts to export"; exit 0; }

{
  echo "-- php2shell-monitor alert export $(utc_now)"
  echo "-- Import target-agnostic; single-statement inserts, idempotent by design."
  cat <<'EOF'
CREATE TABLE IF NOT EXISTS p2s_alerts (
  ts_utc TEXT, host TEXT, rule_id TEXT, tier TEXT, severity TEXT,
  confidence TEXT, src_ip TEXT, uri TEXT, baseline_mode TEXT,
  notes TEXT, evidence TEXT);
EOF

  while IFS= read -r line; do
    [[ -z $line ]] && continue
    [[ -n ${P2S_JQ:-} ]] || continue
    ts=$("$P2S_JQ" -r '.ts_utc // ""' <<<"$line" 2>/dev/null)
    host=$("$P2S_JQ" -r '.host // ""' <<<"$line" 2>/dev/null)
    rule=$("$P2S_JQ" -r '.rule_id // ""' <<<"$line" 2>/dev/null)
    tier=$("$P2S_JQ" -r '.tier // ""' <<<"$line" 2>/dev/null)
    sev=$("$P2S_JQ" -r '.severity // ""' <<<"$line" 2>/dev/null)
    conf=$("$P2S_JQ" -r '.confidence // ""' <<<"$line" 2>/dev/null)
    ip=$("$P2S_JQ" -r '.src_ip_candidates[0].ip // ""' <<<"$line" 2>/dev/null)
    uri=$("$P2S_JQ" -r '.uri // ""' <<<"$line" 2>/dev/null)
    bmode=$("$P2S_JQ" -r '.baseline_mode // ""' <<<"$line" 2>/dev/null)
    notes=$("$P2S_JQ" -r '.notes // ""' <<<"$line" 2>/dev/null)
    evid=$("$P2S_JQ" -c '.evidence' <<<"$line" 2>/dev/null)
    printf "INSERT INTO p2s_alerts VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s);\n" \
      "$(sql_str "$ts")" "$(sql_str "$host")" "$(sql_str "$rule")" "$(sql_str "$tier")" \
      "$(sql_str "$sev")" "$(sql_str "$conf")" "$(sql_str "$ip")" "$(sql_str "$uri")" \
      "$(sql_str "$bmode")" "$(sql_str "$notes")" "$(sql_str "$evid")"
  done <"$QUEUE"
} >"$OUT"

echo "exported SQL -> $OUT"
