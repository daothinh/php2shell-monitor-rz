# Host Lab — victim PHP bị CVE cài TRỰC TIẾP lên host (không docker)

Theo yêu cầu: **không docker** — nginx + PHP-FPM chạy như service thật của VPS, mọi dữ liệu ở **path chuẩn dễ đọc**:

```
/var/log/nginx/php2shell-lab.access.log      ← access log thật (nginx ghi)
/var/log/nginx/php2shell-lab.error.log       ← upstream/502 thật
/var/log/php<ver>-fpm/www-error.log          ← "Allowed memory size exhausted" thật
/var/log/php<ver>-fpm/fpm.log                ← worker exit/signal
/var/www/php2shell-lab/                      ← webroot — webshell drop hiện tại đây
/var/lib/php2shell-monitor/                  ← workdir monitor
        └── alerts/queue.jsonl               ← alert queue (đọc trực tiếp được)
```

## Kiến trúc (tất cả trên một VPS)

```
attack.sh (máy bạn, qua ssh -L tunnel)
   │ HTTP thật
   ▼
nginx + PHP-FPM (host service, 127.0.0.1:8088 — không lộ ra mạng)
   │ log chuẩn /var/log/...
   ▼
monitor.sh (engine php2shell-monitor, batch 10s, đọc log thật)
   │ /var/lib/php2shell-monitor/alerts/queue.jsonl
   ▼
p2s-agent.sh → central server (localhost:8000, docker) → 📱 Telegram group
```

## Triển khai (một lần)

```bash
# từ repo local, đẩy host-lab + src engine + agent lên VPS
rsync -az host-lab/ root@<vps>:/opt/host-lab/
rsync -az php2shell-monitor/src/ root@<vps>:/opt/php2shell-monitor-src/
rsync -az central-alert-server/client/p2s-agent.sh root@<vps>:/usr/local/bin/
ssh root@<vps> 'chmod +x /usr/local/bin/p2s-agent.sh'

# cài victim (nginx + php-fpm + app) trực tiếp lên host
ssh root@<vps> 'bash /opt/host-lab/install.sh'
```

## Ghép nối alert về Telegram (một lần)

```bash
ssh root@<vps> 'P2S_AGENT_CONF=/etc/php2shell/agent.conf /usr/local/bin/p2s-agent.sh \
    pair --server http://127.0.0.1:8000 --chatid <chat-id-group>'
# -> bot gửi yêu cầu vào group → nhắn /confirm trong group
```

## Vận hành hằng ngày

```bash
ssh root@<vps> 'bash /opt/host-lab/monitor.sh start'    # monitor + agent chạy nền
ssh root@<vps> 'bash /opt/host-lab/monitor.sh status'
ssh root@<vps> 'bash /opt/host-lab/monitor.sh stop'

# ĐÁNH THẬT từ máy bạn (qua tunnel, vuln không lộ Internet):
ssh -L 8088:127.0.0.1:8088 -fN root@<vps>
bash host-lab/attack.sh                     # T1 -> T2 -> T3
bash host-lab/attack.sh http://127.0.0.1:8088 --t2   # riêng phase T2
```

Xem Telegram nhận alert theo phase; đọc dữ liệu thẳng trên VPS bằng path chuẩn ở đầu trang.

## Tín hiệu thật vs mô phỏng

| Phase | Thật | Ghi chú |
|---|---|---|
| T1 | ✅ request + access-log nginx ghi | curl như tool thật |
| T2 | ✅ PHP Fatal OOM thật (POST ~110MB > memory_limit 128M), 502/upstream reset khi pool 2 worker kiệt | không ghi log giả |
| T3 | ✅ webshell upload thật qua upload.php yếu, system() chạy thật, file nằm /var/www/php2shell-lab | full kill-chain |
| P2S-011 SIGSEGV/UAF | ❌ không kích được bằng HTTP thuần | giới hạn trung thực của lab |

## Dọn dẹp

```bash
ssh root@<vps> 'bash /opt/host-lab/monitor.sh stop; apt-get purge -y "php*fpm" nginx; \
  rm -rf /var/www/php2shell-lab /var/lib/php2shell-monitor /opt/host-lab'
```
