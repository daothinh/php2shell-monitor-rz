# Central Security Alert Server

Kho **tập trung** cho alert của toàn bộ server được monitor. Mỗi device gửi về
**một alert cho mỗi batch 5 phút**, kèm **toàn bộ dòng log gốc** đã khớp rule.
Server lưu theo `project → device → ngày`, bắn Telegram cho đúng dự án, và cho
phép tra cứu lại từng dòng log.

| | |
|---|---|
| **Backend** | Python 3.11+ · FastAPI · Uvicorn (async) |
| **Database** | SQLite (WAL) — `projects`, `devices`, `pairing_codes`, `alerts`, `alert_hits` |
| **Evidence** | mirror JSONL trên đĩa: `<root>/<project>/IP-LAN_<ip>_<hostname>_<user>/<batch>.jsonl` |
| **Telegram** | 1 bot trung tâm, long-polling (không cần webhook công khai) |
| **Client** | `p2s-agent.sh` — bash + curl, tail `alerts/queue.jsonl` của monitor |
| **Triển khai** | Docker Compose / bare-metal, TLS qua reverse proxy |

---

## 1. Mô hình lưu trữ

```
projects                      devices                        alerts                      alert_hits
────────                      ───────                        ──────                      ──────────
id                            id                             id                          id
project_name                  project_id → projects.id       project_id                  alert_id → alerts.id
api_key_hash (sha256)         device_name                    device_id                   rule_id
status (pending/linked)       created_at                     batch_id                    severity
telegram_chat_id              last_seen_at                   severity (max của batch)    source
created_at, linked_at                                        hit_count                   file
                                                             rules (JSON)                line
                                                             window_start / window_end    ip / method / uri
                                                             evidence_file                status / ua / pid
                                                             evidence_truncated           raw  ← dòng log gốc
                                                             messages / delivered         ts_utc
                                                             received_at
                                                             UNIQUE(device_id, batch_id)
```

Một alert **luôn** có ≥ 1 hit. `alert_hits` là nơi tra cứu: tìm theo IP, URI,
đường dẫn file, hoặc nội dung dòng log.

Trên đĩa, cùng dữ liệu đó được mirror để grep/archive:

```
data/
├── alerts.db
└── evidence/
    └── khach-hang-a/
        └── IP-LAN_10.0.0.15_web01_ubuntu/
            ├── 20261024T000500Z.jsonl   ← mọi hit của batch đó
            └── 20261024T001000Z.jsonl
```

Quy ước:

- Thư mục thiết bị: `IP-LAN_<lan_ip>_<hostname>_<user>` — dễ nhìn ra ngay
  máy nào; thiếu trường nào thì thay bằng `unknown`. IP LAN đổi chỉ ảnh hưởng
  thư mục evidence mới, thiết bị trong DB vẫn nhận diện theo hostname.
- `batch_id` do monitor sinh (`YYYYMMDDTHHMMSSZ`) → dùng làm tên file evidence.
- Gửi lại cùng `(device, batch_id)` là **idempotent**: agent retry không tạo alert
  trùng, không tạo file trùng.
- `ALERT_RETENTION_DAYS` (mặc định 90) dọn cả row DB và thư mục ngày; `0` = giữ mãi.

---

## 2. Cấu trúc mã nguồn

```
central-alert-server/
├── server/
│   ├── app/
│   │   ├── main.py       # FastAPI lifespan: init DB, bot polling, cleanup 15'
│   │   ├── config.py     # env/.env -> Config (evidence root, retention, TTL...)
│   │   ├── db.py         # schema + queries (projects/devices/alerts/alert_hits)
│   │   ├── evidence.py   # normalize payload + mirror raw hits ra đĩa
│   │   ├── routes.py     # pairing, ingest, query (auth: API key / read / admin), admin
│   │   ├── telegram.py   # PairingBot + TelegramClient + formatter 1-alert
│   │   └── security.py   # api_key, pairing code, RateLimiter, AttemptGuard
│   ├── requirements.txt
│   ├── Dockerfile
│   ├── docker-compose.yml
│   └── .env.example
├── client/
│   ├── p2s-agent.sh      # ghép nối (mặc định) | run | test
│   └── p2s-agent.service
└── tests/
    ├── test_ingest.py    # lưu trữ, idempotency, evidence, Telegram
    └── e2e_full_test.sh  # monitor -> agent -> server
```

