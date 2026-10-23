#!/usr/bin/env bash
# bootstrap.sh - makeself startup script (plan 5.3).
# Runs from the temporary extraction dir; copies payload into the workdir,
# then execs main.sh with cwd=WORKDIR. All paths after this are workdir-relative.
#
# Invariants (plan 0, 5.2):
#   - root required
#   - workdir is the ONLY system change: real dir, owner root, mode 0700, no symlink
#   - code dirs overwritten on upgrade; conf/, state/, alerts/, reports/ preserved
set -u

# ---- root check: first action, fail closed --------------------------------
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  printf 'php2shell-monitor: root is REQUIRED (run with sudo). Aborting, nothing was written.\n' >&2
  exit 1
fi

WORKDIR=/tmp/php2shell-monitor
export WORKDIR

# ---- workdir safe-init -----------------------------------------------------
workdir_check() {
  local d=$1
  if [[ -L $d ]]; then
    printf 'php2shell-monitor: UNSAFE: %s is a symlink. Aborting.\n' "$d" >&2
    return 2
  fi
  if [[ ! -e $d ]]; then
    return 1
  fi
  if [[ ! -d $d ]]; then
    printf 'php2shell-monitor: UNSAFE: %s exists and is not a directory. Aborting.\n' "$d" >&2
    return 2
  fi
  local st owner mode
  st=$(stat -c '%u %a' -- "$d" 2>/dev/null)
  if [[ -z $st ]]; then
    printf 'php2shell-monitor: UNSAFE: cannot stat %s. Aborting.\n' "$d" >&2
    return 2
  fi
  owner=${st%% *}; mode=${st##* }
  if [[ $owner -ne 0 ]]; then
    printf 'php2shell-monitor: UNSAFE: %s owner uid=%s (expected root). Aborting.\n' "$d" "$owner" >&2
    return 2
  fi
  if [[ $mode != 700 && $mode != 0700 ]]; then
    printf 'php2shell-monitor: UNSAFE: %s mode=%s (expected 0700). Aborting.\n' "$d" "$mode" >&2
    return 2
  fi
  return 0
}

rc=0
workdir_check "$WORKDIR" || rc=$?
if [[ $rc -eq 1 ]]; then
  (umask 077 && mkdir -m 0700 -- "$WORKDIR") || {
    printf 'php2shell-monitor: cannot create %s\n' "$WORKDIR" >&2
    exit 1
  }
elif [[ $rc -ne 0 ]]; then
  exit 1
fi

# ---- layout ----------------------------------------------------------------
for d in lib engine plugins rules/pack discovery export conf state alerts export reports run tmp; do
  if [[ -e "$WORKDIR/$d" && ! -d "$WORKDIR/$d" ]]; then
    printf 'php2shell-monitor: %s/%s is not a directory. Aborting.\n' "$WORKDIR" "$d" >&2
    exit 1
  fi
  [[ -d "$WORKDIR/$d" ]] || (umask 077 && mkdir -m 0700 -p -- "$WORKDIR/$d") || exit 1
done
chmod 0700 -- "$WORKDIR" 2>/dev/null

# ---- copy payload (code overwritten, conf/state preserved) -----------------
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
copy_tree() { # src dst
  local s=$1 d=$2
  [[ -d $s ]] || return 0
  (umask 077 && cp -a -- "$s/." "$d/") || return 1
  find "$d" -type d -exec chmod 0700 {} + 2>/dev/null
  find "$d" -type f -exec chmod 0600 {} + 2>/dev/null
  # scripts must stay executable for direct exec; bash can run them anyway
  find "$d" -name '*.sh' -exec chmod 0700 {} + 2>/dev/null
  return 0
}

copy_tree "$here/lib"       "$WORKDIR/lib"       || exit 1
copy_tree "$here/engine"    "$WORKDIR/engine"    || exit 1
copy_tree "$here/plugins"   "$WORKDIR/plugins"   || exit 1
copy_tree "$here/rules"     "$WORKDIR/rules"     || exit 1
copy_tree "$here/discovery" "$WORKDIR/discovery" || exit 1
copy_tree "$here/export"    "$WORKDIR/export"    || exit 1
cp -a -- "$here/main.sh" "$WORKDIR/main.sh" || exit 1
chmod 0700 -- "$WORKDIR/main.sh"

# conf: first-install only (user edits survive upgrades)
for f in default.conf rules.conf whitelist.conf; do
  if [[ ! -f "$WORKDIR/conf/$f" && -f "$here/conf/$f" ]]; then
    (umask 077 && cp -a -- "$here/conf/$f" "$WORKDIR/conf/$f")
  fi
done
chmod 0600 -- "$WORKDIR/conf/"*.conf 2>/dev/null

# ---- hand off to dispatcher -------------------------------------------------
export P2S_VERSION
cd -- "$WORKDIR" || exit 1
exec bash ./main.sh "$@"
