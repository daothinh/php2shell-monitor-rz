#!/usr/bin/env bats
# accesslog.awk parser tests (fixtures from Lexsah, MIT, + synthetic)
# Field layout: ts source file line ip method uri status ua pid msg rule

SRC=${SRC:-/opt/php2shell-monitor}
FIX=$(cd "$(dirname "${BASH_SOURCE[0]}")/../fixtures" && pwd)

assert_field() { # <tsv-line> <n> <expected>
  local got
  got=$(printf '%s' "$1" | awk -F'\t' -v n="$2" 'NR==1 { print $n }')
  [[ $got == "$3" ]]
}

@test "accesslog: parses malicious upload-progress query line" {
  run awk -f "$SRC/lib/accesslog.awk" -v src=access_log "$FIX/mal_access_upload_progress.log"
  [ "$status" -eq 0 ]
  assert_field "$output" 5 "198.51.100.7"
  assert_field "$output" 6 "POST"
  assert_field "$output" 7 "/index.php?PHP_SESSION_UPLOAD_PROGRESS=track"
  assert_field "$output" 8 "200"
}

@test "accesslog: records the source file and line number" {
  run awk -f "$SRC/lib/accesslog.awk" -v src=access_log "$FIX/mal_access_php2shell_ua.log"
  [ "$status" -eq 0 ]
  assert_field "$output" 3 "mal_access_php2shell_ua.log"
  assert_field "$output" 4 "1"
}

@test "accesslog: keeps the raw line as evidence" {
  run awk -f "$SRC/lib/accesslog.awk" -v src=access_log "$FIX/mal_access_php2shell_ua.log"
  [ "$status" -eq 0 ]
  [[ $(printf '%s' "$output" | cut -f11) == *"POST /index.php"* ]]
}

@test "accesslog: parses php2shell UA line" {
  run awk -f "$SRC/lib/accesslog.awk" -v src=access_log "$FIX/mal_access_php2shell_ua.log"
  [ "$status" -eq 0 ]
  assert_field "$output" 9 "php2shell-109619"
}

@test "accesslog: normalizes timestamp to UTC" {
  run awk -f "$SRC/lib/accesslog.awk" -v src=access_log "$FIX/benign_access.log"
  [ "$status" -eq 0 ]
  assert_field "$output" 1 "2026-10-21T13:38:12Z"
}

@test "accesslog: benign fixture has no php2shell UA" {
  run awk -f "$SRC/lib/accesslog.awk" -v src=access_log "$FIX/benign_access.log"
  [ "$status" -eq 0 ]
  [[ $(printf '%s\n' "$output" | cut -f9) != *php2shell* ]]
}