---

## 3. Cài đặt

### 3.1. Bot trung tâm (một lần cho toàn hệ thống)

1. `@BotFather` → `/newbot` → lấy token.
2. `server/.env`:

```ini
ALERT_BOT_TOKEN=123456789:AA...
ALERT_ADMIN_TOKEN=doi-ngau-32-ky-tu     # /admin/link + đọc toàn bộ
ALERT_READ_TOKEN=mot-chuoi-ngau-nhien   # chỉ-đọc toàn bộ (dashboard/ops)
ALERT_DB_PATH=/data/alerts.db
ALERT_EVIDENCE_ROOT=/data/evidence
ALERT_RETENTION_DAYS=90
```

### 3.2. Ghép nối theo Chat ID — chat riêng HOẶC group

> Nhánh `feature/chatid-pairing`: pairing theo **Chat ID** thay vì mã `SEC-<UUID>` — alert đi được về **chat riêng của một user hoặc cả group** (cả team cùng nhận).
>
> Bot chính thức của hệ thống: **@p2shell_bot** (lệnh ghép nối in sẵn link và hướng dẫn từng bước).

Bot **tự đăng ký menu lệnh** (nút **≡** / gõ `/`) khi khởi động.

**Luồng ghép nối (TỰ ĐỘNG — không cần /confirm, không spam chat khi triển khai số lượng lớn):**

```
1️⃣ Telegram → bot → /id          → bot trả Chat ID (chat riêng: số dương; group: số âm)
2️⃣ Server:   sudo p2s-agent.sh \
                --server  <url central server> \
                --project <tên dự án> \
                --chatid  <Chat ID vừa copy>
             → GHÉP NỐI NGAY (tự động, không /confirm)

Cả 3 tham số đều BẮT BUỘC, không có mặc định: tên dự án không lấy từ hostname
(hostname là danh tính THIẾT BỊ, agent tự gửi kèm khi ingest).
```

- Bot chỉ nhắn **1 tin** "✅ Đã tự động ghép nối" vào chat cho dự án **mới**
  (kèm `/unlink <tên>` để ngắt nếu không phải do bạn); thêm máy vào dự án đã
  ghép thì **im lặng** — 1000 thiết bị chạy pair cũng không spam chat.
- Mỗi lần pair cấp **một API key riêng** cho dự án (bảng `api_keys`, các key
  cũ vẫn sống) — cứ chạy pair trên từng máy, khỏi copy conf tay.

| Lệnh (menu ≡) | Chức năng |
|---|---|
| `/start` | Một dòng giới thiệu bot |
| `/id` | Lấy Chat ID của chat hiện tại (cần cho script pair) |
| `/list` (hoặc `/ids`, `/servers`) | Dự án đang quản lý + **số thiết bị của từng dự án** (dòng tổng: số dự án, số dự án khả dụng, tổng thiết bị) |
| `/unlink <tên>` | Ngắt một dự án khỏi chat: alert dừng gửi ngay, lịch sử vẫn lưu |
| `/help` | Trợ giúp ngắn: 4 lệnh + 1 dòng cách ghép nối |

Nghiệp vụ: dự án khả dụng luôn có **≥ 1 thiết bị**; dự án chưa nhận alert nào
được `/list` đánh dấu `0 — chưa khả dụng` thay vì ẩn đi. `/confirm` và
`/add_new_id` không còn trong menu (ghép nối tự động qua Chat ID).

