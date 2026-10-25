#!/usr/bin/env bash
# bootstrap.sh - makeself startup script. Finishes the install in place.
# Invariants: root required; only the install directory is written; code is
# replaced on upgrade while conf/ and projects/ are preserved.
set -u

die() { printf 'php2shell-monitor: %s\n' "$*" >&2; exit 1; }

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  die "root is REQUIRED (run with sudo). Aborting, nothing was written."
fi

# The install directory is where the payload was unpacked. Deriving it from our
# own path keeps the tarball fallback (untar anywhere) working, while the
# self-extracting archive always lands in /opt/php2shell-monitor.
WORKDIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) ||
  die "cannot resolve install directory"
[[ -d $WORKDIR && ! -L $WORKDIR ]] || die "$WORKDIR is not a real directory"
[[ -f $WORKDIR/main.sh && -d $WORKDIR/engine ]] || die "$WORKDIR does not look like a payload"
export WORKDIR

# Data directories live under the install dir as well; they survive upgrades
# because they are not part of the payload.
for d in conf projects reports run tmp; do
  if [[ -e "$WORKDIR/$d" && ! -d "$WORKDIR/$d" ]]; then
    die "$WORKDIR/$d is not a directory. Aborting."
  fi
  [[ -d "$WORKDIR/$d" ]] || (umask 077 && mkdir -p -- "$WORKDIR/$d") || die "cannot create $WORKDIR/$d"
done

# First install only: seed conf/ from the shipped templates. Existing files are
# never touched, so operator edits survive every upgrade.
for f in "$WORKDIR"/conf.default/*.conf; do
  [[ -f $f ]] || continue
  b=$(basename -- "$f")
  [[ -e "$WORKDIR/conf/$b" ]] || (umask 077 && cp -a -- "$f" "$WORKDIR/conf/$b") ||
    die "cannot seed conf/$b"
done
[[ -d "$WORKDIR/conf/rules.d" ]] || (umask 077 && mkdir -p -- "$WORKDIR/conf/rules.d")

# Upgrade: the payload is unpacked over the previous install, so files that the
# new version dropped would linger and keep running. MANIFEST lists everything
# the build shipped; delete anything else under the CODE trees. conf/ and
# projects/ are operator data, and export/ holds the exported alerts, so none of
# them is ever pruned.
if [[ -s $WORKDIR/MANIFEST ]]; then
  (cd -- "$WORKDIR" && find lib engine plugins rules discovery third_party conf.default \
    -type f 2>/dev/null) | LC_ALL=C sort >"$WORKDIR/.present"
  LC_ALL=C sort "$WORKDIR/MANIFEST" >"$WORKDIR/.manifest"
  comm -23 "$WORKDIR/.present" "$WORKDIR/.manifest" >"$WORKDIR/.stale"
  while IFS= read -r rel; do
    [[ -n $rel ]] || continue
    rm -f -- "$WORKDIR/$rel"
  done <"$WORKDIR/.stale"
  rm -f -- "$WORKDIR/.present" "$WORKDIR/.manifest" "$WORKDIR/.stale"
fi

# Everything below the install dir holds raw log lines (IPs, URIs, request
# bodies): root-only, no world access. The payload keeps the build machine's
# ownership through tar, so ownership is forced here: a non-root owner could
# edit code that root later executes.
chown -R -- root:root "$WORKDIR" 2>/dev/null || die "cannot chown $WORKDIR to root"
find "$WORKDIR" -xdev -type d -exec chmod 0700 {} + 2>/dev/null
find "$WORKDIR" -xdev -type f -exec chmod 0600 {} + 2>/dev/null
find "$WORKDIR" -xdev -name '*.sh' -exec chmod 0700 {} + 2>/dev/null
find "$WORKDIR" -xdev -name '*.awk' -exec chmod 0600 {} + 2>/dev/null

cd -- "$WORKDIR" || die "cannot cd into $WORKDIR"
exec bash ./main.sh "$@"
