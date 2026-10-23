#!/usr/bin/env bash
# webroot_manifest.sh - baseline + diff detection of dropped executables (P2S-020/P2S-022).
# Manifest stored in state/webroot.manifest.tsv: path \t size \t mtime_epoch \t owner
set -u
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_batch_common.sh"

plugin_name=webroot
MANIFEST=$P2S_STATE_DIR/webroot.manifest.tsv

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

# Scan webroots; emit records for NEW or CHANGED executable-looking files.
plugin_run() {
  local d f path sz mt own prev
  local -a current=()
  local tmp="$P2S_STATE_DIR/webroot.scan.$$"
  : >"$tmp"
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    find "$d" -xdev -type f \
      \( -name '*.php' -o -name '*.phtml' -o -name '*.phar' -o -name '*.php5' \
         -o -name '*.inc' -o -name '.user.ini' -o -name '.htaccess' -o -name '*.sh' \) \
      -printf '%p\t%s\t%T@\t%U\n' 2>/dev/null >>"$tmp"
  done < <(webroot_dirs)

  while IFS=$'\t' read -r path sz mt own; do
    [[ -z $path ]] && continue
    current+=("$path")
    if [[ -s $MANIFEST ]] && grep -F -- "$path	" "$MANIFEST" >/dev/null 2>&1; then
      prev=$(grep -F -- "$path	" "$MANIFEST" | head -1)
      local psz pmt pown
      IFS=$'\t' read -r _ psz pmt pown <<<"$prev"
      if [[ $psz != "$sz" || ${pmt%%.*} != "${mt%%.*}" ]]; then
        P2S_TS=$(utc_now); P2S_SIZE=$sz; P2S_FILE=$path
        emit_record webroot "" "" "" "" "" "$sz" "" "" "$path" "P2S-020" "webroot file CHANGED: $path (size $psz->$sz, owner $pown->$own)"
      fi
    else
      P2S_TS=$(utc_now); P2S_SIZE=$sz; P2S_FILE=$path
      emit_record webroot "" "" "" "" "" "$sz" "" "" "$path" "P2S-020" "webroot file NEW: $path (owner=$own)"
    fi
    # .user.ini / .htaccess with auto_prepend = P2S-022
    if [[ $path == *.user.ini || $path == .htaccess || $path == */.user.ini || $path == */.htaccess ]]; then
      if grep -qiE 'auto_prepend_file|php_value auto_prepend_file' "$path" 2>/dev/null; then
        P2S_TS=$(utc_now); P2S_FILE=$path
        emit_record webroot "" "" "" "" "" "" "" "" "$path" "P2S-022" "auto_prepend_file directive found in $path"
      fi
    fi
  done <"$tmp"

  # update manifest (full snapshot; keep small)
  { printf '# path\tsize\tmtime\towner\n'; sort -u "$tmp"; } >"$MANIFEST.tmp.$$" &&
    mv -f -- "$MANIFEST.tmp.$$" "$MANIFEST"
  rm -f -- "$tmp"
  return 0
}

plugin_run
exit 0
