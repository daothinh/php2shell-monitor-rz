#!/usr/bin/env bash
# common.sh - constants and small helpers (safe to source twice)
[[ -n ${P2S_COMMON_SH:-} ]] && return 0
P2S_COMMON_SH=1

P2S_US=$'\x1f'
export P2S_US

P2S_PROG=${P2S_PROG:-php2shell-monitor}
P2S_VERSION=${P2S_VERSION:-dev}

# Runtime layout. Code lives in WORKDIR; data lives in
# WORKDIR/projects/<project>/devices/<device>/ (see lib/paths.sh).
WORKDIR=${WORKDIR:-/opt/php2shell-monitor}
P2S_SRC_DIR=${P2S_SRC_DIR:-$WORKDIR}
P2S_LIB_DIR=${P2S_LIB_DIR:-$P2S_SRC_DIR/lib}
P2S_PLUGIN_DIR=${P2S_PLUGIN_DIR:-$P2S_SRC_DIR/plugins}
P2S_RULE_DIR=${P2S_RULE_DIR:-$P2S_SRC_DIR/rules}
P2S_ENGINE_DIR=${P2S_ENGINE_DIR:-$P2S_SRC_DIR/engine}
P2S_CONF_DIR=${P2S_CONF_DIR:-$P2S_SRC_DIR/conf}
P2S_RUN_DIR=${P2S_RUN_DIR:-$WORKDIR/run}
P2S_TMP_DIR=${P2S_TMP_DIR:-$WORKDIR/tmp}
P2S_EXPORT_DIR=${P2S_EXPORT_DIR:-$WORKDIR/export}

# Device-scoped paths; lib/paths.sh overwrites these after reading conf.
P2S_STATE_DIR=${P2S_STATE_DIR:-$WORKDIR/state}
P2S_ALERT_DIR=${P2S_ALERT_DIR:-$WORKDIR/alerts}
P2S_EVIDENCE_DIR=${P2S_EVIDENCE_DIR:-$WORKDIR/evidence}

# P2S_JQ đặt sẵn (kể cả rỗng) là override của người vận hành: dùng để trỏ tới
# jaq ở đường dẫn khác, hoặc để giả lập "không có jq" trong test. Chỉ tự dò khi
# biến chưa được đặt.
if [[ ${P2S_JQ+x} ]]; then
  :
elif command -v jq >/dev/null 2>&1; then
  P2S_JQ=$(command -v jq)
elif command -v jaq >/dev/null 2>&1; then
  P2S_JQ=$(command -v jaq)
else
  P2S_JQ=""
fi
export P2S_JQ

have() { command -v "$1" >/dev/null 2>&1; }
is_root() { [[ ${EUID:-$(id -u)} -eq 0 ]]; }

# jq là TUỲ CHỌN. Rule pack đọc bằng lib/jsonl.awk nên monitor phát hiện bình
# thường khi không có jq; jq chỉ làm phần hiển thị (status, src_ip của Suricata)
# gọn hơn. Thiếu jq KHÔNG được chặn batch — chặn batch vì một tiện ích phụ là
# biến một monitor chạy được thành một monitor chết.
p2s_jq_ok() { [[ -n ${P2S_JQ:-} ]]; }

# p2s_want_jq — cài jq nếu thiếu (best effort), không bao giờ làm hỏng lượt chạy.
p2s_want_jq() {
  source "$(dirname "${BASH_SOURCE[0]}")/deps.sh"
  p2s_ensure_jq "${1:-}"
}

utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
utc_epoch() { date -u +%s; }

epoch_to_utc() {
  date -u -d "@${1:?epoch required}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo ""
}

iso_to_epoch() {
  local ts=${1:-}
  [[ -z $ts ]] && return 1
  date -d "$ts" +%s 2>/dev/null
}

# Strip tabs/newlines so a value can live inside the stream TSV.
sanitize_field() {
  local s=${1-}
  s=${s//$'\t'/ }
  s=${s//$'\n'/ }
  s=${s//$'\r'/ }
  printf '%s' "$s"
}

csv_has() {
  local IFS=,
  local x
  for x in $1; do [[ $x == "$2" ]] && return 0; done
  return 1
}

# LAN IP: source address of the default route, then first global IPv4, then
# `hostname -I`. Never loopback; never `hostname -i` (reverse DNS can block).
lan_ip() {
  local ip=''   # gán rỗng: local trần + set -u báo "unbound variable" (bash 5)
  if have ip; then
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)
    [[ -n $ip ]] || ip=$(ip -4 -o addr show scope global 2>/dev/null |
      awk '{ sub(/\/.*/, "", $4); if ($4 !~ /^127\./) { print $4; exit } }')
  fi
  [[ -n $ip ]] || ip=$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '/^[0-9]+\./ && !/^127\./ { print; exit }')
  [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || ip=""
  printf '%s' "$ip"
}

# OS + loại môi trường cho envelope alert: operator đọc tin Telegram thấy ngay
# máy bị nằm ở đâu (container hay bare-metal, distro gì), không phải tra thiết bị.
os_pretty() {
  local n=''
  [[ -r /etc/os-release ]] && \
    n=$(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' /etc/os-release | head -1)
  [[ -n $n ]] || n=$(uname -s 2>/dev/null || echo unknown)
  printf '%s' "$n"
}

env_label() {
  if [[ -f /.dockerenv ]] || grep -qa docker /proc/1/cgroup 2>/dev/null; then
    printf 'Docker Container'
  elif grep -qaE 'containerd|kubepods|lxc' /proc/1/cgroup 2>/dev/null \
     || [[ -f /proc/1/root/.dockerenv ]]; then
    printf 'Container'
  else
    printf 'Host'
  fi
}
