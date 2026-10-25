#!/usr/bin/env bash
# deps.sh - tự cài jq khi host chưa có, theo kiểu "best effort".
#
# Nguyên tắc:
#   * jq là TUỲ CHỌN, không phải bắt buộc. Rule pack đọc bằng lib/jsonl.awk nên
#     monitor vẫn phát hiện bình thường khi không có jq. jq chỉ làm phần phụ
#     (hiển thị status, lấy src_ip từ Suricata eve.json) đẹp hơn.
#   * Vì vậy hàm ở đây KHÔNG BAO GIỜ làm hỏng lượt chạy: cài được thì tốt,
#     không cài được thì thôi và ghi lại một dòng để người vận hành biết.
#   * Chỉ dùng package manager CÓ SẴN trên máy. Không tải binary từ Internet,
#     không thêm repo, không dùng curl|bash, không snap/flatpak/npm.
#   * Ưu tiên apt (ổn định nhất trên Debian/Ubuntu — nhóm host phổ biến nhất).
#     Fallback: dnf, yum, apk, zypper, pacman.
set -u

[[ -n ${P2S_DEPS_SH:-} ]] && return 0
P2S_DEPS_SH=1

# p2s_have_jq — jq (hoặc jaq) đã dùng được chưa.
p2s_have_jq() {
  [[ -n ${P2S_JQ:-} ]] && return 0
  command -v jq >/dev/null 2>&1 && return 0
  command -v jaq >/dev/null 2>&1 && return 0
  return 1
}

# _p2s_pm — in ra package manager sẽ dùng, hoặc rỗng nếu không nhận diện được.
_p2s_pm() {
  local pm
  for pm in apt-get dnf yum apk zypper pacman; do
    command -v "$pm" >/dev/null 2>&1 && { printf '%s' "$pm"; return 0; }
  done
  return 1
}

# _p2s_install_jq <pm> — một lượt cài, không tương tác, có timeout.
# Trả 0 nếu lệnh cài chạy xong (chưa chắc jq đã có — kiểm lại sau).
_p2s_install_jq() {
  local pm=$1
  local -a cmd
  case $pm in
    apt-get)
      # DEBIAN_FRONTEND: không hỏi gì. -o ...: không cần tty, không kéo recommends.
      # `apt-get update` chỉ chạy khi chưa có cache — tránh mạng chậm mỗi lần.
      if [[ ! -d /var/lib/apt/lists ]] || [[ -z $(ls -A /var/lib/apt/lists 2>/dev/null) ]]; then
        DEBIAN_FRONTEND=noninteractive timeout 180 apt-get update -qq >/dev/null 2>&1 || true
      fi
      cmd=(apt-get install -y -qq -o Dpkg::Options::=--force-confold
           -o Dpkg::Options::=--force-confdef jq)
      ;;
    dnf)    cmd=(dnf install -y -q jq) ;;
    yum)    cmd=(yum install -y -q jq) ;;
    apk)    cmd=(apk add --no-cache jq) ;;
    zypper) cmd=(zypper --non-interactive --quiet install jq) ;;
    pacman) cmd=(pacman -S --noconfirm --needed jq) ;;
    *)      return 1 ;;
  esac
  DEBIAN_FRONTEND=noninteractive timeout 300 "${cmd[@]}" >/dev/null 2>&1
}

# p2s_ensure_jq [--quiet]
# Cài jq nếu thiếu. Không bao giờ exit non-zero vì lý do cài đặt: người gọi
# không phải xử lý lỗi. Trả 0 = có jq, 1 = không có (vẫn chạy tiếp được).
p2s_ensure_jq() {
  local quiet=${1:-}

  if p2s_have_jq; then
    # làm mới P2S_JQ nếu nó vừa xuất hiện trong PATH
    [[ -z ${P2S_JQ:-} ]] && {
      if command -v jq >/dev/null 2>&1; then P2S_JQ=$(command -v jq)
      elif command -v jaq >/dev/null 2>&1; then P2S_JQ=$(command -v jaq); fi
      export P2S_JQ
    }
    return 0
  fi

  # Không phải root thì không cài được; đừng thử rồi treo ở prompt sudo.
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    [[ $quiet == --quiet ]] || printf 'php2shell-monitor: chưa có jq và không phải root — bỏ qua (không bắt buộc)\n' >&2
    return 1
  fi

  local pm
  if ! pm=$(_p2s_pm); then
    [[ $quiet == --quiet ]] || printf 'php2shell-monitor: chưa có jq, không nhận diện được package manager — bỏ qua (không bắt buộc)\n' >&2
    return 1
  fi

  [[ $quiet == --quiet ]] || printf '⏳ Chưa có jq — đang cài bằng %s (không bắt buộc, chỉ để hiển thị đẹp hơn)...\n' "$pm"

  _p2s_install_jq "$pm" || true

  if command -v jq >/dev/null 2>&1; then
    P2S_JQ=$(command -v jq)
    export P2S_JQ
    [[ $quiet == --quiet ]] || printf '✅ Đã cài jq: %s\n' "$P2S_JQ"
    return 0
  fi

  [[ $quiet == --quiet ]] || printf 'ℹ️  Không cài được jq (không sao — monitor vẫn phát hiện bình thường).\n' >&2
  return 1
}
