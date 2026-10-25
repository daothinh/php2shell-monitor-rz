#!/usr/bin/env bash
# plugins.sh - run every plugin and collect its stream records.
# A failing plugin never aborts the batch; it is logged and skipped.
set -u
WORKDIR=${WORKDIR:-/opt/php2shell-monitor}
source "$WORKDIR/lib/common.sh"
source "$WORKDIR/lib/paths.sh"
p2s_device_init || exit 1

# Plugin subshells inherit config through the environment.
if [[ -f $WORKDIR/conf/default.conf ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$WORKDIR/conf/default.conf"
  set +a
fi
PLUGIN_TIMEOUT=${PLUGIN_TIMEOUT:-120}
export PLUGIN_TIMEOUT

for p in "$P2S_PLUGIN_DIR"/*.sh; do
  [[ -e $p ]] || continue
  name=$(basename "$p" .sh)
  [[ $name == _* ]] && continue
  if [[ " ${P2S_PLUGINS_DISABLED:-} " == *" $name "* ]]; then
    printf 'plugin\t%s\tdisabled\t%s\n' "$name" "$(utc_now)" >>"$P2S_DEVICE_RUN_DIR/plugin_status.tsv"
    continue
  fi
  out=$P2S_TMP_DIR/plugin.$name.$$.tsv
  timeout "$PLUGIN_TIMEOUT" bash "$p" >"$out" 2>>"$P2S_DEVICE_RUN_DIR/plugins.err"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    printf 'plugin\t%s\trc=%s\t%s\n' "$name" "$rc" "$(utc_now)" >>"$P2S_DEVICE_RUN_DIR/plugin_status.tsv"
  else
    printf 'plugin\t%s\tok\t%s\n' "$name" "$(utc_now)" >>"$P2S_DEVICE_RUN_DIR/plugin_status.tsv"
  fi
  [[ -s $out ]] && cat -- "$out"
  rm -f -- "$out"
done
exit 0
