#!/usr/bin/env bash
# watch.sh - realtime watcher (plan 4 T2/T3, plan 5: tail -F based).
# Emits the same stream records as batch plugins; each event is scored inline
# by score_alerts.sh so T2/T3 alerts land within seconds.
set -u
WORKDIR=${WORKDIR:-/tmp/php2shell-monitor}
# shellcheck source=/dev/null
source "$WORKDIR/lib/common.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/log.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/stream.sh"
# shellcheck source=/dev/null
source "$WORKDIR/lib/time_utc.sh"

LOG_INFO_TAG="watch"

# Resolve the same paths as plugins (duplicated small helpers, keep in sync).
fpm_logs() {
  local -a out=()
  local f
  for f in /var/log/php*-fpm*.log /var/log/php-fpm/*.log /usr/local/cpanel/logs/php-fpm/*.log; do
    [[ -f $f && -r $f ]] && out+=("$f")
  done
  ((${#out[@]})) && printf '%s\n' "${out[@]}"
  return 0
}
apache_error_logs() {
  local -a out=()
  local f
  for f in /var/log/apache2/error.log /var/log/httpd/error_log; do
    [[ -f $f && -r $f ]] && out+=("$f")
  done
  ((${#out[@]})) && printf '%s\n' "${out[@]}"
  return 0
}
nginx_error_logs() {
  local f=/var/log/nginx/error.log
  [[ -f $f && -r $f ]] && printf '%s\n' "$f"
  return 0
}

WATCH_DIR=$WORKDIR/run/watch
mkdir -p -- "$WATCH_DIR"

# tail a file and emit records per matching line
_tail_stream() { # <file> <source> <pattern> <tier> <rule>
  local file=$1 source=$2 pattern=$3 tier=$4 rule=$5
  [[ -r $file ]] || return 0
  local tag; tag=$(basename "$file" | tr -c 'a-zA-Z0-9._-' '_')
  local stamp="$WATCH_DIR/$tag.$source.stamp"
  touch -- "$stamp"
  tail -F -n 0 -- "$file" 2>/dev/null |
  while IFS= read -r line; do
    ts=$(t_extract_fpm_ts "$line" || t_extract_journal_ts "$line" || t_syslog_noyear_to_utc "$(printf '%s' "$line" | cut -c1-15)" || utc_now)
    P2S_TS=$ts emit_record "$source" "" "" "" "" "" "" "" "" "" "$rule" "$line" 2>/dev/null
  done >>"$P2S_STATE_DIR/stream.watch.tsv" &
  echo $! >>"$WATCH_DIR/pids"
}

: >"$P2S_STATE_DIR/stream.watch.tsv"

# T2: FPM errors (memory exhausted, sig11, timeout, exit codes)
for f in $(fpm_logs); do
  _tail_stream "$f" fpm_error \
    'Allowed memory size of|PHP Fatal error: +Out of memory|Hard memory limit of|in Unknown on line 0|exited on signal (6|7|11)|execution timed out|exit code (70|137)|SEGSEGV|signal 11' \
    T2 P2S-010
done
# T2: apache mod_php segfault
for f in $(apache_error_logs); do
  _tail_stream "$f" apache_error \
    'exit signal Segmentation fault|exited on signal (6|7|11)|Child process .* exited' \
    T2 P2S-011
done
# T2: nginx upstream failures
for f in $(nginx_error_logs); do
  _tail_stream "$f" nginx_error \
    'upstream prematurely closed connection|recv\(\) failed \(104|upstream sent unexpected FastCGI record: 3' \
    T2 P2S-014
done
if have journalctl; then
  (journalctl -kf -n 0 --output=short-iso 2>/dev/null |
   while IFS= read -r line; do
     printf '%s' "$line" | grep -P 'segfault|Out of memory|Killed process' >/dev/null 2>&1 || continue
     ts=$(t_extract_journal_ts "$line" || utc_now)
     P2S_TS=$ts emit_record journal "" "" "" "" "" "" "" "" "" "P2S-011" "$line"
   done >>"$P2S_STATE_DIR/stream.watch.tsv") &
  echo $! >>"$WATCH_DIR/pids"
fi
# T3: auditd execve
if [[ -r /var/log/audit/audit.log ]]; then
  _tail_stream /var/log/audit/audit.log auditd \
    'type=EXECVE|type=SYSCALL.*execve' T3 P2S-021
fi

log_info "watcher started (tails active)"
p2s_status_write "watcher_started" 2>/dev/null || true

# Feed watch stream into scoring every 10s (cheap: file stays small, pruned).
while true; do
  sleep 10
  if [[ -s $P2S_STATE_DIR/stream.watch.tsv ]]; then
    local_size=$(wc -c <"$P2S_STATE_DIR/stream.watch.tsv")
    if (( local_size > 0 )); then
      cp "$P2S_STATE_DIR/stream.watch.tsv" "$P2S_STATE_DIR/stream.watch.tsv.inflight"
      : >"$P2S_STATE_DIR/stream.watch.tsv"
      # run scoring on the inflight batch (json path expects matched jsonl; use rule_match)
      bash "$WORKDIR/engine/rule_match.sh" "$P2S_STATE_DIR/stream.watch.tsv.inflight" \
        >"$P2S_STATE_DIR/watch.matched.jsonl" 2>/dev/null || true
      bash "$WORKDIR/engine/score_alerts.sh" "$P2S_STATE_DIR/watch.matched.jsonl" 2>/dev/null || true
      rm -f -- "$P2S_STATE_DIR/stream.watch.tsv.inflight"
    fi
  fi
done
