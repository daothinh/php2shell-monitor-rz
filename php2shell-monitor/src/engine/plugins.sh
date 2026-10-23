#!/usr/bin/env bash
# plugins.sh - plugin loader. Each plugin:
#   - defines plugin_name, plugin_source (canonical event source id)
#   - implements plugin_run() emitting events on stdout (one JSON per line)
#   - implements plugin_available() returning 0 when its sources exist
# A failing/missing plugin never aborts the scan (plan 0.3): the loader
# isolates each plugin in a subshell with a timeout and logs failures.
[[ -n ${P2S_PLUGINS_SH:-} ]] && return 0
P2S_PLUGINS_SH=1
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

PLUGIN_TIMEOUT=${PLUGIN_TIMEOUT:-120}

# Run every enabled plugin; events land in $P2S_EVENT_DIR/events-<plugin>.jsonl
run_all_plugins() {
  local p name out rc
  local event_dir=$P2S_EVENT_DIR
  mkdir -p -- "$event_dir"
  for p in "$P2S_PLUGIN_DIR"/*.sh; do
    [[ -e $p ]] || continue
    name=$(basename "$p" .sh)
    # per-run plugin disable switch: conf/plugins_disabled (space separated names)
    if [[ " ${P2S_PLUGINS_DISABLED:-} " == *" $name "* ]]; then
      log_info "plugin disabled by config: $name"
      continue
    fi
    out="$event_dir/events-$name.jsonl"
    : >"$out"
    timeout "$PLUGIN_TIMEOUT" bash "$p" >"$out" 2>"$event_dir/err-$name.log"
    rc=$?
    if [[ $rc -ne 0 ]]; then
      log_warn "plugin $name rc=$rc (source skipped, scan continues)"
      printf 'plugin\t%s\trc=%s\t%s\n' "$name" "$rc" "$(utc_now)" >>"$P2S_RUN_DIR/plugin_status.tsv"
    else
      printf 'plugin\t%s\tok\t%s\n' "$name" "$(utc_now)" >>"$P2S_RUN_DIR/plugin_status.tsv"
    fi
    if [[ ! -s $out ]]; then
      rm -f -- "$out"
    fi
  done
  return 0
}
