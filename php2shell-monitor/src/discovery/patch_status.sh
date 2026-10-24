#!/usr/bin/env bash
# patch_status.sh - determine patch state from PACKAGE CHANGELOG, not version
# number (plan 0.5: Ubuntu ESM/CloudLinux backports do not bump version).
# Exit codes follow the cybaverse convention (plan 2):
#   0 = patched (or no PHP), 1 = likely vulnerable, 2 = unknown
set -u
WORKDIR=${WORKDIR:-/opt/php2shell-monitor}
# shellcheck source=/dev/null
source "$WORKDIR/lib/common.sh"

status=0
found_php=0
declare -A branch_fixed=([8.2]=35 [8.3]=36 [8.4]=27 [8.5]=12)

_changelog_has_fix() {
  local pkg=$1
  # deb
  local f
  for f in /usr/share/doc/"$pkg"/changelog.Debian.gz /usr/share/doc/"$pkg"/changelog.gz; do
    [[ -r $f ]] || continue
    zcat "$f" 2>/dev/null | grep -qE 'CVE-2026-10961[89]' && return 0
  done
  # rpm
  if have rpm; then
    rpm -q --changelog "$pkg" 2>/dev/null | grep -qE 'CVE-2026-10961[89]' && return 0
  fi
  return 1
}

echo "## php package inventory + changelog evidence"
if have dpkg-query; then
  while IFS=$'\t' read -r pkg ver; do
    found_php=1
    echo "-- $pkg $ver"
    ver_clean=$(printf '%s' "$ver" | grep -oP '^[0-9]+(\.[0-9]+){1,2}')
    major_minor=$(printf '%s' "$ver_clean" | cut -d. -f1,2)
    fixed=${branch_fixed[$major_minor]:-}
    if _changelog_has_fix "$pkg"; then
      echo "   state=PATCHED (changelog)"
    else
      if [[ -n $fixed ]]; then
        patch_ver="${major_minor}.${fixed}"
        if printf '%s\n%s\n' "$ver_clean" "$patch_ver" | sort -V -C; then
          # ver_clean < patch_ver
          echo "   state=LIKELY VULNERABLE (version < $patch_ver; no changelog fix found)"
          status=1
        else
          echo "   state=UNKNOWN (version >= $patch_ver but changelog has no CVE entry; verify vendor backport)"
          [[ $status -eq 0 ]] && status=2
        fi
      else
        echo "   state=NO PATCH BRANCH (PHP <= 8.1 is EOL; vendor NES only)"
        status=1
      fi
    fi
  done < <(dpkg-query -W -f='${Package}\t${Version}\n' 'php*' 2>/dev/null | grep -E '^php[0-9.]*(-fpm|-cli|-common)?\s')
elif have rpm; then
  while IFS= read -r pkg; do
    found_php=1
    ver=$(rpm -q --qf '%{VERSION}\n' "$pkg" 2>/dev/null | head -1)
    echo "-- $pkg $ver"
    if _changelog_has_fix "$pkg"; then
      echo "   state=PATCHED (changelog)"
    else
      echo "   state=UNKNOWN (no CVE entry in changelog)"
      [[ $status -eq 0 ]] && status=2
    fi
  done < <(rpm -qa 'php*' 2>/dev/null)
else
  echo "no package manager detected"
fi

if [[ $found_php -eq 0 ]]; then
  echo "no php package matched"
  exit 0
fi
exit "$status"
