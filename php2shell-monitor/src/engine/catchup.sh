#!/usr/bin/env bash
# catchup.sh - quét bù chạy NỀN ngay sau khi cài: retro-hunt (log đã rotate)
# rồi lượt quét đầu tiên trên log hiện có.
#
# Vì sao tách khỏi main.sh: cài đặt là thao tác của người vận hành, phải trả
# kết quả ngay — ghép nối server, cấp API key, gửi tin Telegram. Quét log cũ
# trên máy thật có hàng trăm MB (kể cả .gz) nên có thể mất vài phút; bắt người
# dùng ngồi chờ trước màn hình chỉ để thấy "chưa xong trong 90s" là vô nghĩa.
# Toàn bộ phần quét bù chuyển vào tiến trình nền này, cài đặt kết thúc trong vài
# giây, kết quả quét bù hiện ở `php2shell-monitor.sh status`.
#
# KHOÁ: main.sh mở fd 9 trên scan.lock rồi flock TRƯỚC khi fork tiến trình này,
# nên catchup thừa hưởng đúng ổ khoá đó và giữ nó suốt cả hai lượt. Nhờ vậy
# supervisor bật sau đó chắc chắn không chen vào giữa: batch đầu của nó thấy
# lock bận, bỏ lượt, tick kế tiếp chạy sau BATCH_INTERVAL. Không có khoá này,
# retro và batch 5 phút có thể cùng xử lý một khoảng thời gian -> hai alert.
#
# Chạy tay được: `sudo bash engine/catchup.sh` (khi đó tự lấy lock).
set -u
WORKDIR=${WORKDIR:-/opt/php2shell-monitor}
export WORKDIR
source "$WORKDIR/lib/common.sh"
source "$WORKDIR/lib/log.sh"
source "$WORKDIR/lib/paths.sh"
p2s_device_init || exit 1
p2s_source_conf "$WORKDIR/conf/default.conf"

STATUS=$P2S_DEVICE_RUN_DIR/catchup.status
LOG=$P2S_DEVICE_RUN_DIR/catchup.log
LOCK=$P2S_DEVICE_RUN_DIR/scan.lock
mkdir -p -- "$P2S_DEVICE_RUN_DIR"

# ghi trạng thái nguyên tử: status.sh đọc file này bất cứ lúc nào
_status() { # <state> [chi tiết]
  printf '%s\t%s\t%s\n' "$(utc_now)" "$1" "${2-}" >"$STATUS.tmp.$$" &&
    mv -f -- "$STATUS.tmp.$$" "$STATUS"
}

# fd 9 đã được main.sh mở + flock trước khi fork. flock trên CÙNG fd là no-op
# thành công nên nhánh này vừa xác nhận "đang giữ khoá" vừa là đường tự lấy
# khoá khi chạy tay. Không dùng biến môi trường làm cờ: env có thể bị đặt tay.
if ! flock -n 9 2>/dev/null; then
  exec 9>"$LOCK"
  flock -w 120 9 || { _status skipped "không lấy được scan.lock"; exit 0; }
fi
# Con (retro_hunt.sh, scan.sh) phải biết đang thừa hưởng khoá để không tự mở
# lại fd 9 trên cùng file rồi flock lần nữa — flock tính theo
# open-file-description, nên lần thứ hai sẽ thất bại vì chính khoá của cha.
export P2S_LOCK_HELD=1

# Heartbeat: supervisor coi scan.lock cũ hơn (SCAN_TIMEOUT+60)s là treo và xoá
# nó. Retro trên log lớn có thể chạy lâu hơn ngưỡng đó; không touch thì
# supervisor xoá tên lock (không phải inode đang giữ) rồi chạy batch song song
# với retro — đúng cái mà khoá này sinh ra để tránh.
(
  while :; do
    sleep 30
    touch -- "$LOCK" 2>/dev/null || exit 0
  done
) &
HB=$!
trap 'kill "$HB" 2>/dev/null' EXIT INT TERM

_status running "retro-hunt"

# ---- 1. retro-hunt: log đã rotate/gzip, sự cố xảy ra TRƯỚC khi cài ----------
# Cửa sổ mặc định = 00:00 UTC hôm nay (= 07:00 giờ VN), xem retro_hunt.sh.
if [[ -n ${RETRO_SINCE:-} ]]; then export RETRO_SINCE; else unset RETRO_SINCE; fi
retro_out=$(timeout "${P2S_RETRO_TIMEOUT:-600}" \
  bash "$WORKDIR/discovery/retro_hunt.sh" 2>&1)
retro_rc=$?
{
  printf '=== retro-hunt ===\n'
  printf '%s\n' "$retro_out"
} >>"$LOG" 2>&1

# Bị kill vì trần thời gian KHÔNG phải "log không đọc được" — operator cần
# phân biệt hai trường hợp này để quyết định có nâng P2S_RETRO_TIMEOUT.
if (( retro_rc == 124 || retro_rc == 137 )); then
  retro=timeout
elif grep -q "alert written to" <<<"$retro_out"; then
  retro=hits
elif grep -q "no hits" <<<"$retro_out"; then
  retro=no-hits
else
  retro=failed
fi
log_info "catchup: retro-hunt -> $retro"

# ---- 2. lượt quét đầu tiên trên log hiện có ---------------------------------
# Offset khởi đầu bằng 0 nên batch này đọc TOÀN BỘ file log hiện có, kể cả
# phần ghi trước khi cài.
_status running "first-scan"
timeout "${P2S_RETRO_TIMEOUT:-600}" bash "$WORKDIR/engine/scan.sh" </dev/null \
  >>"$LOG" 2>&1
scan_rc=$?
log_info "catchup: first scan rc=$scan_rc"

if (( scan_rc == 0 )); then
  scan=ok
elif (( scan_rc == 124 || scan_rc == 137 )); then
  scan=timeout
else
  scan="rc$scan_rc"
fi

_status complete "retro=$retro scan=$scan"
exit 0
