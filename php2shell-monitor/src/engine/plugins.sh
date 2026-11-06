#!/usr/bin/env bash
# plugins.sh - run every plugin and collect its stream records.
# A failing plugin never aborts the batch; it is logged and skipped.
set -u
WORKDIR=${WORKDIR:-/opt/php2shell-monitor}
source "$WORKDIR/lib/common.sh"
source "$WORKDIR/lib/paths.sh"
source "$WORKDIR/lib/health.sh"
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
    # rc=124/137 = bị PLUGIN_TIMEOUT cắt. Đây là thất bại IM LẶNG điển hình:
    # plugin chết giữa chừng, các nguồn xếp sau nó trong cùng file không bao giờ
    # được đọc, và "không có alert" trông giống hệt "yên bình". Ghi health note
    # để P2S-090 nói ra sau P2S_HEALTH_STRIKES batch.
    case $rc in
      124|137) p2s_health_note "plugin/$name" degraded "plugin bi cat boi PLUGIN_TIMEOUT (${PLUGIN_TIMEOUT}s)" ;;
      1)       p2s_health_note "plugin/$name" degraded "plugin loi rc=1 (xem run/plugins.err)" ;;
      *)       p2s_health_note "plugin/$name" ok ;;
    esac
  else
    printf 'plugin\t%s\tok\t%s\n' "$name" "$(utc_now)" >>"$P2S_DEVICE_RUN_DIR/plugin_status.tsv"
    p2s_health_note "plugin/$name" ok
  fi
  [[ -s $out ]] && cat -- "$out"
  rm -f -- "$out"
done
exit 0
