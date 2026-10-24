#!/usr/bin/env bash
# auditd.sh - execve by web uid and .php writes, straight from the audit log.
# The raw audit line is preserved verbatim; the decoded proctitle is appended
# so an analyst can read the command without decoding hex by hand.
set -u
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/_batch_common.sh"

plugin_name=auditd
export plugin_name

AUDIT_UIDS='33|48|82|1012'   # www-data, apache, alpine php-fpm, cpanel nobody-ish

parse_audit_line() {
  local line=$1 ts proctitle decoded msg
  ts=$(printf '%s' "$line" | grep -oP '(?<=audit\()[0-9.]+' | head -1)
  if [[ -n $ts ]]; then
    ts=${ts%%.*}
    ts=$(epoch_to_utc "$ts")
  else
    ts=$(utc_now)
  fi
  P2S_TS=$ts; export P2S_TS

  case $line in
    *type=EXECVE*|*'syscall=execve'*|*type=PATH*) ;;
    *) return 0 ;;
  esac
  printf '%s' "$line" | grep -qP "uid=($AUDIT_UIDS)\b" || return 0

  msg=$line
  proctitle=$(printf '%s' "$line" | grep -oP 'proctitle=\K[0-9A-Fa-f]+' | head -1)
  if [[ -n $proctitle ]]; then
    decoded=$(printf '%s' "$proctitle" | xxd -r -p 2>/dev/null | tr -c '[:print:]' '?' | head -c 300)
    [[ -n $decoded ]] && msg="$msg proctitle_decoded=$decoded"
  fi

  emit_record auditd "$P2S_FILE" "$P2S_LINE" "" "" "" "" "" \
    "$(printf '%s' "$line" | grep -oP 'pid=\K[0-9]+' | head -1)" "$msg" "-"
}

f=${AUDIT_LOG:-/var/log/audit/audit.log}
[[ -f $f && -r $f ]] || exit 0
batch_read "$f" parse_audit_line
