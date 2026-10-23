#!/usr/bin/env bash
# safe_fs.sh - workdir hardening + confined writes (plan 5.2, risk 8.1-10)
[[ -n ${P2S_SAFE_FS_SH:-} ]] && return 0
P2S_SAFE_FS_SH=1
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Validates a workdir: real dir, root-owned, mode 0700, no symlink components.
# Args: path. Returns 0 ok, 1 not-present, 2 unsafe.
workdir_check() {
  local d=${1:?dir}
  if [[ -L $d ]]; then
    printf 'unsafe: %s is a symlink\n' "$d" >&2; return 2
  fi
  if [[ ! -e $d ]]; then
    return 1
  fi
  if [[ ! -d $d ]]; then
    printf 'unsafe: %s is not a directory\n' "$d" >&2; return 2
  fi
  local st owner mode
  st=$(stat -c '%u %a' -- "$d" 2>/dev/null) || { printf 'unsafe: cannot stat %s\n' "$d" >&2; return 2; }
  owner=${st%% *}; mode=${st##* }
  if [[ $owner -ne 0 ]]; then
    printf 'unsafe: %s owner uid=%s (must be root)\n' "$d" "$owner" >&2; return 2
  fi
  if [[ $mode != 700 && $mode != 0700 ]]; then
    printf 'unsafe: %s mode=%s (must be 0700)\n' "$d" "$mode" >&2; return 2
  fi
  # parent chain must not be a symlink (e.g. /tmp/php2shell-monitor via link)
  local parent
  parent=$(dirname -- "$d")
  if [[ -L $parent ]]; then
    printf 'unsafe: parent %s is a symlink\n' "$parent" >&2; return 2
  fi
  return 0
}

# Create or validate the workdir strictly.
workdir_init() {
  local d=${1:?dir}
  if ! workdir_check "$d"; then
    local rc=$?
    if [[ $rc -eq 1 ]]; then
      (umask 077 && mkdir -m 0700 -- "$d") || return 3
      workdir_check "$d" >/dev/null || return 3
    else
      return 2
    fi
  fi
  return 0
}

# Ensure a directory lives strictly inside WORKDIR (no symlink escape).
safe_mkdir() {
  local rel=${1:?relpath}
  local target="$WORKDIR/$rel"
  case $target in
    "$WORKDIR"/*) ;;
    *) printf 'refusing path outside workdir: %s\n' "$target" >&2; return 2 ;;
  esac
  if [[ -L $target ]]; then
    printf 'refusing symlinked dir: %s\n' "$target" >&2; return 2
  fi
  if [[ -e $target && ! -d $target ]]; then
    printf 'refusing non-dir: %s\n' "$target" >&2; return 2
  fi
  [[ -d $target ]] || (umask 077 && mkdir -m 0700 -p -- "$target") || return 3
  return 0
}

# Write content atomically inside workdir: safe_write <relpath>, stdin.
safe_write() {
  local rel=${1:?relpath}
  local target="$WORKDIR/$rel" tmp
  case $target in "$WORKDIR"/*) ;; *) return 2 ;; esac
  tmp="$target.tmp.$$"
  (umask 077 && cat >"$tmp") || return 3
  mv -f -- "$tmp" "$target" || return 3
  chmod 0600 -- "$target" 2>/dev/null
  return 0
}

# Append a line inside workdir with 0600.
safe_append() {
  local rel=${1:?relpath}
  local target="$WORKDIR/$rel"
  case $target in "$WORKDIR"/*) ;; *) return 2 ;; esac
  (umask 077 && printf '%s\n' "$2" >>"$target") || return 3
}

# Enforce size caps for monitor-owned dirs (alerts, export, run, tmp).
enforce_caps() {
  local total_mb=${CAP_TOTAL_MB:-200} keep_days=${CAP_KEEP_DAYS:-7}
  local d
  for d in "$P2S_ALERT_DIR" "$P2S_EXPORT_DIR" "$P2S_TMP_DIR"; do
    [[ -d $d ]] || continue
    find "$d" -type f -mtime "+$keep_days" -delete 2>/dev/null
  done
  local used_kb
  used_kb=$(du -sk -- "$WORKDIR" 2>/dev/null | awk '{print $1}')
  [[ -z $used_kb ]] && return 0
  if (( used_kb > total_mb * 1024 )); then
    # Rotate alert queue by dropping oldest half rather than touching state/conf.
    local q="$P2S_ALERT_DIR/queue.jsonl"
    if [[ -f $q ]]; then
      local lines keep
      lines=$(wc -l <"$q")
      keep=$((lines / 2))
      tail -n "$keep" "$q" >"$q.tmp.$$" && mv -f "$q.tmp.$$" "$q"
      log_warn "cap exceeded (${used_kb}KB); rotated alert queue to $keep lines"
    fi
  fi
}
