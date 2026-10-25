#!/usr/bin/env bash
# webroot_manifest.sh - baseline + diff of dropped/changed executables.
# Manifest: state/webroot.manifest.tsv (path, size, mtime_epoch, owner)
#
# A file is reported only when it is NEW or CHANGED since the last batch, so a
# persistent condition does not re-alert every 5 minutes. auto_prepend_file is
# checked only for those same files.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/_batch_common.sh"

plugin_name=webroot
export plugin_name
MANIFEST=$P2S_STATE_DIR/webroot.manifest.tsv
SEEN=$P2S_STATE_DIR/webroot.seen.tsv

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

tmp="$P2S_TMP_DIR/webroot.scan.$$"
: >"$tmp"
while IFS= read -r d; do
  [[ -n $d ]] || continue
  find "$d" -xdev -type f \
    \( -name '*.php' -o -name '*.phtml' -o -name '*.phar' -o -name '*.php5' \
       -o -name '*.inc' -o -name '.user.ini' -o -name '.htaccess' -o -name '*.sh' \) \
    -printf '%p\t%s\t%T@\t%U\n' 2>/dev/null >>"$tmp"
done < <(webroot_dirs)

# First run: adopt the current tree as baseline, emit nothing (no noise).
if [[ ! -s $MANIFEST ]]; then
  { printf '# path\tsize\tmtime\towner\n'; sort -u "$tmp"; } >"$MANIFEST.tmp.$$" &&
    mv -f -- "$MANIFEST.tmp.$$" "$MANIFEST"
  rm -f -- "$tmp"
  exit 0
fi

while IFS=$'\t' read -r path sz mt own; do
  [[ -z $path ]] && continue
  prev=$(grep -F -- "$path	" "$MANIFEST" | head -1)
  changed=0
  if [[ -n $prev ]]; then
    psz=$(printf '%s' "$prev" | cut -f2)
    pmt=$(printf '%s' "$prev" | cut -f3)
    pown=$(printf '%s' "$prev" | cut -f4)
    if [[ $psz != "$sz" || ${pmt%%.*} != "${mt%%.*}" ]]; then
      changed=1
      P2S_TS=$(utc_now); export P2S_TS
      emit_record webroot "$path" 0 "" "" "" "" "" "" \
        "webroot file CHANGED: $path (size $psz->$sz, owner $pown->$own)" "-"
    fi
  else
    changed=1
    P2S_TS=$(utc_now); export P2S_TS
    emit_record webroot "$path" 0 "" "" "" "" "" "" \
      "webroot file NEW: $path (size=$sz owner=$own)" "-"
  fi

  # Only inspect directives on files that just appeared or changed.
  if (( changed )) && [[ $path == *.user.ini || $path == */.user.ini ||
                         $path == *.htaccess || $path == */.htaccess ]]; then
    if grep -qiE 'auto_prepend_file' "$path" 2>/dev/null; then
      P2S_TS=$(utc_now); export P2S_TS
      emit_record webroot "$path" 0 "" "" "" "" "" "" \
        "auto_prepend_file directive found in $path" "-"
    fi
  fi
done <"$tmp"

# Content scan: a webshell already present when the baseline was adopted is
# never "NEW", so a diff-only plugin stays blind to it forever. Scan the code
# itself every batch and report the CODE, not just the path, so the analyst
# sees what the shell does without opening the file.
while IFS=$'\t' read -r path _sz _mt _own; do
  [[ -n $path ]] || continue
  [[ $path == *.user.ini || $path == */.htaccess ]] && continue
  [[ -r $path ]] || continue
  # cap: never read more than 256 KiB of a single file
  hit=$(head -c 262144 -- "$path" 2>/dev/null | grep -aoiE \
    '(system|exec|passthru|shell_exec|popen|proc_open|pcntl_exec|assert|eval|create_function|call_user_func(_array)?|preg_replace)[[:space:]]*\([^)]*\$_(REQUEST|GET|POST|COOKIE|SERVER|FILES)' \
    | head -1)
  [[ -n $hit ]] || continue
  # De-dup on path+size+mtime: an unchanged shell must not re-alert every batch.
  sig="$path\t$_sz\t$_mt"
  grep -qxF -- "$sig" "$SEEN" 2>/dev/null && continue
  printf '%s\n' "$sig" >>"$SEEN"
  P2S_TS=$(utc_now); export P2S_TS
  emit_record webroot "$path" 0 "" "" "" "" "" "" \
    "webroot webshell pattern: $path contains '$hit'" "-"
done <"$tmp"


{ printf '# path\tsize\tmtime\towner\n'; sort -u "$tmp"; } >"$MANIFEST.tmp.$$" &&
  mv -f -- "$MANIFEST.tmp.$$" "$MANIFEST"
rm -f -- "$tmp"
