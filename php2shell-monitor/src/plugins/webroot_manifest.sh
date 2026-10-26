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
# Danh sách webshell đang thực sự nằm trên đĩa (path + đoạn code khớp).
# KHÔNG phải dedup: mỗi batch quét lại và báo lại chừng nào file còn đó.
SHELLS=$P2S_STATE_DIR/webroot.shells.tsv
SHELLS_NOW=$P2S_STATE_DIR/webroot.shells.now.$$

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

# First run: adopt the current tree as baseline, emit nothing (no noise).
# Manifest lưu khoá ỔN ĐỊNH (xem p2s_container_manifest_key): với file trong
# container là "container:<cid>:<relpath>", không phải /proc/<pid>/root/...
# nên restart container không làm toàn bộ webroot trông như "file NEW".
if [[ ! -s $MANIFEST ]]; then
  {
    printf '# path\tsize\tmtime\towner\n'
    while IFS=$'\t' read -r path sz mt own; do
      [[ -n $path ]] || continue
      printf '%s\t%s\t%s\t%s\n' "$(p2s_container_manifest_key "$path")" "$sz" "$mt" "$own"
    done <"$tmp" | sort -u
  } >"$MANIFEST.tmp.$$" && mv -f -- "$MANIFEST.tmp.$$" "$MANIFEST"
  rm -f -- "$tmp"
  exit 0
fi

while IFS=$'\t' read -r path sz mt own; do
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
# itself every batch and report the CODE, not just the path, so the analyst
# sees what the shell does without opening the file.
#
# Báo lại MỖI batch chừng nào file còn đó. Trước đây khối này dedup trên
# path+size+mtime và ghi vĩnh viễn vào webroot.seen.tsv: một shell đứng yên
# (webshell đã drop thì không ai sửa nữa) chỉ báo đúng một lần rồi câm mãi.
# Hậu quả thực tế: batch sau mất impact=rce nên alert tụt từ CRITICAL xuống
# MODERATE, và Telegram chỉ còn "Server đang bị khai thác php2shell" trong khi
# server đã bị chiếm quyền. Trạng thái "đang có shell" là sự thật của batch
# hiện tại, không phải sự kiện một lần — nó phải tồn tại cùng file.
: >"$SHELLS_NOW"
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
  printf '%s\t%s\n' "$(p2s_container_manifest_key "$path")" "$hit" >>"$SHELLS_NOW"
  disp=$(p2s_container_display "$path")
  P2S_TS=$(utc_now); export P2S_TS
  emit_record webroot "$disp" 0 "" "" "" "" "" "" \
    "webroot webshell pattern: $disp contains '$hit'" "-"
done <"$tmp"

# webroot.shells.tsv = ảnh chụp các shell của batch này. File biến mất thì
# dòng cũng biến mất, nên không có dedup nào sống lâu hơn sự thật trên đĩa.
sort -u "$SHELLS_NOW" >"$SHELLS" 2>/dev/null || : >"$SHELLS"
rm -f -- "$SHELLS_NOW"


{
  printf '# path\tsize\tmtime\towner\n'
  while IFS=$'\t' read -r path sz mt own; do
    [[ -n $path ]] || continue
    printf '%s\t%s\t%s\t%s\n' "$(p2s_container_manifest_key "$path")" "$sz" "$mt" "$own"
  done <"$tmp" | sort -u
} >"$MANIFEST.tmp.$$" && mv -f -- "$MANIFEST.tmp.$$" "$MANIFEST"
rm -f -- "$tmp"