API: `POST /api/v1/register-chatid` `{project_name, chat_id, device?}` → `{pair_ref, auto_linked, ...}` — ghép nối và cấp key NGAY; agent poll `GET /pairing-status?code=<pair_ref>` nhận `linked` + `api_key` ở lần đầu tiên.

**Bảo mật:** ghép nối tự động nên chat ID là "khóa": rate-limit 30 đăng ký/giờ/IP; tin nhắn thông báo nêu rõ `/unlink` để chủ chat tự vệ khi có người lạ trỏ alert vào. Group cần bot là thành viên để bot gửi được alert.

### 3.3. Chạy

```bash
cd server
docker compose up -d --build
curl -s localhost:8000/api/v1/healthz
```

Bare-metal:

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

Volume `./data` phải giữ được: chứa `alerts.db` **và** `evidence/`.

---

## 4. API

Tất cả dưới `/api/v1`. Cột **Auth** cho biết credential bắt buộc.

| Method | Path | Auth | Mục đích |
|---|---|---|---|
| POST | `/register-pairing` | không | xin mã ghép nối |
| GET | `/pairing-status?code=` | không (cần mã) | agent poll: pending / linked + api_key |
| POST | `/ingest-log` | `X-API-Key` / Bearer | device gửi alert |
| GET | `/devices` | **đọc** | kiểm kê device + đếm alert/hit, severity cuối |
| GET | `/alerts?limit=&project_id=&device_id=&severity=` | **đọc** | danh sách alert |
| GET | `/alerts/{id}` | **đọc** | **chi tiết + toàn bộ raw hit** |
| GET | `/search?q=` | **đọc** | tìm trong `raw`/`file`/`ip`/`uri` |
| POST | `/admin/link` | admin token | ghép nối thủ công |
| GET | `/healthz` | không | health check (không lộ dữ liệu) |

### 4.0. Xác thực endpoint đọc

Bốn endpoint đọc (`/devices`, `/alerts`, `/alerts/{id}`, `/search`) **bắt buộc**
một trong các credential sau — không có thì `401`:

| Credential | Phạm vi |
|---|---|
| `X-API-Key: <key>` hoặc `Authorization: Bearer <key>` | **chỉ project sở hữu key** |
| `X-Read-Token: <ALERT_READ_TOKEN>` | mọi project (read-only, cho dashboard) |
| `X-Admin-Token: <ALERT_ADMIN_TOKEN>` | mọi project |

Với API key, alert của project khác trả `404` (không xác nhận sự tồn tại) và
`?project_id=` trỏ sang project khác trả `403`. `X-Read-Token` chỉ hoạt động khi
`ALERT_READ_TOKEN` được đặt — mặc định rỗng = tắt.

```bash
# ops/dashboard: xem mọi project
curl -s -H "X-Read-Token: $ALERT_READ_TOKEN" \
  'https://alert.example.com/api/v1/alerts?limit=5'

# một khách hàng tự tra dữ liệu của mình
curl -s -H "X-API-Key: $API_KEY" \
  'https://alert.example.com/api/v1/search?q=203.0.113.42'
```

### 4.1. `POST /ingest-log`

