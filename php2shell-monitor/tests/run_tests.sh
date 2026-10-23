#!/usr/bin/env bash
# run_tests.sh - bats-less test runner (bats preferred when installed).
# Executes the same assertions via inline bash so CI/build works everywhere.
set -u
SRC=${SRC:-/tmp/php2shell-monitor}
FIX="$(cd "$(dirname "${BASH_SOURCE[0]}")/fixtures" && pwd)"
PASS=0; FAIL=0

fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
pass() { echo "pass: $1"; PASS=$((PASS+1)); }

field() { printf '%s' "$1" | awk -F'\t' -v n="$2" 'NR==1 { print $n }'; }

T() { # <name> <expected-substr> <actual>
  if [[ $3 == *"$2"* ]]; then pass "$1"; else fail "$1 (missing: $2)"; fi
}
rule_match_stream() {
  local stream=$1 w
  w=$(mktemp -d)
  mkdir -p "$w/rules/pack" "$w/conf" "$w/state"
  printf 'proc\nauditd\naccess_log\nfpm_error\njournal\nsessions\n' >"$w/state/capabilities.txt"
  cp -a "$SRC/rules/pack/." "$w/rules/pack/" 2>/dev/null
  WORKDIR=$w P2S_SRC_DIR=$SRC bash "$SRC/engine/rule_match.sh" "$stream" 2>/dev/null
  rm -rf -- "$w"
}
N() { # <name> <not-expected> <actual>
  if [[ $3 != *"$2"* ]]; then pass "$1"; else fail "$1 (unexpected: $2)"; fi
}

# ---------- accesslog.awk ----------
out=$(awk -f "$SRC/lib/accesslog.awk" -v src=access_log "$FIX/mal_access_upload_progress.log")
T "parser: ip"          "198.51.100.7" "$(field "$out" 3)"
T "parser: method"      "POST"         "$(field "$out" 4)"
T "parser: uri marker"  "PHP_SESSION_UPLOAD_PROGRESS" "$(field "$out" 5)"
T "parser: status"      "200"          "$(field "$out" 6)"
T "parser: ts normalized" "2026-10-21T13:38:12Z" "$(field "$out" 1)"

out=$(awk -f "$SRC/lib/accesslog.awk" -v src=access_log "$FIX/mal_access_php2shell_ua.log")
T "parser: ua"          "php2shell-109619" "$(field "$out" 8)"

out=$(awk -f "$SRC/lib/accesslog.awk" -v src=access_log "$FIX/benign_access.log")
N "parser: benign has no php2shell" "php2shell" "$out"

# 500-burst parses
out=$(awk -f "$SRC/lib/accesslog.awk" -v src=access_log "$FIX/mal_500_burst.log")
T "parser: 500 status" "500" "$(field "$out" 6)"

# ---------- rule_match ----------
stream=$(mktemp)
awk -f "$SRC/lib/accesslog.awk" -v src=access_log "$FIX/mal_access_php2shell_ua.log" >>"$stream"
out=$(rule_match_stream "$stream")
T "rules: P2S-008 UA hit"        "P2S-008" "$out"

stream=$(mktemp)
awk -f "$SRC/lib/accesslog.awk" -v src=access_log "$FIX/mal_access_upload_progress.log" >>"$stream"
out=$(rule_match_stream "$stream")
T "rules: P2S-017 marker hit"    "P2S-017" "$out"

stream=$(mktemp)
for i in 1 2 3 4 5; do
  printf '2026-10-2%dT10:1%d:00Z\tfpm_error\t\t\t\t\t\t\t\t\t\tP2S-010\tPHP Fatal error:  Allowed memory size of 134217728 bytes exhausted\n' "$i" "$i" >>"$stream"
done
out=$(rule_match_stream "$stream")
T "rules: P2S-010 memory"        "P2S-010" "$out"

stream=$(mktemp)
printf '2026-10-21T10:13:00Z\tapache_error\t\t\t\t\t\t999\t\t\t\tP2S-011\tAH00052: child pid 4242 exit signal Segmentation fault (11)\n' >>"$stream"
out=$(rule_match_stream "$stream")
T "rules: P2S-011 segfault"      "P2S-011" "$out"

stream=$(mktemp)
printf '2026-10-21T10:00:00Z\taccess_log\t1.2.3.4\tGET\t/uploads/sh.php?cmd=whoami\t200\t0\tcurl/8.5.0\t\t\t\t-\tGET /uploads/sh.php?cmd=whoami 200\n' >>"$stream"
out=$(rule_match_stream "$stream")
T "rules: P2S-030 webshell cmd"  "P2S-030" "$out"

stream=$(mktemp)
printf '2026-10-21T10:00:00Z\tproc\t\t\t\t\t\t4242\t\t\t\t-\tsuspicious cmdline: bash -c /dev/tcp/1.2.3.4/4444 (parent=php-fpm8.2)\n' >>"$stream"
out=$(rule_match_stream "$stream")
T "rules: P2S-025 revshell"      "P2S-025" "$out"

stream=$(mktemp)
printf '2026-10-21T10:00:00Z\taccess_log\t1.2.3.4\tGET\t/\t200\t0\tMozilla/5.0\t\t\t\t-\tGET / 200\n' >>"$stream"
out=$(rule_match_stream "$stream")
N "rules: benign line silent"    "P2S-" "$out"

stream=$(mktemp)
awk -f "$SRC/lib/accesslog.awk" -v src=access_log "$FIX/benign_access.log" >>"$stream"
out=$(rule_match_stream "$stream")
N "rules: benign fixture silent" "P2S-" "$out"

# ---------- JSON emission sanity ----------
stream=$(mktemp)
awk -f "$SRC/lib/accesslog.awk" -v src=access_log "$FIX/mal_access_php2shell_ua.log" >>"$stream"
w=$(mktemp -d); mkdir -p "$w/rules/pack" "$w/conf" "$w/state"; cp -a "$SRC/rules/pack/." "$w/rules/pack/"
printf 'proc\nauditd\naccess_log\nfpm_error\njournal\nsessions\n' >"$w/state/capabilities.txt"
WORKDIR=$w P2S_SRC_DIR=$SRC bash "$SRC/engine/rule_match.sh" "$stream" >"$w/m.jsonl" 2>/dev/null
if command -v jq >/dev/null; then
  if jq -e 'select(.rule == "P2S-008") | .ts and .src_ip and .ua' "$w/m.jsonl" >/dev/null 2>&1; then
    pass "json: event object valid"
  else
    fail "json: event object invalid"
  fi
fi
rm -rf -- "$w"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
