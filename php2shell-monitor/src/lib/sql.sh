#!/usr/bin/env bash
# sql.sh - SQL (portable .sql file) escaping helpers. No DB client dependency.
[[ -n ${P2S_SQL_SH:-} ]] && return 0
P2S_SQL_SH=1

# Escape a value for a single-quoted SQL string literal.
sql_escape() {
  local s=${1-}
  # Standard SQL: only single quotes need doubling. Backslashes are literal in
  # Postgres and in MySQL with NO_BACKSLASH_ESCAPES; note in file header.
  s=${s//\'/\'\'}
  s=${s//$'\n'/ }
  s=${s//$'\r'/ }
  printf '%s' "$s"
}

sql_str() {
  local v=${1-}
  if [[ -z $v ]]; then
    printf 'NULL'
  else
    printf "'%s'" "$(sql_escape "$v")"
  fi
}

sql_num() {
  local v=${1-}
  if [[ $v =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
    printf '%s' "$v"
  else
    printf 'NULL'
  fi
}