```bash
curl -s -X POST https://alert.example.com/api/v1/ingest-log \
  -H "X-API-Key: $API_KEY" -H 'Content-Type: application/json' \
  -d '{
    "host": "web01",
    "device": "web01",
    "alerts": [{
      "batch_id": "20261024T000500Z",
      "project": "khach-hang-a",
      "device": "web01",
      "window_start": "2026-10-24T00:00:00Z",
      "window_end":   "2026-10-24T00:05:00Z",
      "severity": "CRITICAL",
      "hits": 2,
      "rules": [{"rule_id": "P2S-020", "hits": 1}, {"rule_id": "P2S-030", "hits": 1}],
      "evidence": [
        {"ts_utc":"2026-10-24T00:03:11Z","rule_id":"P2S-020","severity":"CRITICAL",
         "source":"webroot","file":"/var/www/html/shell.php","line":0,
         "raw":"webroot file NEW: /var/www/html/shell.php"},
        {"ts_utc":"2026-10-24T00:03:12Z","rule_id":"P2S-030","severity":"HIGH",
         "source":"access_log","file":"/var/log/nginx/access.log","line":8842,
         "ip":"203.0.113.42","method":"GET","uri":"/shell.php?cmd=whoami","status":"200",
         "ua":"curl/8.5.0","raw":"203.0.113.42 - - [...] \"GET /shell.php?cmd=whoami HTTP/1.1\" 200 34 \"-\" \"curl/8.5.0\""}
      ]
    }]
  }'
```

```json
{
  "accepted": 1,
  "duplicates": 0,
  "messages": 1,
  "delivered": 1,
  "alerts": [{"batch_id":"20261024T000500Z","status":"stored","alert_id":42,
              "severity":"CRITICAL","hits":2,
              "evidence_file":"/data/evidence/khach-hang-a/IP-LAN_10.0.0.15_web01_ubuntu/20261024T000500Z.jsonl"}]}
}
```

- `accepted`: alert mới đã lưu; `duplicates`: batch đã có (retry an toàn).
- `messages`/`delivered`: số tin Telegram đã gửi / gửi thành công.
- Payload **kiểu cũ** (một `rule_id` + `message` + `src_ip`) vẫn được nhận và
  chuẩn hoá thành một alert có một hit.
- Mã lỗi: `401` key sai · `409` chưa có chat_id · `422` body sai · `429` vượt rate.

### 4.2. `GET /alerts/{id}`

```json
{
  "id": 42, "project_name": "khach-hang-a", "device_name": "web01",
  "batch_id": "20261024T000500Z", "severity": "CRITICAL", "hit_count": 2,
  "rules": [{"rule_id": "P2S-020", "hits": 1}, {"rule_id": "P2S-030", "hits": 1}],
  "evidence_file": "/data/evidence/khach-hang-a/IP-LAN_10.0.0.15_web01_ubuntu/20261024T000500Z.jsonl",
  "evidence": [
    {"rule_id":"P2S-020","source":"webroot","file":"/var/www/html/shell.php","line":0,
     "raw":"webroot file NEW: ..."},
    {"rule_id":"P2S-030","source":"access_log","file":"/var/log/nginx/access.log","line":8842,
     "ip":"203.0.113.42","uri":"/shell.php?cmd=whoami","raw":"203.0.113.42 - - ..."}
  ]
}
```

### 4.3. `GET /devices`

```json
{"devices":[
  {"project_name":"khach-hang-a","device_name":"web01","alerts":37,"hits":214,
   "last_severity":"CRITICAL","last_alert_at":"2026-10-24T00:05:02Z",
   "last_seen_at":"2026-10-24T00:05:01Z"}
]}
```

### 4.4. Tin Telegram

Mỗi alert = **một tin 4 dòng**, không kèm raw log (raw nằm ở `GET /alerts/{id}`
và file evidence):

```
🛡 Central Security Alert - 24/10/2026
🚨 CRITICAL · Server bị chiếm quyền (RCE) · 7 hit / 5 phút
📦 Dự án: khach-hang-a
🖥 web01 / 192.168.1.24
```

| Dòng | Nội dung |
|---|---|
| 1 | `🛡 Central Security Alert - DD/MM/YYYY` theo `ALERT_DISPLAY_TZ` |
| 2 | emoji + severity cao nhất batch · **một trong 2 thông báo** · `hits`/độ dài cửa sổ |
| 3 | dự án |
| 4 | `hostname / LAN IP` — LAN IP do agent gửi (`lan_ip`), bỏ trống nếu không xác định |

