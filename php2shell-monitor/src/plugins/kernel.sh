#!/usr/bin/env bash
# kernel.sh - kernel segfault/OOM via journald or rsyslog files.
# Prefilter is deliberately broad: the rule pack decides severity and id.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/_batch_common.sh"

plugin_name=kernel
export plugin_name
KERNEL_RE='segfault at|Out of memory|Killed process|exited on signal|signal 11'

# Journal ưu tiên vì nó trả lời theo cửa sổ thời gian (--since), không phải theo
# offset byte: journald tự xoay vòng file, đọc bằng offset là đọc một định dạng
# nhị phân có khoá — sai hoàn toàn.
#
# NHƯNG journal KHÔNG được phép làm monitor MÙ khi nó im lặng. Trước đây:
#   if have journalctl && [[ -d /var/log/journal ]]; then ...; exit 0; fi
# nghĩa là chỉ cần thư mục tồn tại là 3 file text bị bỏ qua VĨNH VIỄN — kể cả
# khi journald chết, journal bị xoá, hoặc quyền đọc bị thu hồi. Chuyển sang
# file text là một SỰ KIỆN đáng điều tra, nên nó phải nhìn thấy được.
have_journal=0
if have journalctl && [[ -d /var/log/journal ]]; then
  if ! journalctl -k -n 1 --no-pager >/dev/null 2>&1; then
    # Có thư mục nhưng KHÔNG đọc được: hạ cấp và báo, không im lặng bỏ qua.
    p2s_health_note kernel degraded \
      "journalctl -k khong doc duoc (quyen/xoay vong?) — chuyen sang file text"
    echo "kernel: journalctl -k không đọc được — chuyển sang file text" >&2
  else
    have_journal=1
    p2s_health_note kernel ok
  fi
fi

# Đường dẫn TUYỆT ĐỐI tới file journal đang được đọc.
#
# Trước đây field `file` của record kernel là chuỗi "journalctl -k". Đó không
# phải đường dẫn: người trực ca nhận alert không biết mở file nào để tra, và
# không phân biệt được alert của máy nào khi cùng một dự án có nhiều thiết bị.
# journald lưu kernel/system log trong
#   /var/log/journal/<machine-id>/system.journal      (persistent)
#   /run/log/journal/<machine-id>/system.journal      (volatile, mất khi reboot)
# nên phải dò đúng file và chỉ dùng khi Thật sự đọc được (journalctl --file).
journal_file() {
  local f d
  for d in /var/log/journal /run/log/journal; do
    [[ -d $d ]] || continue
    for f in "$d"/*/system.journal "$d"/*/system@*.journal; do
      [[ -f $f && -r $f ]] || continue
      # xác nhận journalctl đọc được chính file này, không chỉ suy từ đường dẫn
      if journalctl --file "$f" -k -n 1 --no-pager >/dev/null 2>&1; then
        printf '%s' "$f"
        return 0
      fi
    done
  done
  return 1
}

if (( have_journal )); then
  if ! jfile=$(journal_file); then
    p2s_health_note kernel degraded "khong tim duoc file journal doc duoc"
    jfile=''
  fi
  last=$(state_last_batch)
  if (( last > 0 )); then
    since=$(epoch_to_utc "$last")
  else
    since="-30min"
  fi
  n=0
  journalctl -k --since "$since" --output=short-iso --no-pager 2>/dev/null |
  while IFS= read -r line; do
    n=$((n + 1))
    printf '%s' "$line" | grep -qP "$KERNEL_RE" || continue
    ts=$(t_extract_journal_ts "$line" || utc_now)
    P2S_TS=$ts; export P2S_TS
    # `file` = đường dẫn tuyệt đối thật; rỗng thì để trống chứ KHÔNG bịa tên.
    emit_record kernel "${jfile:-}" "$n" "" "" "" "" "" "" "$line" "-"
  done
  exit 0
fi

# Nhánh file text: batch_read có trần byte + trần thời gian cho từng file
# (lib/readcap.sh). /var/log/syslog trên host chạy lâu có thể 269 MB; đọc từ
# byte 0 là vượt mọi trần, nên lần đầu tiên nó nhảy tới EOF - trần và đọc phần
# mới nhất, phần lịch sử để retro_hunt (có cửa sổ thời gian riêng).
for f in ${KERNEL_LOGS:-} /var/log/kern.log /var/log/messages /var/log/syslog; do
  [[ -z $f ]] && continue
  [[ -f $f && -r $f ]] || continue
  batch_read "$f" parse_kernel_line
done
