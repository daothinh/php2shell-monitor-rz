#!/usr/bin/env bash
# webroot_manifest.sh - baseline + diff of dropped/changed executables.
# Manifest: state/webroot.manifest.tsv (path, size, mtime_epoch, owner)
#
# A file is reported only when it is NEW or CHANGED since the last batch, so a
# persistent condition does not re-alert every 5 minutes. auto_prepend_file is
# checked only for those same files.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/_batch_common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/container.sh"

plugin_name=webroot
export plugin_name
MANIFEST=$P2S_STATE_DIR/webroot.manifest.tsv
# Tập webshell ĐÃ BÁO: mỗi dòng "<khoá ổn định>\t<đoạn code khớp>".
# Dùng để chặn spam, không phải để báo cáo trạng thái (xem khối content scan).
SHELLS=$P2S_STATE_DIR/webroot.shells.tsv
SHELLS_NOW=$P2S_STATE_DIR/webroot.shells.now.$$
SHELLS_DISP=$P2S_STATE_DIR/webroot.shells.disp.$$

webroot_dirs() {
  local -a out=()
  local d
  for d in ${WEBROOTS:-} /var/www /var/www/html /usr/share/nginx/html /home/*/public_html; do
    [[ -z $d ]] && continue
    [[ -d $d && -r $d ]] && out+=("$d")
  done
  ((${#out[@]})) && printf '%s\n' "${out[@]}"
  return 0
}

# container_webroot_dirs — webroot BÊN TRONG từng container đang chạy, qua
# /proc/<pid>/root (xem lib/container.sh). Host không có /var/www/html khi ứng
# dụng chạy trong container, nên webroot_dirs() ở trên quét rỗng và webshell
# đã drop vào container không bao giờ bị thấy — đó là lỗ hổng thật đã bỏ sót
# s.php trên php2shell-lab-1.
container_webroot_dirs() {
  local _short _name _pid rootfs _cid d
  while IFS=$'\t' read -r _short _name _pid rootfs _cid; do
    [[ -n $rootfs ]] || continue
    # Chỉ lấy thư mục NÔNG NHẤT còn tồn tại: /var/www/html đã bao /var/www,
    # nên quét cả hai làm mỗi file xuất hiện hai lần trong manifest và mỗi
    # webshell bị báo hai lần trong cùng một alert.
    for d in /var/www/html /usr/share/nginx/html /var/www; do
      if [[ -d "$rootfs$d" && -r "$rootfs$d" ]]; then
        printf '%s\n' "$rootfs$d"
        break
      fi
    done
  done < <(p2s_containers)
}

tmp="$P2S_TMP_DIR/webroot.scan.$$"
: >"$tmp"
while IFS= read -r d; do
  [[ -n $d ]] || continue
  # -L để theo symlink trong container (một số image symlink webroot), nhưng
  # -xdev vẫn giữ phạm vi trong một filesystem.
  find -L "$d" -xdev -type f \
    \( -name '*.php' -o -name '*.phtml' -o -name '*.phar' -o -name '*.php5' \
       -o -name '*.inc' -o -name '.user.ini' -o -name '.htaccess' -o -name '*.sh' \) \
    -printf '%p\t%s\t%T@\t%U\n' 2>/dev/null >>"$tmp"
done < <(webroot_dirs; container_webroot_dirs)

# Lượt đầu: nhận cây webroot hiện có làm baseline, KHÔNG báo NEW/CHANGED cho
# từng file — một webroot sẵn có sẽ sinh hàng nghìn dòng "file NEW".
# Manifest lưu khoá ỔN ĐỊNH (xem p2s_container_manifest_key): với file trong
# container là "container:<cid>:<relpath>", không phải /proc/<pid>/root/...
# nên restart container không làm toàn bộ webroot trông như "file NEW".
#
# KHÔNG `exit 0` sau khi ghi baseline: content scan bên dưới phải chạy cả ở
# lượt đầu. Trước đây thoát ngay, nên webshell đã nằm sẵn trên đĩa trước khi
# cài chỉ được báo ở batch THỨ HAI — trễ 5 phút so với lúc đáng lẽ phải biết,
# và nếu supervisor không kịp chạy batch 2 thì shell đó chưa từng xuất hiện
# trong bất kỳ alert nào.
baseline_run=0
if [[ ! -s $MANIFEST ]]; then
  baseline_run=1
  {
    printf '# path\tsize\tmtime\towner\n'
    while IFS=$'\t' read -r path sz mt own; do
      [[ -n $path ]] || continue
      printf '%s\t%s\t%s\t%s\n' "$(p2s_container_manifest_key "$path")" "$sz" "$mt" "$own"
    done <"$tmp" | sort -u
  } >"$MANIFEST.tmp.$$" && mv -f -- "$MANIFEST.tmp.$$" "$MANIFEST"
fi

# Diff NEW/CHANGED chỉ có nghĩa khi ĐÃ có baseline; lượt đầu bỏ qua để không
# biến cả cây webroot thành "file NEW".
while (( ! baseline_run )) && IFS=$'\t' read -r path sz mt own; do
  [[ -z $path ]] && continue
  key=$(p2s_container_manifest_key "$path")
  # Tên hiển thị trong alert: container:<tên>:/var/www/html/s.php
  disp=$(p2s_container_display "$path")
  prev=$(grep -F -- "$key	" "$MANIFEST" | head -1)
  changed=0
  if [[ -n $prev ]]; then
    psz=$(printf '%s' "$prev" | cut -f2)
    pmt=$(printf '%s' "$prev" | cut -f3)
    pown=$(printf '%s' "$prev" | cut -f4)
    if [[ $psz != "$sz" || ${pmt%%.*} != "${mt%%.*}" ]]; then
      changed=1
      P2S_TS=$(utc_now); export P2S_TS
      emit_record webroot "$disp" 0 "" "" "" "" "" "" \
        "webroot file CHANGED: $disp (size $psz->$sz, owner $pown->$own)" "-"
    fi
  else
    changed=1
    P2S_TS=$(utc_now); export P2S_TS
    emit_record webroot "$disp" 0 "" "" "" "" "" "" \
      "webroot file NEW: $disp (size=$sz owner=$own)" "-"
  fi

  # Only inspect directives on files that just appeared or changed.
  if (( changed )) && [[ $path == *.user.ini || $path == */.user.ini ||
                         $path == *.htaccess || $path == */.htaccess ]]; then
    if grep -qiE 'auto_prepend_file' "$path" 2>/dev/null; then
      P2S_TS=$(utc_now); export P2S_TS
      emit_record webroot "$disp" 0 "" "" "" "" "" "" \
        "auto_prepend_file directive found in $disp" "-"
    fi
  fi