Thông báo chỉ có 2 loại (`_headline` trong `telegram.py`):
- **Server bị chiếm quyền (RCE)** — batch chứa bất kỳ hit thành công (webroot bị ghi `P2S-020`, host exec `P2S-021`, backdoor `P2S-022`, fpm spawn shell `P2S-024`, reverse shell `P2S-025`).
- **Server đang bị khai thác php2shell** — mọi trường hợp khác (dò/khai thác đang diễn ra).

Chi tiết rule/evidence vẫn tra qua `GET /api/v1/alerts/{id}`.

---

## 5. Client agent

```bash
# Ghép nối: BẮT BUỘC đủ 3 tham số — không có giá trị mặc định
sudo ./p2s-agent.sh \
  --server  http://192.168.22.191:8000 \
  --project khach-hang-A \
  --chatid  812345678

sudo ./p2s-agent.sh test
sudo ./p2s-agent.sh run
```

| Tham số | Bắt buộc | Ý nghĩa |
|---|---|---|
| `--server` | ✅ | URL central server (không hardcode trong script) |
| `--project` | ✅ | tên dự án khách hàng, `[A-Za-z0-9._-]{1,64}` |
| `--chatid` | ✅ | Chat ID Telegram từ `/id` (chat riêng dương, group âm) |

Thiếu bất kỳ tham số nào → script dừng và liệt kê đúng tham số còn thiếu.
Không có chữ `pair`: truyền thẳng 3 tham số là ghép nối. `--device` **không**
phải tham số — thiết bị luôn là `hostname` của máy chạy agent (danh tính thiết
bị, không phải tên dự án).

Thêm thiết bị khác vào cùng dự án: chạy lại lệnh trên máy đó với **cùng**
`--project` + `--chatid` — mỗi máy nhận API key riêng, bot không nhắn lại.

`run`:

- tail `P2S_ALERT_FILE` theo **inode + offset** (rotate an toàn, không gửi trùng);
- chỉ nhận dòng JSON hoàn chỉnh; batch ≤ 20 dòng/request;
- mất mạng → spool `$STATE_DIR/spool/pending.jsonl`, chu kỳ sau gửi bù (FIFO);
- gửi kèm `device`, suy ra từ đường dẫn
  `.../projects/<project>/devices/<device>/alerts/queue.jsonl`, không thì hostname;
- gửi kèm `lan_ip` (IP LAN của host: `ip -4 route get 1.1.1.1` → `ip -4 addr` →
  `hostname -I`; không dùng `hostname -i` vì reverse DNS có thể treo), hiển thị ở
  dòng cuối tin Telegram và dùng trong thư mục evidence;
- gửi kèm `user` (user đang chạy agent: `id -un`) để đặt tên thư mục evidence.

| Biến | Mặc định | Ghi chú |
|---|---|---|
| `P2S_AGENT_CONF` | `/etc/php2shell/agent.conf` | `SERVER_URL`, `API_KEY`, `PROJECT_NAME` (0600) |
| `P2S_AGENT_STATE` | `/var/lib/php2shell-agent` | offset + spool |
| `P2S_ALERT_FILE` | `/var/lib/php2shell/projects/<PROJECT_NAME>/devices/<hostname>/alerts/queue.jsonl` | queue của monitor (suy ra từ project + hostname) |
| `P2S_AGENT_POLL` | `5` | giây/chu kỳ |
| `P2S_SERVER_URL` | — | thay cho `--server` |
| `P2S_PROJECT_NAME` | — | thay cho `--project` (không mặc định hostname) |
| `P2S_TG_CHATID` | — | thay cho `--chatid` |

---

## 6. Bảo mật

