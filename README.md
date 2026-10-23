# PHP2Shell Monitor — Detection & Central Alert Platform

Bộ giải pháp **phòng thủ** phát hiện và cảnh báo khai thác **CVE-2026-109618 / CVE-2026-109619** (PHP2Shell — lỗicritical của PHP 8.2.x/8.3.x liên quan `PHP_SESSION_UPLOAD_PROGRESS`: memory exhaustion & Use-After-Free dẫn tới RCE) gồm **hai thành phần độc lập, ghép nối được với nhau**:

```
┌─────────────────────────────┐        HTTPS + API key         ┌──────────────────────────────┐
│  SERVER DỰ ÁN (mỗi khách)    │ ────────────────────────────► │  CENTRAL ALERT SERVER         │
│                              │                                │                               │
│  php2shell-monitor (bash)    │   alert JSONL                  │  FastAPI + SQLite             │
│   · phát hiện T1/T2/T3       │   ┌────────────────────┐       │   · pairing dự án ↔ Telegram  │
│   · 18 rule, read-only       │   │  p2s-agent.sh      │ ────► │   · 1 bot dùng chung          │
│   · alerts/queue.jsonl ──────┼───►│  (client agent)   │       │   · bắn alert tức thì         │
└─────────────────────────────┘   └────────────────────┘       └───────────────┬──────────────┘
                                                                               │ sendMessage
                                                                       ▼ Telegram @bot
                                                            📱 Alert về đúng người phụ trách dự án
```

## Thành phần

| Thư mục | Là gì | Tài liệu |
|---|---|---|
| **[`php2shell-monitor/`](php2shell-monitor/)** | Engine phát hiện chạy **trên server web**: đọc access log/FPM/kernel/auditd/webroot//proc, 3 tầng phát hiện (T1 pre-exploit → T2 đang khai thác → T3 đã thành công), xuất alert JSONL SIEM-ready. Pure Bash + awk, read-only, zero-dependency cài thêm. | [php2shell-monitor/README.md](php2shell-monitor/README.md) · [ARCHITECTURE.md](php2shell-monitor/ARCHITECTURE.md) |
| **[`central-alert-server/`](central-alert-server/)** | Server trung tâm nhận alert từ mọi server dự án, **pairing tự động qua Telegram** (mã `SEC-<UUID>` in trên terminal → user nhắn cho bot → xong), bắn cảnh báo tức thì. FastAPI + SQLite + bot polling; client agent bash chỉ cần `curl`. | [central-alert-server/README.md](central-alert-server/README.md) |

## Bắt đầu nhanh

**1. Trên server web (mỗi khách hàng):** chạy php2shell-monitor

```bash
cd php2shell-monitor
sudo bash dist/php2shell-monitor.sh -- run      # monitor nền, alert ghi alerts/queue.jsonl
sudo bash dist/php2shell-monitor.sh -- status
```

**2. Central server (một cho toàn hệ thống):**

```bash
cd central-alert-server/server
cp .env.example .env        # điền ALERT_BOT_TOKEN từ @BotFather
docker compose up -d
```

**3. Ghép nối server dự án với Telegram (một lần mỗi dự án):**

```bash
cd central-alert-server/client
sudo ./p2s-agent.sh pair --name khach-hang-A --server https://alert.example.com
# → in mã SEC-<UUID> → user copy mã nhắn cho bot → bot trả lời "Ghép nối thành công"
sudo ./p2s-agent.sh test    # alert thử phải hiện trên Telegram
sudo ./p2s-agent.sh run     # chạy thường trực (systemd unit kèm sẵn)
```

## Đường alert hoàn chỉnh

php2shell-monitor phát hiện (ví dụ worker php-fpm `exited on signal 11` + IP đang POST upload-progress) → ghi `alerts/queue.jsonl` → `p2s-agent.sh` đọc theo offset (không trùng, spool khi mất mạng) → `POST /api/v1/ingest-log` → central server tra `api_key → project → chat_id` → **🚨 CRITICAL · P2S-011** hiện trên Telegram trong ~giây.

## Giấy phép & phạm vi

Nghiên cứu/giáo dục và vận hành giám sát an ninh cho hệ thống của bạn. Các rule có ghi rõ nguồn gốc/license trong từng file JSONL (tham chiếu Sigma, Elastic, Cybaverse, Lexsah, NSA DFIR…). Thư mục `repos/` chứa bản clone các repo tham chiếu bên thứ ba — **không đưa lên git** (xem `.gitignore`).
