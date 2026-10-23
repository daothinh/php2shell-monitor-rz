#!/usr/bin/env bash
# auditd.sh - execve by web uid (P2S-021), .php writes (P2S-020) from audit log.
set -u
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_batch_common.sh"

plugin_name=auditd

AUDIT_UIDS='33|48|82|1012'   # www-data, apache, alpine php-fpm, cpanel nobody-ish

parse_audit_line() {
  local line=$1
  local ts
  ts=$(printf '%s' "$line" | grep -oP '(?<=audit\()[0-9.]+' | head -1)
  [[ -n $ts ]] && { ts=${ts%%.*}; ts=$(epoch_to_utc "$ts"); } || ts=""
  P2S_TS=${ts:-$(utc_now)}
  local rule=-
  local proctitle
  proctitle=$(printf '%s' "$line" | grep -oP 'proctitle=\K[0-9A-Fa-f]+' | head -1)
  local msg="$line"
  if [[ -n $proctitle ]]; then
    # hex decode for readable evidence
    local decoded
    decoded=$(printf '%s' "$proctitle" | xxd -r -p 2>/dev/null | tr -c '[:print:]' '?' | head -c 200)
    [[ -n $decoded ]] && msg="$msg proc=$decoded"
  fi
  case $line in
    *type=EXECVE*|*'syscall=execve'*)
      if printf '%s' "$line" | grep -P "uid=($AUDIT_UIDS)\b" >/dev/null 2>&1; then
        rule=P2S-021
      fi
      ;;
    *type=PATH*)
      if printf '%s' "$line" | grep -P "uid=($AUDIT_UIDS)\b" >/dev/null 2>&1 &&
         printf '%s' "$line" | grep -P 'name=.*\.(php|phtml|phar|php5|inc|user\.ini|htaccess)' >/dev/null 2>&1; then
        rule=P2S-020
      fi
      ;;
  esac
  [[ $rule == - ]] && return 0
  emit_record auditd "" "" "" "" "" "" "$(printf '%s' "$line" | grep -oP 'pid=\K[0-9]+' | head -1)" "" "" "$rule" "$msg"
}

plugin_run() {
  local f=${AUDIT_LOG:-/var/log/audit/audit.log}
  [[ -f $f && -r $f ]] || { printf 'auditd\tmissing\tok\t-\n'; return 0; }
  batch_read "$f" parse_audit_line
}

plugin_run
exit 0