| Lớp | Cơ chế |
|---|---|
| API key | 256-bit, server chỉ lưu SHA-256 |
| Đọc dữ liệu | `/devices`, `/alerts`, `/alerts/{id}`, `/search` bắt buộc credential; API key chỉ thấy project của mình, `X-Read-Token`/`X-Admin-Token` thấy tất cả |
| Pairing | mã một lần, 10 phút, chống dò 5 lần/10 phút |
| Rate limit | ingest 120 req/phút/key, đăng ký 30/giờ/IP |
| Evidence | nằm trong volume `data/`, mode kế thừa từ container; đối xử như dữ liệu nhạy cảm |
| Admin | `/admin/link` chỉ bật khi có `ALERT_ADMIN_TOKEN` |

Read API không còn hở: nếu không đặt `ALERT_READ_TOKEN`/`ALERT_ADMIN_TOKEN` thì
chỉ API key từng project đọc được dữ liệu của chính nó. Vẫn nên đặt server sau
reverse proxy có TLS và không publish `8000` ra Internet.

---

## 7. Vận hành

```bash
# ops: kiểm kê toàn bộ device (cần read token)
curl -s -H "X-Read-Token: $ALERT_READ_TOKEN" localhost:8000/api/v1/devices | jq

# alert gần nhất
curl -s -H "X-Read-Token: $ALERT_READ_TOKEN" \
  'localhost:8000/api/v1/alerts?limit=5' | jq '.alerts[]|{batch_id,device_name,severity,hit_count}'

# tra một IP / URI trong toàn bộ hit
curl -s -H "X-Read-Token: $ALERT_READ_TOKEN" \
  'localhost:8000/api/v1/search?q=203.0.113.42' | jq '.hits[]|{project_name,device_name,file,line,raw}'

# SQL trực tiếp
sqlite3 data/alerts.db "SELECT a.id,a.batch_id,d.device_name,a.severity,a.hit_count,a.delivered
                        FROM alerts a JOIN devices d ON d.id=a.device_id
                        ORDER BY a.id DESC LIMIT 20;"
sqlite3 data/alerts.db "SELECT rule_id,COUNT(*) FROM alert_hits GROUP BY rule_id ORDER BY 2 DESC;"

# alert gửi Telegram lỗi
sqlite3 data/alerts.db "SELECT id,batch_id,severity,received_at FROM alerts WHERE delivered=0;"

# evidence trên đĩa
find data/evidence -name '*.jsonl' -newermt '-1 day' | head

# backup: DB + evidence
sqlite3 data/alerts.db ".backup backup-$(date +%F).db"
tar czf evidence-$(date +%F).tgz data/evidence
```

Khôi phục: giữ `.env` + `data/alerts.db` + `data/evidence/`.

---

## 8. Xử lý sự cố

| Triệu chứng | Nguyên nhân & xử lý |
|---|---|
| `/healthz` → `"bot":"disabled"` | thiếu `ALERT_BOT_TOKEN`; điền rồi restart |
| ingest trả `warning ... telegram` | alert **đã lưu** (`delivered=0`); Telegram lỗi mạng/token |
| `duplicates` tăng liên tục | agent retry cùng batch — đúng thiết kế, không mất alert |
| `accepted: 0` mọi lần | kiểm `batch_id` trong payload; alert không có `batch_id` bị từ chối |
| Dòng 2 ghi `không xác định rule` | payload không có `rule_id`/`rules[]`/`evidence[]` |
| Thiếu LAN IP ở dòng 4 | agent không dò được IP (host chỉ loopback) — kiểm `ip -4 route get 1.1.1.1` |
| 409 `chưa có telegram_chat_id` | dự án chưa ghép nối; chạy `p2s-agent.sh --server … --project … --chatid …` |
| DB lớn nhanh | giảm `ALERT_RETENTION_DAYS`, dọn `data/evidence` theo ngày |

---

## 9. Kiểm thử

```bash
cd server && pip install -r requirements.txt pytest
PYTHONPATH=. python -m pytest ../tests/test_ingest.py -q     # 15 test
bash ../tests/e2e_full_test.sh --src ../../php2shell-monitor/src [--conf agent.conf]
```
