#!/usr/bin/env bash
# correlator.sh - candidate-IP ranking and cross-tier correlation state.
#
# Design rule (plan 6.4): one IP cannot identify a PHP worker. FPM lines carry no
# IP, so T2/T3 events yield RANKED CANDIDATE IPs from T1 history, never a claim.
[[ -n ${P2S_CORR_SH:-} ]] && return 0
P2S_CORR_SH=1
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

CORR_FILE=${CORR_FILE:-$P2S_STATE_DIR/corr.tsv}
# Fields: epoch \t tier \t rule \t ip \t uri

corr_note() { # <tier> <rule> <ip> <uri>
  local tier=$1 rule=$2 ip=$3 uri=${4:-}
  [[ -z $ip ]] && return 0
  printf '%s\t%s\t%s\t%s\t%s\n' "$(utc_epoch)" "$tier" "$rule" "$ip" "$uri" >>"$CORR_FILE"
}

corr_prune() {
  local win=${1:-1800} tmp
  [[ -f $CORR_FILE ]] || return 0
  tmp="$CORR_FILE.tmp.$$"
  awk -F'\t' -v cut=$(( $(utc_epoch) - win )) '$1 >= cut' "$CORR_FILE" >"$tmp" &&
    mv -f -- "$tmp" "$CORR_FILE"
}

# Ranked candidate IPs for a T2/T3 event at now: T1 hits in the last <win> seconds.
# Output TSV: ip \t hits \t last_epoch \t sample_uri ; sorted by hits desc.
corr_candidates() {
  local win=${1:-${CORR_WINDOW_MAX:-30}} tmp
  local cut=$(( $(utc_epoch) - win ))
  [[ -f $CORR_FILE ]] || return 0
  awk -F'\t' -v cut="$cut" '
    $1 >= cut && $2 == "T1" && $4 != "" {
      n[$4]++; last[$4]=$1; uri[$4]=$5
    }
    END {
      for (ip in n) printf "%s\t%d\t%d\t%s\n", ip, n[ip], last[ip], uri[ip]
    }' "$CORR_FILE" | sort -t$'\t' -k2,2nr | head -5
}

# True (0) when a T2/T3 event on this host happened within <win> seconds.
corr_recent_tier() { # <tier> <win>
  local tier=$1 win=${2:-600} cut
  cut=$(( $(utc_epoch) - win ))
  [[ -f $CORR_FILE ]] || return 1
  awk -F'\t' -v cut="$cut" -v t="$tier" '$1 >= cut && $2 == t { f=1 } END { exit(f?0:1) }' "$CORR_FILE"
}
