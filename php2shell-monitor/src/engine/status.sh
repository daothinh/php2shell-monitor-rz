#!/usr/bin/env bash
# status.sh - project/device overview: supervisor state, plugins, rules, last batches.
set -u
WORKDIR=${WORKDIR:-/opt/php2shell-monitor}
source "$WORKDIR/lib/common.sh"
source "$WORKDIR/lib/paths.sh"
p2s_device_init || exit 1

pid=$(cat "$P2S_DEVICE_RUN_DIR/supervisor.pid" 2>/dev/null || echo 0)
if [[ $pid != 0 ]] && kill -0 "$pid" 2>/dev/null; then
  echo "supervisor: running (pid $pid)"
else
  echo "supervisor: NOT running"
fi
echo "project:    $PROJECT"
echo "device:     $DEVICE"
echo "data dir:   $P2S_DATA_DIR"
echo "batch:      every ${BATCH_INTERVAL:-300}s"
if [[ -r $WORKDIR/conf/central.conf ]]; then
  # shellcheck disable=SC1090
  source "$WORKDIR/conf/central.conf"
  echo "central:    paired -> $SERVER_URL (project: ${PROJECT_NAME:-$PROJECT})"
  apid=$(cat "$P2S_DEVICE_RUN_DIR/agent/agent.pid" 2>/dev/null || echo 0)
  if [[ $apid =~ ^[0-9]+$ ]] && kill -0 "$apid" 2>/dev/null; then
    echo "agent:      running (pid $apid)"
  else
    echo "agent:      NOT running (bật khi chạy '-- run')"
  fi
else
  echo "central:    not paired (sudo bash php2shell-monitor.sh -- pair --server <url>)"
fi
echo ""

echo "== catchup (quét bù sau khi cài) =="
# catchup.status do engine/catchup.sh ghi: "<utc> TAB <state> TAB <chi tiết>".
# Quét bù chạy nền nên không còn chặn lệnh cài — đây là chỗ DUY NHẤT operator
# biết lượt quét log cũ đã xong hay chưa và có phát hiện gì.
if [[ -r $P2S_DEVICE_RUN_DIR/catchup.status ]]; then
  IFS=$'\t' read -r _c_ts _c_state _c_detail <"$P2S_DEVICE_RUN_DIR/catchup.status" || true
  case ${_c_state:-} in
    complete)
      case ${_c_detail:-} in
        *retro=hits*)    _c_retro='có dấu vết trong log cũ (đã tạo alert)' ;;
        *retro=no-hits*) _c_retro='không có dấu vết trong log cũ' ;;
        *retro=timeout*) _c_retro='bỏ qua — log cũ quá lớn' ;;
        *)               _c_retro='không đọc được log cũ' ;;
      esac
      printf 'xong lúc %s — %s\n' "${_c_ts:-?}" "$_c_retro"
      ;;
    running)
      case ${_c_detail:-} in
        first-scan) printf 'đang chạy: lượt quét đầu tiên trên log hiện có\n' ;;
        *)          printf 'đang chạy: %s\n' "${_c_detail:-retro-hunt}" ;;
      esac
      ;;
    *)
      printf '%s (%s)\n' "${_c_state:-không rõ}" "${_c_detail:-}"
      ;;
  esac
  unset _c_ts _c_state _c_detail _c_retro
elif [[ -s $P2S_DEVICE_RUN_DIR/catchup.log ]]; then
  echo "đang chạy (chưa có trạng thái) — nhật ký: catchup.log"
else
  echo "chưa chạy"
fi

echo ""
echo "== plugins (last batch) =="
if [[ -f $P2S_DEVICE_RUN_DIR/plugin_status.tsv ]]; then
  tail -20 "$P2S_DEVICE_RUN_DIR/plugin_status.tsv" | column -t -s $'\t' 2>/dev/null ||
    tail -20 "$P2S_DEVICE_RUN_DIR/plugin_status.tsv"
else
  echo "no batch has run yet"
fi

echo ""
echo "== health (nguồn đang bị mù?) =="
# Bộ đếm do lib/health.sh ghi: "<khoá> <strikes> <since> <detail>".
# "!" ở đầu detail = đã sinh cảnh báo P2S-090 cho chuỗi lỗi này.
# Không có file = mọi nguồn đọc được, không có gì phải nói.
_hf=$P2S_STATE_DIR/health.tsv
if [[ -s $_hf ]]; then
  awk -F'\t' -v th="${P2S_HEALTH_STRIKES:-3}" '{
      d = $4; warned = (d ~ /^!/) ? "da bao" : "chua bao"
      sub(/^!/, "", d)
      printf "  %-46s %2d/%s batch  %-10s %s\n", $1, $2, th, warned, d
    }' "$_hf" 2>/dev/null
else
  echo "  (không có nguồn nào lỗi)"
fi
_he=$P2S_STATE_DIR/health.events
if [[ -s $_he ]]; then
  echo "  sự kiện chưa gửi:"
  tail -3 "$_he" | awk -F'\t' '{ printf "    %s  %s — %s\n", $1, $2, $3 }'
fi

echo ""
echo "== capabilities =="
if [[ -f $P2S_STATE_DIR/capabilities.txt ]]; then
  tr '\n' ' ' <"$P2S_STATE_DIR/capabilities.txt"; echo ""
else
  echo "run -- discover first"
fi

echo ""
echo "== last 5 batches =="
tail -5 "$P2S_DEVICE_RUN_DIR/batches.log" 2>/dev/null || echo "(none)"

echo ""
echo "== last alert =="
if [[ -s $P2S_ALERT_DIR/queue.jsonl ]]; then
  if [[ -n ${P2S_JQ:-} ]]; then
    "$P2S_JQ" -r '[.ts_utc,.severity,(.hits|tostring),(.rules|map(.rule_id)|join(",")),.evidence_file] | @tsv' \
      <(tail -1 "$P2S_ALERT_DIR/queue.jsonl")
  else
    tail -1 "$P2S_ALERT_DIR/queue.jsonl"
  fi
else
  echo "(none)"
fi
