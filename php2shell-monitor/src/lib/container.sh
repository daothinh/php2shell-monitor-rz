#!/usr/bin/env bash
# container.sh - phát hiện container Docker đang chạy và đường dẫn host tới
# filesystem của nó. Read-only, không cần docker CLI/socket.
#
# VÌ SAO CẦN FILE NÀY
# Một install php2shell-monitor trên host phải monitor cả host LẪN các container
# chạy trên host đó. Nhưng log/webroot của container KHÔNG nằm ở đường dẫn host
# thông thường:
#
#   - nginx trong container ghi access log vào /var/log/nginx/access.log BÊN
#     TRONG container (không ra stdout) — host không có /var/log/nginx đó;
#   - webroot nằm ở /var/www/html BÊN TRONG container — host không có.
#
# Đọc docker json log (stdout/stderr) là KHÔNG ĐỦ: PHP-FPM ghi access log theo
# access.format không có %Q%q nên query string mất sạch. Thực đo trên lab:
#   json log   : 0 dòng chứa 'page='
#   access.log : 635.840 dòng chứa 'page='
# Toàn bộ CVE-2026-109619 nằm trong query string (?page=/var/lib/php/sessions/
# sess_...), nên đọc json log thì không bao giờ thấy tấn công.
#
# CÁCH ĐI QUA ĐƯỢC
# Mỗi container có PID của process chính trong config.v2.json (State.Pid).
# /proc/<pid>/root trỏ vào root filesystem của container, đọc được từ host khi
# có root — độc lập storage driver (overlay2, overlayfs, btrfs, zfs, vfs...).
# Đã kiểm: inode qua /proc/<pid>/root trùng khớp với qua overlayfs mount, nên
# offset tracking theo inode vẫn đúng.
[[ -n ${P2S_CONTAINER_SH:-} ]] && return 0
P2S_CONTAINER_SH=1

P2S_DOCKER_DIR=${P2S_DOCKER_DIR:-/var/lib/docker}
P2S_CONTAINER_DIR=${P2S_CONTAINER_DIR:-$P2S_DOCKER_DIR/containers}

# P2S_CONTAINER_ROOTFS_MAP — file ánh xạ thay cho việc đọc /proc/<pid>/root.
# Mỗi dòng: <cid>\t<name>\t<rootfs>
# Dùng khi /proc bị chặn (container PID namespace, hardening, hidepid=2) hoặc
# khi muốn quét một bản snapshot/backup rootfs offline thay vì container đang
# chạy. Không có file này thì dò qua config.v2.json + /proc như bình thường.
P2S_CONTAINER_ROOTFS_MAP=${P2S_CONTAINER_ROOTFS_MAP:-}

