#!/usr/bin/env bash
# scoring.sh - aggregated score -> severity (plan 4 scoring table)
[[ -n ${P2S_SCORING_SH:-} ]] && return 0
P2S_SCORING_SH=1

# Per-hit weights
score_for_tier() {
  case $1 in
    T1) echo 5 ;;
    T2) echo 15 ;;
    T3) echo 40 ;;
    *)  echo 1 ;;
  esac
}

# Combine: any T3 alone is CRITICAL; T2 sig11 HIGH; sums map via thresholds.
score_classify() { # <total_score> <has_t3 0/1> <has_sig11 0/1> <baseline_mode>
  local total=$1 has_t3=$2 has_sig11=$3 mode=$4
  if (( has_t3 )); then echo CRITICAL; return 0; fi
  if (( has_sig11 )); then echo HIGH; return 0; fi
  local med=${SCORE_MEDIUM:-10} high=${SCORE_HIGH:-40} crit=${SCORE_CRITICAL:-80}
  if (( total >= crit )); then echo CRITICAL
  elif (( total >= high )); then echo HIGH
  elif (( total >= med )); then
    if [[ $mode == learning ]]; then echo MEDIUM_LOWCONF; else echo MEDIUM; fi
  else
    if [[ $mode == learning ]]; then echo LOW_LOWCONF; else echo LOW; fi
  fi
}
