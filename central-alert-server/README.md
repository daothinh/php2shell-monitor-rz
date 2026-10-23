# Central Security Alert Server

Server trung tâm tiếp nhận **alert bảo mật real-time** (php2shell-monitor và bất kỳ log bất thường nào khác) từ các server dự án của khách hàng, rồi **bắn cảnh báo tức thì về Telegram** của đúng người phụ trách dự án đó — dùng chung **một bot duy nhất của hệ thống**.

| | |
|---|---|
| **Backend** | Python 3.11+ · FastAPI · Uvicorn (async) |
| **Database** | SQLite (WAL mode) — 3 bảng: `projects`, `pairing_codes`, `alerts_log` |
| **Telegram** | 1 bot trung tâm, chế độ **long-polling** (không cần public webhook) |
| **Client agent** | Bash thuần (`p2s-agent.sh`) — chỉ cần `curl` |
| **Triển khai** | Docker Compose / bare-metal, TLS qua reverse proxy (Caddy/nginx) |

---

## 1. Bài toán & mô hình

Nhiều server dự án của khách hàng chạy php2shell-monitor (phát hiện khai thác CVE-2026-109618/109619 — PHP session upload-progress memory exhaustion & UAF). Cần một nơi tập trung:

- nhận alert từ tất cả các server này,
- định danh **mỗi dự án ↔ đúng một chat Telegram** của khách,
- cảnh báo tức thì, không bắt khách hàng tự tạo bot hay nắm token.

```
[Server Dự Án (p2s-agent.sh)]           [Central Server + SQLite]         [Telegram Bot & User]
        |                                       |                                |
 1. agent pair --name X --server URL            |                                |
        |---- POST /register-pairing ---------->|                                |
        |<------ mã "SEC-3F2504E0-4F89-41D3-9A0C-0305E82C3301" (10 phút) ---|                                |
 2. In mã ra terminal                           |                                |
    "Gửi mã SEC-<UUID> tới @Bot"                  |     3. User nhắn mã cho bot    |
        |                                       |<------- "SEC-3F2504E0-4F89-41D3-9A0C-0305E82C3301" ---|
        |                                       |  bot lấy chat_id, sinh api_key |
        |                                       |------ "Ghép nối thành công" -->|
 4. agent poll /pairing-status                  |                                |
        |<------ status=linked + api_key -------|                                |
 5. Monitor phát hiện webshell / log bất thường |                                |
        |---- POST /ingest-log (X-API-Key) ---->|                                |
        |                                       |--- 6. Bắn alert tức thì ------>|
```

**Nguyên tắc thiết kế**

- API key 256-bit, server **chỉ lưu SHA-256 hash** — lộ DB không lộ key.
- Mã pairing dùng một lần, sống 10 phút, chống dò (xem §7).
- At-least-once delivery: alert gửi Telegram lỗi vẫn lưu lại (`delivered=0`), agent spool khi mất mạng và tự gửi lại.
- Zero-dependency phía khách hàng: bash + curl là đủ.

---

## 2. Cấu trúc mã nguồn

```
central-alert-server/
├── server/
│   ├── app/
│   │   ├── main.py          # FastAPI app + lifespan (init DB, bot task, cleanup task 15')
│   │   ├── config.py        # cấu hình từ biến môi trường / file .env
│   │   ├── db.py            # SQLite: schema + toàn bộ truy vấn
│   │   ├── security.py      # sinh api_key/mã pairing, RateLimiter, AttemptGuard
│   │   ├── telegram.py      # PairingBot (polling) + TelegramClient (gửi, obey 429) + formatter
│   │   └── routes.py        # 5 endpoint API
│   ├── requirements.txt     # fastapi, uvicorn[standard], httpx
│   ├── Dockerfile
│   ├── docker-compose.yml
│   └── .env.example         # mẫu cấu hình (copy thành .env)
└── client/
    ├── p2s-agent.sh         # agent: pair | run | test
    └── p2s-agent.service    # systemd unit mẫu
```

---

## 3. Cài đặt Central Server

### 3.1. Tạo bot trung tâm (làm MỘT lần cho toàn hệ thống)

