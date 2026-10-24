#!/usr/bin/env bash
# build.sh - shellcheck + tests + makeself -> dist/php2shell-monitor.sh (+sha256)
# Runs on the BUILD machine only (needs makeself; target machine needs none).
#
# The archive unpacks directly into INSTALL_DIR on the target host; nothing is
# staged in /tmp and no second copy is made by bootstrap.sh.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

VERSION=$(cat VERSION 2>/dev/null || echo "1.0.0")
DIST=dist
PAYLOAD=dist/payload
INSTALL_DIR=/opt/php2shell-monitor

mkdir -p -- "$DIST"
rm -rf -- "$PAYLOAD"
mkdir -p -- "$PAYLOAD"

# ---- assemble payload (bootstrap runs from this tree) ----
# conf/ ships as conf.default/: the live conf/ is seeded from it on first run
# and must never be overwritten by an upgrade.
cp -a -- src/lib src/engine src/plugins src/rules src/discovery src/export "$PAYLOAD/"
cp -a -- src/conf "$PAYLOAD/conf.default"
cp -a -- src/main.sh src/bootstrap.sh "$PAYLOAD/"
# third-party notices
mkdir -p -- "$PAYLOAD/third_party"
[[ -d repos/php2shell-detection ]] && cp -a -- repos/php2shell-detection/LICENSE "$PAYLOAD/third_party/LICENSE.Lexsah" 2>/dev/null || true
[[ -d repos/php-uploadprogress-waf ]] && cp -a -- repos/php-uploadprogress-waf/LICENSE "$PAYLOAD/third_party/LICENSE.break-the-build" 2>/dev/null || true
[[ -f third_party/NOTICE ]] && cp -a -- third_party/NOTICE "$PAYLOAD/third_party/NOTICE" || true

# ---- shellcheck (skip gracefully when absent) ----
if command -v shellcheck >/dev/null 2>&1; then
  echo "== shellcheck =="
  find src -name '*.sh' -print0 | xargs -0 -n1 shellcheck -x || true
else
  echo "shellcheck not installed; skipping (install for CI)"
fi

# ---- tests (bats or built-in runner) ----
echo "== tests =="
if command -v bats >/dev/null 2>&1; then
  bats tests/unit
else
  SRC="$PWD/src" bash tests/run_tests.sh
fi

# ---- file manifest: lets bootstrap.sh delete stale code on upgrade ----
(
  cd -- "$PAYLOAD" &&
    find . -type f -printf '%P\n' | LC_ALL=C sort >MANIFEST
)

# ---- makeself ----
if command -v makeself >/dev/null 2>&1; then
  echo "== makeself =="
  # --needroot: refuse to run without root before unpacking anything.
  # --target:   unpack straight into the install directory (no /tmp staging).
  makeself --sha256 --nox11 --noprogress --gzip --needroot --target "$INSTALL_DIR" \
    "$PAYLOAD" "$DIST/php2shell-monitor.sh" \
    "PHP2Shell Monitor $VERSION" ./bootstrap.sh
  sha256sum "$DIST/php2shell-monitor.sh" >"$DIST/php2shell-monitor.sh.sha256"
  echo "built: $DIST/php2shell-monitor.sh (installs into $INSTALL_DIR)"
else
  echo "makeself not installed; payload staged at $PAYLOAD (install: apt install makeself)"
  echo "fallback: dist/php2shell-monitor-raw.tar.gz"
  echo "          (sudo mkdir -p $INSTALL_DIR && sudo tar -xzf ... -C $INSTALL_DIR && sudo $INSTALL_DIR/bootstrap.sh)"
  tar -czf "$DIST/php2shell-monitor-raw.tar.gz" -C "$PAYLOAD" .
  sha256sum "$DIST/php2shell-monitor-raw.tar.gz" >"$DIST/php2shell-monitor-raw.tar.gz.sha256"
fi

rm -rf -- "$PAYLOAD"
echo "version: $VERSION"
