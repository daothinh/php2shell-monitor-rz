#!/usr/bin/env bash
# container_accesslog.sh - access log của nginx/apache BÊN TRONG container.
# Read-only, offset-tracked, không cần docker CLI/socket.
#
# VÌ SAO PLUGIN NÀY TỒN TẠI
# docker_logs.sh đọc json log (stdout/stderr) của container. Với image PHP-FPM
# thì đó KHÔNG phải access log thật: FPM ghi theo access.format không có %Q%q,
# nên query string biến mất:
#
#   json log   : 127.0.0.1 -  26/Oct/2026:07:47:47 +0000 "GET /vuln.php" 200
#   access.log : 192.168.0.1 - - [26/Oct/2026:07:47:15 +0000] "GET /vuln.php?page=/var/lib/php/sessions/sess_p2s7d73... HTTP/1.1" 200 410
#
# Toàn bộ CVE-2026-109619/109618 nằm trong query string (?page=..., upload
# progress), nên chỉ đọc json log là mù hoàn toàn. Đo trên lab: json log 0 dòng
# chứa 'page=', access.log 635.840 dòng. Đó chính là lý do "container đang bị
# RCE liên tục mà không có alert nào".
#
# Đường dẫn host tới file trong container lấy qua /proc/<pid>/root (xem
# lib/container.sh) — độc lập storage driver, không cần mount lại.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/_batch_common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/container.sh"

plugin_name=container_accesslog
export plugin_name

# Đường dẫn access log bên trong container, theo thứ tự ưu tiên. Debian/nginx
# chính thức: /var/log/nginx/access.log. Apache httpd: /var/log/apache2/ hoặc
# /var/log/httpd/. Alpine/nginx: /var/log/nginx/. Mỗi mục là một GLOB để bắt
# cả access.log.1 sau rotation.
CONTAINER_ACCESS_GLOBS=(
  'var/log/nginx/access.log'
  'var/log/nginx/*access*.log'
  'var/log/apache2/*access*.log'
  'var/log/httpd/*access*.log'
  'var/log/nginx/access.log.*'
)

# Trần kích thước đọc cho MỘT lượt của MỘT file. Lượt quét đầu trên container
# đã chạy lâu có thể gặp file 100+ MB; đọc hết một lần thì plugin vượt
# PLUGIN_TIMEOUT và batch sau lại đọc lại từ đầu. Cắt theo trần, các batch sau
# đọc tiếp phần còn lại — không mất dòng nào, chỉ trải ra nhiều batch.
CONTAINER_READ_CAP_BYTES=${CONTAINER_READ_CAP_BYTES:-16777216}

# parse_container_access <hostpath> <cid> <name> <rel>
# Như parse_access_file nhưng: (a) giới hạn byte mỗi lượt, (b) tên file hiển
# thị là container:<tên> thay vì đường dẫn /proc/<pid>/root dài dằng dặc.
#
# KHOÁ OFFSET: dùng "<cid>:<rel>" chứ KHÔNG dùng đường dẫn /proc/<pid>/root.
# Container restart thì PID đổi, đường dẫn /proc cũ biến mất, offset theo
# đường dẫn sẽ trỏ vào key không bao giờ gặp lại -> đọc lại từ byte 0 sau mỗi
# lần restart. CID thì ổn định suốt vòng đời container, và <rel> ổn định trong
# container, nên cặp đó là khoá đúng. Inode vẫn được lưu để phát hiện log
# rotation/truncation bên trong container.
parse_container_access() {
  local file=$1 cid=$2 name=$3 rel=$4
  [[ -f $file && -r $file ]] || return 0
  local key="container:$cid/$rel"
  local ino size pos line_no
  ino=$(stat -c '%i' -- "$file") || return 0
  size=$(stat -c '%s' -- "$file") || return 0
  IFS=$'\t' read -r pos line_no <<<"$(state_offset_get "$key" "$ino")"
  (( pos <= size )) || { pos=0; line_no=0; }
  (( size > pos )) || return 0

  local avail=$((size - pos))
  local want=$avail
  (( want > CONTAINER_READ_CAP_BYTES )) && want=$CONTAINER_READ_CAP_BYTES

  local chunk="$P2S_TMP_DIR/cacc.chunk.$$"
  tail -c +"$((pos + 1))" -- "$file" 2>/dev/null | head -c "$want" >"$chunk"
  # Dòng cuối có thể bị cắt giữa chừng vì trần byte: bỏ nó lại cho batch sau.
  local newpos
  if [[ $(tail -c1 -- "$chunk" 2>/dev/null | wc -l) -eq 0 ]]; then
    local complete_bytes
    complete_bytes=$(p2s_complete_bytes "$chunk")
    [[ -z $complete_bytes || $complete_bytes -le 0 ]] && complete_bytes=0
    if (( complete_bytes > 0 )); then
      head -c "$complete_bytes" -- "$chunk" >"$chunk.full"
      mv -f -- "$chunk.full" "$chunk"
    else
      : >"$chunk"
    fi
    newpos=$((pos + complete_bytes))
  else
    newpos=$((pos + want))
  fi

  local emitted=0 read_lines=0
  if [[ -s $chunk ]]; then
    # realfile: alert phải chỉ được container nào, không phải đường dẫn
    # /proc/<pid>/root/var/log/nginx/access.log.
    awk -f "$P2S_SRC_DIR/lib/accesslog.awk" -v src=access_log \
        -v realfile="container:$name:${cid:0:12}" -v startline="$line_no" "$chunk" | tee "$chunk.out"
    emitted=$(wc -l <"$chunk.out")
    read_lines=$(LC_ALL=C awk 'END { print NR }' "$chunk" 2>/dev/null)
    [[ -n $read_lines ]] || read_lines=$emitted
  fi
  rm -f -- "$chunk" "$chunk.out"

  state_offset_set "$key" "$ino" "$newpos" "$((line_no + read_lines))"
  return 0
}

# Đếm số container đã quét để log lại khi không có gì (dễ chẩn đoán).
while IFS=$'\t' read -r _short name _pid rootfs cid; do
  [[ -n $cid ]] || continue
  [[ -n $rootfs ]] || continue
  # GLOB mở rộng trong rootfs của container. nullglob để pattern không khớp
  # không tạo ra chuỗi rác.
  shopt -s nullglob
  for rel in "${CONTAINER_ACCESS_GLOBS[@]}"; do
    for f in "$rootfs"/$rel; do
      [[ -f $f && -r $f ]] || continue
      # rel chuẩn hoá: bỏ tiền tố rootfs để làm khoá offset ổn định
      relpath=${f#"$rootfs"/}
      parse_container_access "$f" "$cid" "$name" "$relpath"
    done
  done
  shopt -u nullglob
done < <(p2s_containers)

exit 0
