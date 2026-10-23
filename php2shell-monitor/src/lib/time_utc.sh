#!/usr/bin/env bash
# time_utc.sh - normalize all timestamp shapes found in logs to UTC ISO8601.
# Sources: nginx/apache (with offset), FPM (no tz, server local), journald (local).
[[ -n ${P2S_TIME_SH:-} ]] && return 0
P2S_TIME_SH=1

# Convert "23/Oct/2026:10:12:00 +0700" (nginx/apache clf, already zoned) -> ISO UTC
t_apache_to_utc() {
  local s=${1-}
  [[ -z $s ]] && return 1
  local e
  e=$(date -u -d "$s" +%s 2>/dev/null) || return 1
  epoch_to_utc "$e"
}

# Convert "23-Oct-2026 10:12:00" / "2026-10-23 10:12:00" (FPM, local tz, no zone) -> ISO UTC
t_local_to_utc() {
  local s=${1-}
  [[ -z $s ]] && return 1
  local e
  e=$(date -d "$s" +%s 2>/dev/null) || return 1
  epoch_to_utc "$e"
}

# Parse the common nginx/apache combined log prefix timestamp.
# Input line -> ISO UTC; prints nothing when absent.
t_extract_access_ts() {
  local line=${1-}
  local m
  m=$(printf '%s' "$line" | grep -oP '\[\d{1,2}/[A-Za-z]{3}/\d{4}:\d{2}:\d{2}:\d{2} [+-]\d{4}\]' | head -1)
  [[ -z $m ]] && return 1
  m=${m:1:${#m}-2}
  t_apache_to_utc "$m"
}

# Parse FPM log prefix "[23-Oct-2026 10:12:00]" or "[23-Oct-2026 10:12:00.123456]"
t_extract_fpm_ts() {
  local line=${1-}
  local m
  m=$(printf '%s' "$line" | grep -oP '^\[\d{1,2}-[A-Za-z]{3}-\d{4} \d{2}:\d{2}:\d{2}' | head -1)
  [[ -z $m ]] && return 1
  t_local_to_utc "${m:1}"
}

# journalctl --output=short-iso timestamp "2026-10-23T10:12:00+0700"
t_extract_journal_ts() {
  local line=${1-}
  local m
  m=$(printf '%s' "$line" | grep -oP '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:[+-]\d{4}|Z)?' | head -1)
  [[ -z $m ]] && return 1
  local e
  e=$(date -d "$m" +%s 2>/dev/null) || return 1
  epoch_to_utc "$e"
}

# Generic: any "YYYY-MM-DD HH:MM:SS" (syslog without year handled by caller) -> epoch of today's year
t_syslog_to_utc() {
  local s=${1-}
  [[ -z $s ]] && return 1
  local e
  e=$(date -d "$s" +%s 2>/dev/null) || return 1
  epoch_to_utc "$e"
}

# syslog "Oct 23 10:12:00" (no year) -> use current year; bump back if in future.
t_syslog_noyear_to_utc() {
  local s=${1-}
  [[ -z $s ]] && return 1
  local year e now
  year=$(date -u +%Y); now=$(date -u +%s)
  e=$(date -d "$s $year" +%s 2>/dev/null) || return 1
  if (( e > now + 86400 )); then
    e=$(date -d "$s $((year - 1))" +%s 2>/dev/null) || return 1
  fi
  epoch_to_utc "$e"
}
