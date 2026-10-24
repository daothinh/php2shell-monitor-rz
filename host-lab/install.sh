#!/usr/bin/env bash
# install.sh — cài VICTIM host-lab trực tiếp lên host (không docker):
# nginx + PHP-FPM + app upload yếu, mọi log ở path CHUẨN /var/log/... dễ đọc.
#
# Chạy trên VPS với root:  bash install.sh
# An toàn: site CHỈ nghe 127.0.0.1:8088 — không lộ vuln ra Internet.
set -euo pipefail

WEBROOT=/var/www/php2shell-lab
PHPV=""

apt-get update -qq
apt-get install -yqq nginx >/dev/null

# PHP 8.2 (dòng bị CVE) qua PPA ondrej; nếu không được thì dùng PHP bản dist
if ! apt-cache show php8.2-fpm >/dev/null 2>&1; then
  apt-get install -yqq software-properties-common >/dev/null
  add-apt-repository -y ppa:ondrej/php >/dev/null
  apt-get update -qq
fi
if apt-cache show php8.2-fpm >/dev/null 2>&1; then PHPV=8.2; else PHPV=8.3; fi
apt-get install -yqq "php${PHPV}-fpm" >/dev/null
echo "PHP-FPM: ${PHPV}"

# ---- php.ini lab: session.upload_progress BẬT + memory_limit thật ----
cat >"/etc/php/${PHPV}/fpm/conf.d/99-php2shell-lab.ini" <<'EOF'
session.upload_progress.enabled = On
session.upload_progress.cleanup = On
session.upload_progress.prefix = "upload_progress_"
session.upload_progress.name = "PHP_SESSION_UPLOAD_PROGRESS"
session.upload_progress.freq = 1%
session.upload_progress.min_freq = 1
memory_limit = 128M
post_max_size = 256M
upload_max_filesize = 256M
log_errors = On
display_errors = Off
EOF

# ---- pool: 2 worker (VPS nhỏ) + error log riêng cho từng request ----
mkdir -p "/var/log/php${PHPV}-fpm"
cat >"/etc/php/${PHPV}/fpm/pool.d/zz-lab.conf" <<EOF
[www]
pm.max_children = 2
pm.start_servers = 1
pm.min_spare_servers = 1
pm.max_spare_servers = 1
catch_workers_output = yes
php_flag[log_errors] = on
php_admin_value[error_log] = /var/log/php${PHPV}-fpm/www-error.log
request_terminate_timeout = 30s
EOF

# ---- app ----
mkdir -p "$WEBROOT"
cp -a "$(dirname "$0")/app/." "$WEBROOT/"
echo '<?php /* shell do attacker drop (phase T3) se xuat hien o day */' > /dev/null

# ---- site nginx: loopback-only ----
cat >/etc/nginx/sites-available/php2shell-lab <<EOF
server {
    listen 127.0.0.1:8088;
    server_name _;
    root $WEBROOT;
    index index.php;
    access_log /var/log/nginx/php2shell-lab.access.log;
    error_log  /var/log/nginx/php2shell-lab.error.log warn;
    client_max_body_size 300M;
    location / { try_files \$uri \$uri/ =404; }
    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php${PHPV}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_read_timeout 60s;
    }
}
EOF
ln -sf /etc/nginx/sites-available/php2shell-lab /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl enable --now nginx "php${PHPV}-fpm" >/dev/null 2>&1 || true
systemctl reload nginx || systemctl restart nginx
systemctl restart "php${PHPV}-fpm"

sleep 1
echo "---- verify ----"
curl -s http://127.0.0.1:8088/ | grep -o '<title>.*</title>'
curl -s -X POST http://127.0.0.1:8088/upload.php | head -1; echo
echo "PHP: $(php${PHPV} -v | head -1)"
echo "upload_progress = $(php${PHPV} -r 'echo ini_get("session.upload_progress.enabled"),PHP_EOL;')"
echo "log: /var/log/nginx/php2shell-lab.access.log | /var/log/php${PHPV}-fpm/{fpm,www-error}.log | webroot: $WEBROOT"