done <"$tmp"

# Content scan: a webshell already present when the baseline was adopted is
# never "NEW", so a diff-only plugin stays blind to it forever. Scan the code
# itself every batch — but BÁO MỘT LẦN cho mỗi nội dung shell, không phải mỗi
# batch.
#
# VÌ SAO KHÔNG BÁO LẠI MỖI BATCH (bản trước làm vậy):
# "Alert chỉ phục vụ cảnh báo, không phục vụ báo cáo trạng thái." Một shell đứng
# yên trên đĩa không phải hành vi mới — không có ai vừa làm gì. Báo lại mỗi 5
# phút biến 1 sự cố thành 48 tin giống nhau (đo được trên lab: 48 batch liên
# tiếp, cùng một signature), và người trực ca sẽ tắt thông báo — đúng lúc sự cố
# tiếp theo xảy ra thì không ai đọc.
#
# VÌ SAO KHÔNG PHẢI dedup path+size+mtime như webroot.seen.tsv cũ:
# khoá cũ không phân biệt "cùng shell" với "shell bị thay bằng shell khác cùng
# kích thước". Khoá ở đây là (path, đoạn code khớp): sửa nội dung, đổi hàm, đổi
# biến nhận vào — đều là hành vi mới và phải báo lại. Shell bị xoá rồi drop lại
# nguyên bản cũng báo lại, vì lần drop đó là hành vi mới.
#
# KHÔNG gửi tin "đã hết" khi shell biến mất: dọn dẹp không phải sự cố, và alert
# không phải kênh báo cáo trạng thái. Dòng tương ứng chỉ đơn giản rời khỏi
# SHELLS, im lặng.
#
# ĐÁNH ĐỔI ĐÃ BIẾT: batch không có hành vi mới thì không có hit P2S-056, nên
# severity batch đó chỉ phản ánh các hit mới. Đó là hệ quả đúng của nghiệp vụ
# "alert = cảnh báo hành vi", không phải mất tín hiệu: shell vẫn nằm trong
# SHELLS và trong manifest, và nếu có hành vi mới thật (file mới, nội dung đổi,
# request khai thác trong access log) thì batch đó có hit và lại CRITICAL.
# Bản trước giữ CRITICAL bằng cách bắn một tin giống hệt mỗi 5 phút — đúng
# severity nhưng sai hoàn toàn về mặt vận hành.
: >"$SHELLS_NOW"
: >"$SHELLS_DISP"
while IFS=$'\t' read -r path _sz _mt _own; do
  [[ -n $path ]] || continue
  [[ $path == *.user.ini || $path == */.htaccess ]] && continue
  [[ -r $path ]] || continue
  # cap: never read more than 256 KiB of a single file
  hit=$(head -c 262144 -- "$path" 2>/dev/null | grep -aoiE \
    '(system|exec|passthru|shell_exec|popen|proc_open|pcntl_exec|assert|eval|create_function|call_user_func(_array)?|preg_replace)[[:space:]]*\([^)]*\$_(REQUEST|GET|POST|COOKIE|SERVER|FILES)' \
    | head -1)
  [[ -n $hit ]] || continue
  # Khoá ổn định cho webroot.shells.tsv, tên đọc được cho alert.
  key=$(p2s_container_manifest_key "$path")
  printf '%s\t%s\n' "$key" "$hit" >>"$SHELLS_NOW"
  # Đã báo cho đúng cặp (path, đoạn code) này rồi ⇒ không phải hành vi mới.
  # So sánh bằng awk trên từng field TAB, không ghép chuỗi có tab vào pattern.
  if [[ -s $SHELLS ]] && awk -F'\t' -v k="$key" -v h="$hit" \
       '$1 == k && $2 == h { found = 1; exit } END { exit !found }' "$SHELLS"; then
    printf '%s\t%s\n' "$key" "$hit" >>"$SHELLS_DISP"
    continue
  fi
  disp=$(p2s_container_display "$path")
  P2S_TS=$(utc_now); export P2S_TS
  emit_record webroot "$disp" 0 "" "" "" "" "" "" \
    "webroot webshell pattern: $disp contains '$hit'" "-"
  printf '%s\t%s\n' "$key" "$hit" >>"$SHELLS_DISP"
done <"$tmp"

# SHELLS = tập shell đã báo và CÒN trên đĩa. Shell biến mất thì dòng rời khỏi
# đây, nên nếu nó được drop lại sau này thì đó lại là hành vi mới và báo lại.
# Không dòng nào được ghi thêm ngoài SHELLS_DISP, nên tập này không phình ra
# theo thời gian và không giữ ký ức về file đã bị xoá.
sort -u "$SHELLS_DISP" >"$SHELLS" 2>/dev/null || : >"$SHELLS"
rm -f -- "$SHELLS_NOW" "$SHELLS_DISP"


{
  printf '# path\tsize\tmtime\towner\n'
  while IFS=$'\t' read -r path sz mt own; do
    [[ -n $path ]] || continue
    printf '%s\t%s\t%s\t%s\n' "$(p2s_container_manifest_key "$path")" "$sz" "$mt" "$own"
  done <"$tmp" | sort -u
} >"$MANIFEST.tmp.$$" && mv -f -- "$MANIFEST.tmp.$$" "$MANIFEST"
rm -f -- "$tmp"