1. Telegram → nhắn **@BotFather** → `/newbot`.
2. Đặt tên, ví dụ `php2shell_alert_bot` → nhận `BOT_TOKEN` (dạng `123456789:AA...`).
3. *(Khuyến nghị)* `/setjoingroups` → Disable, `/setprivacy` → Enable để bot không bị spam nhóm.

### 3.2. Chạy bằng Docker (khuyến nghị)

```bash
cd server
cp .env.example .env       # điền ALERT_BOT_TOKEN (bắt buộc), ALERT_ADMIN_TOKEN (nên có)
chmod 600 .env
docker compose up -d       # lắng nghe :8000, DB tại ./data/alerts.db (volume)
docker compose logs -f     # xem log pairing + gửi alert
```

### 3.3. Chạy bare-metal

```bash
cd server
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
set -a; source .env; set +a
.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000
```

### 3.4. Ra internet: bắt buộc TLS

Uvicorn chỉ nghe `127.0.0.1`; đặt reverse proxy phía trước. **Caddy** (tự cấp Let's Encrypt):

```
alert.example.com {
    reverse_proxy 127.0.0.1:8000
}
```

**nginx** tương đương:

```nginx
server {
    listen 443 ssl http2;
    server_name alert.example.com;
    ssl_certificate     /etc/letsencrypt/live/alert.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/alert.example.com/privkey.pem;
    client_max_body_size 2m;
    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Host $host;
    }
}
```

Server đọc IP client từ `X-Forwarded-For` (dùng cho rate-limit đăng ký pairing).

### 3.5. Biến môi trường

| Biến | Bắt buộc | Mặc định | Ý nghĩa |
|---|---|---|---|
| `ALERT_BOT_TOKEN` | ✅ | — | Token bot trung tâm từ @BotFather. Bỏ trống = bot tắt, chỉ API chạy (dev) |
| `ALERT_ADMIN_TOKEN` | nên có | — | Bật `POST /api/v1/admin/link` (ghép nối thủ công). Sinh: `openssl rand -hex 16` |
| `ALERT_DB_PATH` | | `data/alerts.db` | Đường dẫn SQLite |
| `ALERT_PAIRING_TTL_SEC` | | `600` | Thời gian sống mã pairing |
| `ALERT_REVEAL_TTL_SEC` | | `600` | Cửa sổ lấy lại api_key sau khi linked (polled lại) |
| `ALERT_MAX_ALERTS_PER_REQUEST` | | `50` | Số alert tối đa / request ingest (dư thừa bị cắt) |
| `ALERT_INGEST_RATE_PER_MIN` | | `120` | Rate-limit ingest theo api_key |
| `ALERT_REGISTER_RATE_PER_HOUR` | | `30` | Rate-limit đăng ký pairing theo IP |
| `ALERT_BOT_POLLING` | | `1` | `0` = tắt bot polling |
| `ALERT_BOT_ATTEMPTS_LIMIT/WINDOW/MUTE` | | `5 / 600 / 600` | Chống dò mã: sai N lần trong W giây → khoá chat M giây |
| `ALERT_DISPLAY_TZ` | | `Asia/Ho_Chi_Minh` | Múi giờ hiển thị thời gian trong alert |

---

## 4. Database

```sql
projects (
  id, project_name,                     -- dự án của khách
  api_key_hash UNIQUE,                  -- sha256(api_key) — KHÔNG lưu plaintext
  status,                               -- pending | linked | disabled
  telegram_chat_id,                     -- chat nhận alert (bot ghi khi pairing)
  created_at, linked_at
)

pairing_codes (
  code PK,                              -- SEC-<UUID> (uuid4)
  project_id → projects.id,
  api_key_plain,                        -- tiết lộ cho agent 1 cửa sổ 10' rồi bị dọn
  revealed_at, created_at, expires_at, used_at
)

alerts_log (
  id, project_id,
  rule_id, severity, host, message,     -- bản rút gọn cho truy vấn sau này
  delivered,                            -- 1/0: đã đẩy Telegram thành công?
  received_at
)
```

Tác vụ dọn dẹp chạy mỗi 15 phút: xoá pairing code hết hạn >24h, xoá `api_key_plain` 10 phút sau khi tiết lộ.

---

## 5. API — tài liệu đầy đủ

Số liệu dưới đây là **phản hồi thật** lấy từ phiên kiểm thử E2E. Sau khi chạy server, `/docs` (Swagger UI) cũng có sẵn tự động.

### 5.1. `POST /api/v1/register-pairing` — xin mã ghép nối

```bash
curl -s -X POST https://alert.example.com/api/v1/register-pairing \
  -H 'Content-Type: application/json' \
  -d '{"project_name": "khach-hang-A"}'
```

```json
{"code":"SEC-3F2504E0-4F89-41D3-9A0C-0305E82C3301","expires_in":600,"expires_at":"2026-10-23T14:58:42Z",
 "instruction":"Gửi mã SEC-3F2504E0-4F89-41D3-9A0C-0305E82C3301 cho bot Telegram để hoàn tất ghép nối"}
```

- `project_name`: 1-64 ký tự (chữ/số/._-@, tiếng Việt, khoảng trắng).
- Giới hạn 30 lần/giờ/IP (tránh dồn DB).

### 5.2. Bot nhận mã (tự động, người dùng thao tác)

User mở Telegram nhắn đúng mã `SEC-3F2504E0-4F89-41D3-9A0C-0305E82C3301` cho bot (copy từ terminal). Bot xác thực (tồn tại – chưa dùng – chưa hết hạn) rồi:

- lưu `chat_id` vào project, sinh `api_key` (hash + bản plaintext chờ agent lấy),
- trả lời user: **"✅ Ghép nối thành công! 📦 Dự án: khach-hang-A ..."**.

Sai mã → bot trả lời lý do (không tồn tại / đã dùng / hết hạn). Sai 5 lần trong 10 phút → chat bị khoá 10 phút.

### 5.3. `GET /api/v1/pairing-status?code=SEC-3F2504E0-4F89-41D3-9A0C-0305E82C3301` — agent poll

```json
{"status":"pending","project_name":"khach-hang-A"}
```

Khi user đã gửi mã cho bot (agent lần đầu poll sau đó):

```json
{"status":"linked","project_name":"khach-hang-A",
 "api_key":"p2s_hift3RD_JcpN1ptlWdm2-sHAY1yVkiJ338FM8QAXSLM"}
```

`api_key` chỉ được trả trong **10 phút** sau khi linked (cửa sổ reveal); sau đó vẫn trả `status=linked` nhưng không còn key.

### 5.4. `POST /api/v1/ingest-log` — đẩy alert (endpoint nóng)

Auth: header `X-API-Key: <api_key>` hoặc `Authorization: Bearer <api_key>`.

```bash
curl -s -X POST https://alert.example.com/api/v1/ingest-log \
  -H "X-API-Key: $API_KEY" -H 'Content-Type: application/json' \
  -d '{
    "host": "webserver01",
    "alerts": [
      {"ts_utc":"2026-10-23T14:55:01Z","host":"webserver01","rule_id":"P2S-011",
       "tier":"T2","severity":"CRITICAL",
       "src_ip_candidates":[{"ip":"203.0.113.42","score":3,"via":"direct"}],
       "uri":"/upload.php",
       "evidence":[{"source":"fpm_error","file":"/var/log/php8.2-fpm.log",
                    "msg":"child 4242 exited on signal 11"}],
       "notes":"php-fpm worker segfault"},
      {"rule_id":"P2S-030","severity":"HIGH","message":"webshell cmd=whoami",
       "uri":"/shell.php?cmd=whoami","src_ip":"203.0.113.42"}
    ]
  }'
```

```json
{"accepted":2,"messages":1,"delivered":1}
```

- `accepted`: số alert đã nhận vào `alerts_log`; `messages`: số tin Telegram (nhiều alert **được gộp** thành tin ≤3900 ký tự); `delivered`: số tin gửi thành công.
- Lỗi gửi Telegram (mất mạng tới api.telegram.org…): alert vẫn lưu với `delivered=0`, response kèm `"warning"` — không mất alert.
- Mã lỗi: `401` key sai/chưa ghép nối · `409` dự án chưa có chat_id · `422` body sai · `429` vượt 120 request/phút.

**Trường alert formatter hiểu** (tất cả đều tuỳ chọn, schema linh hoạt): `rule_id`, `severity` (CRITICAL/HIGH/MEDIUM/LOW/INFO), `tier`, `host`, `uri`, `src_ip` hoặc `src_ip_candidates[]` (php2shell-monitor), `message`/`notes` (fallback `evidence[0].msg`), `ts_utc`/`ts` (ISO8601, hiển thị theo `ALERT_DISPLAY_TZ`).

Ví dụ tin Telegram thật (HTML render):

```
🛡 Central Security Alert
🚨 CRITICAL · P2S-011 [T2] — webserver01
🔗 /upload.php
👤 IP: 203.0.113.42 (ứng viên, 3 hit)
📝 child 4242 exited on signal 11
🕒 23/10 21:55:01 (Ho Chi Minh)
📦 Dự án: khach-hang-A
```

### 5.5. `POST /api/v1/admin/link` — ghép nối thủ công (dev/ops)

Chỉ bật khi có `ALERT_ADMIN_TOKEN`. Dùng khi cần link chat_id mà không qua tin nhắn bot (kiểm thử, sự cố bot):

```bash
curl -s -X POST https://alert.example.com/api/v1/admin/link \
  -H "X-Admin-Token: $ALERT_ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"code":"SEC-3F2504E0-4F89-41D3-9A0C-0305E82C3301","chat_id":"555000111"}'
# → {"status":"linked","project_id":1,"project_name":"khach-hang-A"}
```

### 5.6. `GET /api/v1/healthz`

```json
{"ok":true,"bot":"polling","projects":2,"time_utc":"2026-10-23T14:56:40Z"}
```

---

## 6. Client Agent — cài trên server dự án

Yêu cầu: bash 4+, curl (`jq` tuỳ chọn — có fallback). Không cần root nếu đổi đường dẫn qua biến môi trường.

```bash
# 1. Ghép nối (MỘT lần) — in mã ra terminal, user gửi mã cho bot
sudo ./p2s-agent.sh pair --name khach-hang-A --server https://alert.example.com

# 2. Kiểm tra đường truyền — alert thử phải hiện trên Telegram
sudo ./p2s-agent.sh test

# 3. Chạy thường trực — đọc /tmp/php2shell-monitor/alerts/queue.jsonl
sudo ./p2s-agent.sh run
```

Cài thành service:

```bash
sudo cp p2s-agent.sh /usr/local/bin/
sudo cp p2s-agent.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now p2s-agent
journalctl -u p2s-agent -f
```

**Cơ chế `run` (at-least-once):**

- Theo dõi file alert bằng **offset theo inode** — không gửi trùng khi log rotate; khi inode đổi (file mới) đọc lại từ đầu file mới.
- Chỉ nhận dòng JSON hợp lệ; batch tối đa 20 dòng/request.
- **Mất mạng → spool xuống đĩa** (`$STATE_DIR/spool/pending.jsonl`) → chu kỳ sau gửi spool trước (FIFO).
- Poll mỗi 5 giây (đổi qua `P2S_AGENT_POLL`).

**File & biến:**

| | Mặc định | Ghi chú |
|---|---|---|
| `P2S_AGENT_CONF` | `/etc/php2shell/agent.conf` | `SERVER_URL`, `API_KEY`, `PROJECT_NAME`; mode 0600 |
| `P2S_AGENT_STATE` | `/var/lib/php2shell-agent` | offset + spool |
| `P2S_ALERT_FILE` | `/tmp/php2shell-monitor/alerts/queue.jsonl` | output queue của php2shell-monitor |
| `P2S_AGENT_POLL` | `5` | giây giữa các chu kỳ |

---

## 7. Bảo mật

| Lớp | Cơ chế |
|---|---|
| Auth client | API key 256-bit (`p2s_` + 43 ký tự); server chỉ lưu **SHA-256**; tra cứu theo hash |
| Pairing | Mã **UUID** (`SEC-<uuid4>`, 122-bit entropy — không thể dò), TTL 10 phút, **single-use**; bot giới hạn 5 lần sai/10 phút/chat (khoá 10 phút) |
| Rate-limit | 30 register/giờ/IP · 120 ingest/phút/api_key (sliding window) |
| Vận chuyển | HTTPS bắt buộc khi ra internet (TLS tại reverse proxy); Telegram API luôn TLS |
| Tiết lộ key | `api_key_plain` chỉ tồn tại ≤10 phút sau reveal, dọn tự động; DB lộ cũng không suy ra key |
| Chống spam alert | Gộp tin, ≤50 alert/request, 1 tin/giây/chat, obey `retry_after` của Telegram |
| Bot | Nên tắt joingroups + bật privacy mode qua BotFather |

*Nâng cấp tự nhiên khi cần mạnh hơn:* ký payload bằng HMAC-SHA256 trên mỗi request (không chỉ API key) và/hoặc khoá chat_id duy nhất mỗi project.

---

## 8. Vận hành

```bash
# Danh sách dự án & trạng thái ghép nối
sqlite3 data/alerts.db "SELECT id, project_name, status, telegram_chat_id, linked_at FROM projects;"

# 20 alert gần nhất & tình trạng deliver
sqlite3 data/alerts.db "SELECT rule_id, severity, host, delivered, received_at
                        FROM alerts_log ORDER BY id DESC LIMIT 20;"

# Alert gửi lỗi (cần chú ý)
sqlite3 data/alerts.db "SELECT * FROM alerts_log WHERE delivered = 0 ORDER BY id DESC;"

# Backup (WAL mode: copy khi server đang chạy vẫn an toàn nếu kèm -wal/-shm)
sqlite3 data/alerts.db ".backup backup-$(date +%F).db"

# Log server
docker compose logs -f alert-server
```

**Khôi phục sau sự cố:** chỉ cần giữ lại `.env` + `data/alerts.db` — khởi động lại là đủ state như cũ.

---

## 9. Xử lý sự cố (troubleshooting)

| Triệu chứng | Nguyên nhân & cách xử lý |
|---|---|
| `/healthz` trả `"bot":"disabled"` | Thiếu `ALERT_BOT_TOKEN` trong `.env` — điền rồi restart |
| Log lặp `polling/getMe lỗi` | Token sai / server không ra được internet tới `api.telegram.org` (kiểm tra DNS, firewall) |
| User gửi mã nhưng bot im lặng | Xem log: nếu `chat bị khoá` → user nhập sai ≥5 lần, chờ 10 phút; nếu mã "đã sử dụng" — người khác đã link, tạo mã mới |
| Agent pair dừng ở "chờ ghép nối" | User chưa gửi mã / gửi sau 10 phút (hết hạn) → chạy lại `pair` lấy mã mới |
| `pairing-status` trả `linked` nhưng không có `api_key` | Quá cửa sổ reveal 10 phút → ghép nối lại: xoá conf, `pair` mới |
| ingest trả `warning ... telegram http` | Alert **đã lưu an toàn**; server mất kết nối Telegram — tự phục hồi, không cần làm gì |
| Agent log "mạng lỗi — spool N alert" | Mất kết nối tới central server; tự gửi lại khi mạng về. Kiểm tra: `curl -s $SERVER_URL/api/v1/healthz` |
| Trùng lặp alert trên Telegram | Agent bị reset state (`offset` mất) sau khi đã spool — hiếm; chấp nhận at-least-once theo thiết kế |

---

## 10. Đã kiểm thử

**E2E local (bot fake-token):** full API flow (register → pending → link → linked + api_key → ingest 2 alert gộp 1 tin → sai key 401); agent thật: pair in mã + lưu conf 0600; run đọc 3 alert JSONL, offset chuẩn; **mất mạng → spool 2 alert → hồi phục → tự drain**; bot sai token không làm chết server (retry 10s).

**E2E bot thật (@php2shell_alert_bot):** user nhắn mã UUID → bot lưu chat_id + trả lời thành công → agent lấy api_key → `test-alert` và alert `P2S-011 CRITICAL` mô phỏng **deliver thật** (`delivered:1` cho cả hai, xác nhận trên Telegram).

---

## 11. Mở rộng (roadmap gợi ý)

- [ ] HMAC ký payload mỗi request (nâng cấp auth ngoài API key)
- [ ] Digest hàng giờ khi có alert `delivered=0` tồn đọng
- [ ] `/api/v1/projects` (admin): xem/khoá/unlink dự án qua API thay vì SQL tay
- [ ] Prometheus `/metrics` (số alert nhận/gửi/lỗi theo project)
- [ ] Đa kênh: email/Webhook ngoài Telegram (mở rộng `telegram.py` → `notifier/`)
