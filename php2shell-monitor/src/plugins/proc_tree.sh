#!/usr/bin/env bash
# proc_tree.sh - /proc scan: web-worker parent spawning shells/interpreters.
# Root only. Emits one record per suspicious process, raw cmdline preserved.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/_batch_common.sh"

plugin_name=proc_tree
export plugin_name

PARENT_RE='(^|/)(php-fpm|php-cgi|lsphp|frankenphp|httpd|apache2)[0-9.]*$'
CHILD_RE='(^|/)(sh|bash|dash|zsh|busybox|python3?|perl|nc|ncat|socat|curl|wget)$'

proc_cmdline() {
  # 2>/dev/null phải đứng TRƯỚC "<". Plugin này quét MỌI pid trên host nên tỉ
  # lệ race cao nhất: process sinh/chết liên tục trong lúc quét, và mỗi PID
  # biến mất giữa chừng lại rò một dòng "No such file or directory" vào
  # scan.log. Shell mở input redirection trước khi áp stderr, nên thứ tự cũ
  # ("<file" rồi mới "2>/dev/null") không chặn được gì.
  tr '\0' ' ' 2>/dev/null <"/proc/$1/cmdline" | sed 's/ $//'
}

[[ ${PROC_SCAN:-1} == 1 ]] || exit 0
[[ $(id -u) -eq 0 ]] || exit 0

declare -A COMM=()
for pid_dir in /proc/[0-9]*; do
  p=${pid_dir##*/}
  COMM[$p]=$(cat "$pid_dir/comm" 2>/dev/null || true)
done

for p in "${!COMM[@]}"; do
  [[ -r /proc/$p/stat ]] || continue
  ppid=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null) || continue
  pname=${COMM[$ppid]:-}
  cname=${COMM[$p]:-}
  [[ -z $pname || -z $cname ]] && continue
  printf '%s' "$pname" | grep -Pq "$PARENT_RE" || continue
  printf '%s' "$cname" | grep -Pq "$CHILD_RE" || continue
  cmd=$(proc_cmdline "$p")
  P2S_TS=$(utc_now); export P2S_TS
  emit_record proc "/proc/$p/cmdline" 1 "" "" "" "" "" "$p" \
    "parent=$pname child=$cname cmd=$cmd" "-"
done
