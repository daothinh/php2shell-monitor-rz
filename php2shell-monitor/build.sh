#!/usr/bin/env bash
# build.sh - shellcheck + tests + makeself -> dist/php2shell-monitor.sh (+sha256)
# Runs on the BUILD machine only (needs makeself; target machine needs none).
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

VERSION=$(cat VERSION 2>/dev/null || echo "1.0.0")
DIST=dist
PAYLOAD=dist/payload

mkdir -p -- "$DIST"
rm -rf -- "$PAYLOAD"
mkdir -p -- "$PAYLOAD"

# ---- assemble payload (bootstrap expects lib/ engine/ plugins/ rules/
#      discovery/ export/ conf/ main.sh in its cwd) ----
cp -a -- src/lib src/engine src/plugins src/rules src/discovery src/export src/conf "$PAYLOAD/"
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

# ---- makeself ----
if command -v makeself >/dev/null 2>&1; then
  echo "== makeself =="
  makeself --sha256 --nox11 --noprogress --gzip "$PAYLOAD" "$DIST/php2shell-monitor.sh" \
    "PHP2Shell Monitor $VERSION" ./bootstrap.sh
  sha256sum "$DIST/php2shell-monitor.sh" >"$DIST/php2shell-monitor.sh.sha256"
  echo "built: $DIST/php2shell-monitor.sh"
else
  echo "makeself not installed; payload staged at $PAYLOAD (install: apt install makeself)"
  echo "fallback: dist/php2shell-monitor-raw.tar.gz (untar + 'sudo bash bootstrap.sh')"
  tar -czf "$DIST/php2shell-monitor-raw.tar.gz" -C "$PAYLOAD" .
  sha256sum "$DIST/php2shell-monitor-raw.tar.gz" >"$DIST/php2shell-monitor-raw.tar.gz.sha256"
fi

rm -rf -- "$PAYLOAD"
echo "version: $VERSION"
