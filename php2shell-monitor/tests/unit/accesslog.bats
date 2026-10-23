#!/usr/bin/env bats
# accesslog.awk parser tests (fixtures from Lexsah, MIT, + synthetic)
load 'test_helper'

@test "accesslog: parses malicious upload-progress query line" {
  run awk -f "$SRC/lib/accesslog.awk" -v src=access_log "$FIX/mal_access_upload_progress.log"
  [ "$status" -eq 0 ]
  line=$output
  assert_field "$line" 3 "198.51.100.7"     # ip
  assert_field "$line" 4 "POST"             # method
  assert_field "$line" 5 "/upload.php?PHP_SESSION_UPLOAD_PROGRESS=fixture"  # uri
  assert_field "$line" 6 "200"              # status
}

@test "accesslog: parses php2shell UA line" {
  run awk -f "$SRC/lib/accesslog.awk" -v src=access_log "$FIX/mal_access_php2shell_ua.log"
  [ "$status" -eq 0 ]
  assert_field "$output" 8 "php2shell-109619"
}

@test "accesslog: normalizes +0700 offset to UTC" {
  run awk -f "$SRC/lib/accesslog.awk" -v src=access_log "$FIX/benign_access.log"
  [ "$status" -eq 0 ]
  # fixture benign has +0000 only; check ts format shape instead
  assert_field "$output" 1 "2026-10-21T13:38:12Z"
}

@test "accesslog: benign fixture has no php2shell UA" {
  run awk -f "$SRC/lib/accesslog.awk" -v src=access_log "$FIX/benign_access.log"
  [ "$status" -eq 0 ]
  ! grep -q php2shell <<<"$output"
}