# p2s_containers — in mỗi container đang chạy một dòng TSV:
#   <short_id>\t<name>\t<pid>\t<rootfs>\t<cid>
# rootfs = /proc/<pid>/root khi process còn sống; rỗng nếu không đọc được.
p2s_containers() {
  # Ánh xạ thủ công (snapshot offline / host chặn /proc) thay cho dò tự động.
  if [[ -n $P2S_CONTAINER_ROOTFS_MAP && -r $P2S_CONTAINER_ROOTFS_MAP ]]; then
    local mn mr mid
    while IFS=$'\t' read -r mid mn mr; do
      [[ -n $mid ]] || continue
      [[ $mid == '#'* ]] && continue
      printf '%s\t%s\t%s\t%s\t%s\n' "${mid:0:12}" "${mn:-${mid:0:12}}" 0 "$mr" "$mid"
    done <"$P2S_CONTAINER_ROOTFS_MAP"
    return 0
  fi
  [[ -d $P2S_CONTAINER_DIR && -r $P2S_CONTAINER_DIR ]] || return 0
  local d cid cfg line short name pid running rootfs
  for d in "$P2S_CONTAINER_DIR"/*/; do
    [[ -d $d ]] || continue
    cid=$(basename "$d")
    cfg="$d/config.v2.json"
    [[ -r $cfg ]] || continue
    # awk một lượt: config.v2.json có thể tới vài chục KB, không cần jq
    # (jq là tuỳ chọn trong tool này, xem lib/deps.sh). Trả 3 field thô để bash
    # kiểm tra rootfs — không gọi system() trong awk, tránh fork mỗi container.
    line=$(awk '
      # grab <key> -> giá trị của "key":..., bóc cả string lẫn số/bool
      function grab(key,   i, rest, s) {
        i = index($0, "\"" key "\":")
        if (i == 0) return ""
        rest = substr($0, i + length(key) + 3)
        if (substr(rest, 1, 1) == "\"") {
          rest = substr(rest, 2)
          s = index(rest, "\"")
          return s ? substr(rest, 1, s - 1) : ""
        }
        match(rest, /^[A-Za-z0-9]+/)
        return substr(rest, 1, RLENGTH)
      }
      {
        n = grab("Name"); p = grab("Pid"); r = grab("Running")
        sub(/^\//, "", n)
        printf "%s\t%s\t%s\n", n, p, r
        exit
      }
    ' "$cfg" 2>/dev/null)
    [[ -n $line ]] || continue
    IFS=$'\t' read -r name pid running <<<"$line"
    # Chỉ container đang chạy mới có filesystem truy cập được.
    [[ $running == true ]] || continue
    [[ -n $pid && $pid != 0 ]] || continue
    rootfs="/proc/$pid/root"
    [[ -d $rootfs ]] || rootfs=''
    short=${cid:0:12}
    [[ -n $name ]] || name=$short
    printf '%s\t%s\t%s\t%s\t%s\n' "$short" "$name" "$pid" "$rootfs" "$cid"
  done
}

# p2s_container_logpath <cid> — đường dẫn docker json log của container.
p2s_container_logpath() {
  local cid=$1
  printf '%s/%s/%s-json.log' "$P2S_CONTAINER_DIR" "$cid" "$cid"
}

# p2s_container_paths <rootfs> <relpath> — in các đường dẫn host ứng viên cho
# một đường dẫn tương đối trong container. Chỉ in cái tồn tại và đọc được.
# Ưu tiên /proc/<pid>/root (mọi storage driver); thử thêm overlayfs mount và
# overlay2 merged làm dự phòng cho môi trường lạ.
p2s_container_paths() {
  local rootfs=$1 rel=$2 p
  local -a cand=()
  [[ -n $rootfs ]] && cand+=("$rootfs/$rel")
  # overlayfs (driver mới của Docker 24+): rootfs mount theo container id
  cand+=("$P2S_DOCKER_DIR/rootfs/overlayfs/$P2S_CUR_CID/$rel")
  # overlay2 (driver cũ): /var/lib/docker/overlay2/<id>/merged
  cand+=("$P2S_DOCKER_DIR/overlay2/$P2S_CUR_CID/merged/$rel")
  for p in "${cand[@]}"; do
    [[ -n $p ]] || continue
    [[ -e $p && -r $p ]] && printf '%s\n' "$p"
  done
  return 0
}

# p2s_container_relpaths <rootfs> <relpath> — như trên nhưng trả về TẤT CẢ
# đường dẫn ứng viên (dùng cho find -L theo nhiều gốc).
p2s_container_webroots() {
  local rootfs=$1 p
  for p in /var/www/html /usr/share/nginx/html /var/www; do
    p2s_container_paths "$rootfs" "${p#/}"
  done
}

# p2s_container_display <path>
# Đổi đường dẫn host-tới-container thành dạng đọc được trong alert:
#   /proc/1087326/root/var/www/html/s.php  ->  container:php2shell-lab-1:/var/www/html/s.php
# Đường dẫn host thường giữ nguyên. Alert phải chỉ đúng container VÀ đúng
# đường dẫn bên trong nó; /proc/<pid>/root vừa dài vừa đổi theo mỗi lần
# restart nên không dùng làm định danh được.
p2s_container_display() {
  local p=$1 short name pid rootfs cid rel
  while IFS=$'\t' read -r short name pid rootfs cid; do
    [[ -n $rootfs ]] || continue
    if [[ $p == "$rootfs"/* ]]; then
      rel=${p#"$rootfs"}
      printf 'container:%s:%s' "$name" "$rel"
      return 0
    fi
  done < <(p2s_containers)
  printf '%s' "$p"
  return 0
}

# p2s_container_manifest_key <path>
# Khoá manifest/offset ổn định qua restart container. Cùng lý do với offset:
# khoá theo (cid, relpath) chứ không theo /proc/<pid>/root.
p2s_container_manifest_key() {
  local p=$1 short name pid rootfs cid rel
  while IFS=$'\t' read -r short name pid rootfs cid; do
    [[ -n $rootfs ]] || continue
    if [[ $p == "$rootfs"/* ]]; then
      rel=${p#"$rootfs"}
      printf 'container:%s:%s' "$cid" "$rel"
      return 0
    fi
  done < <(p2s_containers)
  printf '%s' "$p"
  return 0
}
