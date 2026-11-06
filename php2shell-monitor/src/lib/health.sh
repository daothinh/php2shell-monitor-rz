#!/usr/bin/env bash
# health.sh - phát hiện THẤT BẠI IM LẶNG của chính monitor.
#
# VÌ SAO CẦN
# Sự cố container_accesslog tồn tại lâu không phải vì khó sửa, mà vì nó KHÔNG
# có tiếng nói: plugin trả rc=124 mỗi batch, alert vắng mặt, và "không có alert"
# là trạng thái bình thường của một hệ thống không bị tấn công. Không phân biệt
# được "yên" với "mù".
#
# Hai bộ đếm bền (state/health.tsv):
#   <khoá>  <số lần liên tiếp>  <utc lần đầu>  <chi tiết>
# khi số lần liên tiếp đạt ngưỡng, ghi một dòng vào state/health.events và
# batches.log. Từ 1.4.12 health.events được đẩy lên central qua chính kênh alert
# (source=health, rule P2S-090) để người trực ca thấy trên Telegram.
#
# Nguyên tắc: KHÔNG dùng chung file với offsets.tsv (giữ nguyên hợp đồng offset),
# mỗi khoá là một dòng nên nhiều plugin ghi song song vẫn an toàn.
[[ -n ${P2S_HEALTH_SH:-} ]] && return 0
P2S_HEALTH_SH=1

# Ngưỡng: 3 batch liên tiếp (~15 phút) mới báo — đủ để không kêu vì một lần
# đọc trượt, đủ sớm để không mất buổi trực.
P2S_HEALTH_STRIKES=${P2S_HEALTH_STRIKES:-3}

_health_file() { printf '%s/health.tsv' "$P2S_STATE_DIR"; }
_health_events() { printf '%s/health.events' "$P2S_STATE_DIR"; }

# p2s_health_get <key> -> "<strikes>\t<since>\t<detail>"
p2s_health_get() {
  local k=$1 f
  f=$(_health_file)
  [[ -r $f ]] || { printf '0\t\t'; return 0; }
  local row
  row=$(awk -F'\t' -v k="$k" '$1 == k { print; exit }' "$f" 2>/dev/null)
  [[ -n $row ]] || { printf '0\t\t'; return 0; }
  printf '%s' "${row#*$'\t'}"
}

# p2s_health_note <key> <ok|degraded> <detail>
#
# ok      -> xoá bộ đếm (hồi phục thì im lặng, không gửi tin "đã hết": dọn dẹp
#            không phải sự cố).
# degraded-> tăng strikes; tới ngưỡng thì ghi sự kiện đúng MỘT lần cho mỗi
#            chuỗi liên tiếp (đánh dấu bằng cột detail bắt đầu "!") để không
#            biến một nguồn hỏng thành tin nhắn mỗi 5 phút.
p2s_health_note() {
  local k=$1 state=$2 detail=${3:-} f tmp strikes since cur
  f=$(_health_file)
  [[ -d ${f%/*} ]] || return 0
  tmp="$f.tmp.$$"
  : >"$tmp" 2>/dev/null || return 0
  if [[ -r $f ]]; then
    awk -F'\t' -v OFS='\t' -v k="$k" '$1 != k' "$f" >"$tmp" 2>/dev/null || : >"$tmp"
  fi
  IFS=$'\t' read -r strikes since cur <<<"$(p2s_health_get "$k")"
  [[ $strikes =~ ^[0-9]+$ ]] || strikes=0
  if [[ $state == ok ]]; then
    rm -f -- "$tmp"
    return 0
  fi
  strikes=$((strikes + 1))
  [[ -n $since ]] || since=$(utc_now)
  local marked=0
  [[ $cur == '!'* ]] && marked=1
  if (( strikes >= P2S_HEALTH_STRIKES )) && (( ! marked )); then
    # batches.log: dạng TSV giống mọi dòng khác, thêm cột để grep được.
    printf '%s\t%s\t%s\t%s\t%s\n' "${BATCH_ID:-$(utc_now)}" "$PROJECT" "$DEVICE" \
      "degraded" "$k (${detail:-$k}); strikes=$strikes" \
      >>"$P2S_DEVICE_RUN_DIR/batches.log"
    printf '%s\t%s\t%s\t%s\n' "$(utc_now)" "$k" "${detail:-$k}" "$strikes" \
      >>"$(_health_events)"
    marked=1
  fi
  printf '%s\t%s\t%s\t%s\n' "$k" "$strikes" "$since" "$([[ $marked == 1 ]] && printf '!%s' "${detail:-$k}" || printf '%s' "${detail:-}")" >>"$tmp"
  mv -f -- "$tmp" "$f" 2>/dev/null
  return 0
}

# p2s_health_sweep [ngưỡng]
# Chuyển health.events thành record stream (source=health, field msg) để
# rule_match bắt bằng P2S-090 và alert đi lên Telegram như mọi hit khác.
# Gọi từ engine/scan.sh sau khi chạy plugins, trước rule_match.
# File sự kiện bị CẮT sau khi đọc: mỗi sự kiện chỉ báo một lần.
p2s_health_sweep() {
  local ev
  ev=$(_health_events)
  [[ -s $ev ]] || return 0
  local ts k detail strikes
  while IFS=$'\t' read -r ts k detail strikes; do
    [[ -n $k ]] || continue
    P2S_TS=${ts:-$(utc_now)}; export P2S_TS
    emit_record health "" 0 "" "" "" "" "" "" \
      "monitor degraded: $k — $detail (lien tiep ${strikes:-?} batch)" "-"
  done <"$ev"
  : >"$ev"
  return 0
}
