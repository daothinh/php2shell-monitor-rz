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
#
# HAI LỚP CHỐNG TREO (bản 1.4.12)
# 1. nginx official image để /var/log/nginx/access.log là SYMLINK tới
#    /dev/stdout. Đọc từ host, đích tuyệt đối /dev/stdout được giải theo
#    namespace của HOST, tức /proc/<pid-của-chính-plugin>/fd/1; plugins.sh lại
#    redirect stdout của plugin vào một file, nên `-f` ĐÚNG và `tail` đọc chính
#    file đang được plugin ghi ra -> file tự dài ra trong lúc đọc -> không bao
#    giờ tới EOF. Đo trên lab: rc=124 mỗi batch, 0 dòng, và vì vòng lặp đứng ở
#    container ĐẦU TIÊN nên access log thật của DVWA không bao giờ được đọc.
#    Xử lý: phân loại bằng readlink TRƯỚC (p2s_file_kind); `stdout` thì bỏ qua
#    ở đây và để docker_logs đọc /var/lib/docker/containers/<cid>/<cid>-json.log
#    — đó mới là nội dung thật của stdout. Không im lặng: ghi health note.
# 2. Mỗi file có trần byte và trần thời gian riêng (lib/readcap.sh); hết hạn
#    thì giữ phần đã đọc, lưu cursor, đi tiếp container kế tiếp.
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
CONTAINER_READ_CAP_BYTES=${CONTAINER_READ_CAP_BYTES:-16777216}

# parse_container_access <hostpath> <cid> <name> <rel>
# Như parse_access_file nhưng: (a) giới hạn byte mỗi lượt, (b) tên file hiển
# thị là container:<tên> thay vì đường dẫn /proc/<pid>/root dài dằng dặc.
#
# KHOÁ OFFSET: dùng "<cid>/<rel>" chứ KHÔNG dùng đường dẫn /proc/<pid>/root.
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
  ino=$(stat -Lc '%i' -- "$file" 2>/dev/null) || return 0
  size=$(stat -Lc '%s' -- "$file" 2>/dev/null) || return 0
  IFS=$'\t' read -r pos line_no <<<"$(state_offset_get "$key" "$ino")"
  (( pos <= size )) || { pos=0; line_no=0; }
  (( size > pos )) || return 0

  local chunk="$P2S_TMP_DIR/cacc.chunk.$$"
  p2s_read_chunk "$file" "$pos" "$size" "$CONTAINER_READ_CAP_BYTES" \
    "${P2S_READ_TIMEOUT:-45}" "$chunk" || { rm -f -- "$chunk"; return 1; }
  local newpos=$((P2S_RD_BASE + P2S_TRIM_BYTES))
  if (( P2S_RD_TIMEOUT )); then
    echo "readcap: timeout đọc $name:$rel tại byte $newpos (${P2S_READ_TIMEOUT}s)" >&2
    p2s_health_note "container_accesslog/$cid/$rel" degraded \
      "timeout ${P2S_READ_TIMEOUT}s tai byte $newpos"
  else
    p2s_health_note "container_accesslog/$cid/$rel" ok
  fi

  local emitted=0 read_lines=0
  if [[ -s $chunk ]]; then
    # realfile: alert phải chỉ được container nào, không phải đường dẫn
    # /proc/<pid>/root/var/log/nginx/access.log.
    awk -f "$P2S_SRC_DIR/lib/accesslog.awk" -v src=access_log \
        -v realfile="container:$name:$abspath" -v startline="$line_no" "$chunk" \
      | tee "$chunk.out"
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
      # khoá offset: bỏ tiền tố rootfs (ổn định qua restart/đổi PID)
      relpath=${f#"$rootfs"/}
      # đường dẫn HIỂN THỊ phải tuyệt đối bên trong container: giữ dấu "/"
      abspath=/${relpath}
      case $(p2s_file_kind "$f") in
        regular)
          parse_container_access "$f" "$cid" "$name" "$relpath" || true
          ;;
        stdout)
          # access.log -> /dev/stdout (nginx:alpine, nginx:official). Nội dung
          # thật nằm ở json log; docker_logs đọc nó. Ghi nhận để người trực ca
          # biết nguồn này KHÔNG được đọc ở đây, thay vì im lặng.
          p2s_health_note "container_accesslog/$cid/$relpath" ok
          printf 'container_accesslog: %s:%s -> /dev/stdout, bỏ qua (docker_logs đọc json log)\n' \
            "$name" "$relpath" >&2
          ;;
        *)
          p2s_health_note "container_accesslog/$cid/$relpath" degraded \
            "không phải regular file ($(stat -Lc '%F' -- "$f" 2>/dev/null))"
          ;;
      esac
    done
  done
  shopt -u nullglob
done < <(p2s_containers)

exit 0
