#!/usr/bin/env bash
# baseline.sh - per-host/per-pool baseline learner (plan 4 T1, risk 8.1-5).
# Learns: which (ip,uri) pairs ever saw POST; POST/.php counts per 5-min bucket
# per ip; referer/UA diversity per uri (P2S-026 rare-uri); memory-exhausted count
# per pool for P2S-010 escalation. Attack window (BASELINE_EXCLUDE_SINCE) is
# excluded from learning and labeled.
[[ -n ${P2S_BASELINE_SH:-} ]] && return 0
P2S_BASELINE_SH=1
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

BASELINE_FILE=${BASELINE_FILE:-$P2S_STATE_DIR/baseline.tsv}   # kind \t key \t count \t first_epoch \t last_epoch
P2S_BASELINE_MODE=${P2S_BASELINE_MODE:-learning}

baseline_mode() {
  if [[ -f $P2S_STATE_DIR/baseline.mode ]]; then
    cat "$P2S_STATE_DIR/baseline.mode"
  else
    echo "${P2S_BASELINE_MODE:-learning}"
  fi
}

baseline_set_mode() { printf '%s\n' "$1" >"$P2S_STATE_DIR/baseline.mode"; }

# Learn one access event. Args: method uri status ip referer ua ts_epoch
baseline_learn_access() {
  local method=$1 uri=$2 status=$3 ip=$4 referer=$5 ua=$6 ts=$7
  [[ -z $ip || -z $uri ]] && return 0
  # attack-window exclusion: events since EXCLUDE are NOT learned
  local cut
  cut=$(iso_to_epoch "${BASELINE_EXCLUDE_SINCE:-}" 2>/dev/null)
  if [[ -n $cut && $ts -ge $cut ]]; then
    printf 'excluded\t%s\t%s\t%s\n' "$ip" "$uri" "$ts" >>"$P2S_STATE_DIR/baseline.excluded.tsv"
    return 0
  fi
  local kind key
  if [[ $method == POST && $uri == *.php* ]]; then
    kind=php_post; key="$uri"
  elif [[ $method == POST ]]; then
    kind=post_uri; key="$uri"
  else
    kind=uri_seen; key="$uri"
  fi
  _baseline_bump "$kind" "$key" "$ts"
  _baseline_bump "${kind}_ip" "$ip|$uri" "$ts"
  if [[ -n $referer ]]; then _baseline_bump uri_ref "$uri|$referer" "$ts"; fi
  if [[ -n $ua ]]; then _baseline_bump uri_ua "$uri|$ua" "$ts"; fi
  _baseline_bump ip_seen "$ip" "$ts"
}

# Learn an FPM memory-exhausted occurrence per pool/file context.
baseline_learn_fpm_mem() { # <pool_or_file_key> <ts_epoch>
  _baseline_bump fpm_mem "$1" "$2"
}

baseline_get() { # <kind> <key> -> count
  awk -F'\t' -v k="$1" -v key="$2" '$1==k && $2==key { print $3; exit }' "$BASELINE_FILE" 2>/dev/null
}

_baseline_bump() {
  local kind=$1 key=$2 ts=$3
  local line count first
  line=$(awk -F'\t' -v k="$kind" -v key="$key" '
    $1==k && $2==key { print NR "\t" $3 "\t" $4; exit }' "$BASELINE_FILE" 2>/dev/null)
  if [[ -n $line ]]; then
    local nr cnt fst
    nr=${line%%	*}; rest=${line#*	}; cnt=${rest%%	*}; fst=${rest##*	}
    local tmp
    tmp="$BASELINE_FILE.tmp.$$"
    awk -F'\t' -v nr="$nr" -v ts="$ts" -v cnt="$cnt" \
      'NR==nr { $3=cnt+1; $5=ts } { print }' OFS='\t' "$BASELINE_FILE" >"$tmp" &&
      mv -f -- "$tmp" "$BASELINE_FILE"
  else
    printf '%s\t%s\t%s\t%s\t%s\n' "$kind" "$key" 1 "$ts" "$ts" >>"$BASELINE_FILE"
  fi
}

# Auto-promote learning -> learned after N batches (conf default 2016 = 7d).
baseline_tick() {
  local n=0 f="$P2S_STATE_DIR/baseline.batches"
  [[ -f $f ]] && n=$(cat "$f")
  n=$((n + 1))
  printf '%s\n' "$n" >"$f"
  local max=${BASELINE_LEARNING_MAX_BATCHES:-2016}
  if [[ $(baseline_mode) == learning && $n -ge $max ]]; then
    baseline_set_mode learned
    log_info "baseline auto-promoted to learned after $n batches"
  fi
}
