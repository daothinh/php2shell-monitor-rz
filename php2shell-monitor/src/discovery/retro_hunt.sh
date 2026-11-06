#!/usr/bin/env bash
# retro_hunt.sh - one-shot hunt over existing logs including rotated/gzipped.
# Produces exactly ONE alert for the whole window (same model as a batch), with
# every raw hit line kept in evidence/.
set -u
WORKDIR=${WORKDIR:-/opt/php2shell-monitor}
source "$WORKDIR/lib/common.sh"
source "$WORKDIR/lib/log.sh"
source "$WORKDIR/lib/stream.sh"
source "$WORKDIR/lib/time_utc.sh"
source "$WORKDIR/lib/paths.sh"
source "$WORKDIR/lib/readcap.sh"
p2s_device_init || exit 1
p2s_source_conf "$WORKDIR/conf/default.conf"

# Cửa sổ retro mặc định = 00:00 UTC HÔM NAY, không phải một ngày hardcode.
# Ngày cứng (2026-10-17) là mốc của lần phát triển đầu: cài máy mới hôm nay vẫn
# quét từ 17 ngày trước, quét lại đúng những dòng mà batch 5 phút đã xử lý, và
# bắn alert cho sự kiện đã cũ. Muốn xa hơn thì đặt RETRO_SINCE tường minh.
#
# Mốc là UTC nên 00:00 UTC = 07:00 giờ Việt Nam: sự cố trong khoảng 00:00-07:00
# VN không được quét. Đây là lựa chọn có chủ ý — mốc UTC không phụ thuộc cấu
# hình TZ của máy cài đặt. Cần phủ trọn ngày VN thì đặt 17:00Z hôm trước:
#   RETRO_SINCE=2026-11-02T17:00:00Z   # = 00:00 ngày 03/11 giờ VN
SINCE=${RETRO_SINCE:-$(date -u +%Y-%m-%dT00:00:00Z)}
# Tiền tố "retro-" đã tách khỏi batch thường, nhưng hai lượt retro trong cùng
# một giây vẫn đụng nhau -> cùng lý do như scan.sh: phải duy nhất.
BATCH="retro-$(date -u +%Y%m%dT%H%M%SZ)"
_rb=$BATCH
_rs=0
while [[ -e $P2S_EVIDENCE_DIR/$BATCH.jsonl ]] ||
      { [[ -s $P2S_ALERT_DIR/queue.jsonl ]] &&
        grep -qF "\"batch_id\":\"$BATCH\"" "$P2S_ALERT_DIR/queue.jsonl" 2>/dev/null; }; do
  _rs=$((_rs + 1))
  (( _rs > 99 )) && break
  BATCH="$_rb-$_rs"
done
unset _rb _rs
# Cùng ổ khoá với scan.sh: retro-hunt chạy song song với batch 5 phút sẽ sinh
# HAI alert cho cùng một khoảng thời gian -> sysadmin nhận 2 tin. Một khoảng chỉ
# được có một alert, nên hai đường phải loại trừ nhau.
LOCK=$P2S_DEVICE_RUN_DIR/scan.lock
mkdir -p -- "$P2S_DEVICE_RUN_DIR"
# catchup.sh đã giữ scan.lock và truyền fd 9 xuống. Mở lại fd trên cùng file
# tạo open-file-description MỚI, và flock tính theo open-file-description chứ
# không theo inode — flock -n ở đây sẽ thất bại vì chính khoá của cha và lượt
# retro trong catchup tự chặn nó. Kiểm fd thật, đừng tin biến môi trường suông.
if [[ ${P2S_LOCK_HELD:-0} == 1 && -e /proc/self/fd/9 ]]; then
  :
else
  exec 9>"$LOCK"
  flock -n 9 || { echo "batch/retro khác đang chạy; bỏ lượt retro này" >&2; exit 0; }
fi

WORK=$P2S_TMP_DIR/$BATCH
mkdir -p -- "$WORK"
STREAM=$WORK/stream.tsv
HITS=$WORK/hits.tsv
: >"$STREAM"
: >"$HITS"

log_info "retro-hunt since $SINCE"

# keep only lines whose normalized ts is >= SINCE (unknown ts are kept)
_filter_since() {
  awk -F'\t' -v since="${SINCE:0:19}" '
    $1 ~ /^[0-9][0-9][0-9][0-9]-/ && substr($1,1,19) < since { next }
    { print }
  '
}

_add_access() {
  local f out="$WORK/access.tsv"
  : >"$out"
  for f in ${NGINX_ACCESS:-} ${APACHE_ACCESS:-} \
           /var/log/nginx/access.log* /var/log/apache2/access.log* \
           /var/log/apache2/other_vhosts_access.log* /var/log/httpd/access_log* \
           /var/log/nginx/*access*.log*; do
    [[ -f $f && -r $f ]] || continue
    # Cùng luật với batch: symlink -> /dev/*|/proc/* (nginx:alpine để
    # access.log -> /dev/stdout) thì `cat` đọc chính fd đang mở của tiến trình
    # này và không bao giờ EOF. retro chạy trong cửa sổ có trần thời gian, nên
    # treo ở đây là mất luôn cả lượt quét bù.
    case $(p2s_file_kind "$f") in
      regular) ;;
      *) printf 'retro: bỏ qua %s (không phải regular file)\n' "$f" >&2; continue ;;
    esac
    case $f in
      *.gz) timeout -k 2 "${RETRO_FILE_TIMEOUT:-120}" zcat -- "$f" 2>/dev/null >"$WORK/plain.log" ;;
      *)    timeout -k 2 "${RETRO_FILE_TIMEOUT:-120}" cat -- "$f" 2>/dev/null >"$WORK/plain.log" ;;
    esac
    awk -f "$P2S_SRC_DIR/lib/accesslog.awk" -v src=access_log \
        -v realfile="$f" "$WORK/plain.log" >>"$out"
  done
  cat -- "$out" >>"$STREAM"
}

_add_error_logs() {
  local f line no
  for f in ${FPM_LOG:-} ${APACHE_ERROR:-} ${NGINX_ERROR:-} \
           /var/log/php*-fpm*.log* /var/log/php-fpm/*.log* \
           /var/log/apache2/error.log* /var/log/httpd/error_log* /var/log/nginx/error.log*; do
    [[ -f $f && -r $f ]] || continue
    case $(p2s_file_kind "$f") in
      regular) ;;
      *) printf 'retro: bỏ qua %s (không phải regular file)\n' "$f" >&2; continue ;;
    esac
    local src=fpm_error
    case $f in
      /var/log/nginx/*) src=nginx_error ;;
      /var/log/apache2/*|/var/log/httpd/*) src=apache_error ;;
    esac
    no=0
    case $f in
      *.gz) timeout -k 2 "${RETRO_FILE_TIMEOUT:-120}" zcat -- "$f" 2>/dev/null ;;
      *)    timeout -k 2 "${RETRO_FILE_TIMEOUT:-120}" cat -- "$f" 2>/dev/null ;;
    esac | while IFS= read -r line; do
      no=$((no + 1))
      ts=$(t_extract_fpm_ts "$line" || t_extract_access_ts "$line" || utc_now)
      P2S_TS=$ts emit_record "$src" "$f" "$no" "" "" "" "" "" "" "$line" "-"
    done >>"$STREAM"
  done
}

_add_auditd() {
  local f line no
  for f in /var/log/audit/audit.log*; do
    [[ -f $f && -r $f ]] || continue
    case $(p2s_file_kind "$f") in
      regular) ;;
      *) continue ;;
    esac
    no=0
    case $f in
      *.gz) timeout -k 2 "${RETRO_FILE_TIMEOUT:-120}" zcat -- "$f" 2>/dev/null ;;
      *)    timeout -k 2 "${RETRO_FILE_TIMEOUT:-120}" cat -- "$f" 2>/dev/null ;;
    esac | while IFS= read -r line; do
      no=$((no + 1))
      printf '%s' "$line" | grep -qP 'type=EXECVE|type=PATH' || continue
      ts=$(printf '%s' "$line" | grep -oP '(?<=audit\()[0-9.]+' | head -1)
      [[ -n $ts ]] && ts=$(epoch_to_utc "${ts%%.*}") || ts=$(utc_now)
      P2S_TS=$ts emit_record auditd "$f" "$no" "" "" "" "" "" "" "$line" "-"
    done >>"$STREAM"
  done
}

_add_access
_add_error_logs
_add_auditd

# jq không bắt buộc — chỉ dùng cho phần tóm tắt. Có thì cài (best effort).
p2s_want_jq --quiet || true

_filter_since <"$STREAM" >"$WORK/stream.window.tsv"
mv -f -- "$WORK/stream.window.tsv" "$STREAM"

bash "$WORKDIR/engine/rule_match.sh" "$STREAM" >"$HITS" 2>/dev/null || true
bash "$WORKDIR/engine/report.sh" "$HITS" "$BATCH" "$(iso_to_epoch "$SINCE")" "$(utc_epoch)"

mkdir -p -- "$WORKDIR/reports"
report=$WORKDIR/reports/retro-hunt-$BATCH.md
{
  echo "# PHP2Shell retro-hunt"
  echo ""
  echo "- Generated: $(utc_now)"
  echo "- Project / device: $PROJECT / $DEVICE"
  echo "- Window: >= $SINCE"
  echo "- Records scanned: $(wc -l <"$STREAM")"
  echo "- Rule hits: $(wc -l <"$HITS")"
  echo ""
  echo "## Hits by rule"
  if [[ -n ${P2S_JQ:-} ]]; then
    "$P2S_JQ" -r '.rule' "$HITS" 2>/dev/null | sort | uniq -c | sort -rn | sed 's/^/    /'
  fi
  echo ""
  echo "## Raw hits (file:line)"
  awk -F'\t' '{ printf "    %s:%s  %s  %s\n", $3, $4, $12, substr($11,1,160) }' "$HITS" |
    head -200
  if [[ -s $HITS ]]; then
    echo ""
    echo "## Evidence file"
    echo "    $P2S_EVIDENCE_DIR/$BATCH.jsonl"
  else
    echo ""
    echo "## Evidence file"
    echo "    (none — no rule hits in this window)"
  fi
} >"$report"

# Phải chốt kết quả TRƯỚC khi xoá $WORK: $HITS nằm trong đó, nên kiểm -s sau
# `rm -rf $WORK` luôn sai và mọi lượt retro đều báo "no hits" — kể cả khi alert
# đã được ghi. Setup dựa vào dòng này để nói với operator là có phát hiện hay
# không, nên báo sai ở đây làm hỏng đúng thông tin cần thấy lúc cài.
if [[ -s $HITS ]]; then
  _hits_n=$(wc -l <"$HITS")
  _has_alert=1
else
  _hits_n=0
  _has_alert=0
fi
rm -rf -- "$WORK"
echo "retro-hunt complete: $report"
if (( _has_alert )); then
  printf 'alert written to %s (%d hit)\n' "$P2S_ALERT_DIR/queue.jsonl" "$_hits_n"
else
  echo "no hits: no alert produced"
fi
