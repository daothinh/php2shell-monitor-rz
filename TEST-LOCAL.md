# Test local — php2shell-monitor 1.4.9 + server 1.1.0

## 0. Server đang chạy

```bash
docker ps | grep p2s-central-alert        # Up (healthy)
curl -s http://127.0.0.1:8000/api/v1/healthz
# {"ok":true,"bot":"polling","projects":4,...}
```

Image: `p2s/central-alert-server:1.1.0` · data: `data-server/` (mount ra host)

## 1. Cài monitor trỏ về server local

Endpoint trong bản build là `https://45-124-93-136.sslip.io`. Để test local, override:

```bash
cd /home/gaban/Downloads/php2shell-wrap

sudo P2S_ENDPOINT_B64=DAwbBFIeQVlWT0FERgFAWV5AX0RY \
  bash php2shell-monitor/dist/php2shell-monitor.sh \
  --project khach-test --chatid <CHAT_ID>
```

`DAwbBFIeQVlWT0FERgFAWV5AX0RY` = `http://127.0.0.1:8000` (XOR-mã hoá).
Sinh lại nếu đổi URL:

```bash
bash -c 'source php2shell-monitor/src/lib/endpoint.sh; p2s_endpoint_encode http://127.0.0.1:8000'
```

Lấy CHAT_ID: nhắn `/id` cho bot `@lenp2shell_bot`.

## 2. Kỳ vọng khi cài

```
⏳ Đang đăng ký thiết bị <hostname> | <ip> cho dự án "khach-test" (thiết bị <hostname>)

✅ GHÉP NỐI THÀNH CÔNG

 Dự án     :  khach-test
 Thiết bị   :  <hostname>

 Quét log cũ: chạy nền, không cần chờ.

 Kiểm tra trạng thái:   sudo php2shell-monitor.sh status
```

Lệnh cài trả về ngay. Quét bù (retro-hunt + lượt quét đầu) chạy nền; xem kết quả:

```bash
sudo php2shell-monitor.sh status      # mục "== catchup (quét bù sau khi cài) =="
```

```
== catchup (quét bù sau khi cài) ==
đang chạy: retro-hunt
# rồi:
xong lúc 2026-11-03T07:39:57Z — không có dấu vết trong log cũ
```

Telegram nhận đúng 1 tin:

```
✅ GHÉP NỐI THÀNH CÔNG

📦 Dự án: khach-test
🏷 Thiết bị: <hostname>
🛠 php2Shell-monitor: 1.4.9
```

## 3. Kiểm tra

```bash
sudo php2shell-monitor.sh status
```

## 4. Update (bắt buộc --force)

```bash
sudo P2S_ENDPOINT_B64=DAwbBFIeQVlWT0FERgFAWV5AX0RY \
  bash php2shell-monitor/dist/php2shell-monitor.sh --force \
  --project khach-test --chatid <CHAT_ID>
```

Không có `--force` → giữ cấu hình cũ, **không** gửi tin xác nhận (không biết đã lên bản mới chưa).


## 4b. Đổi nơi nhận alert (group <-> chat cá nhân)

```bash
sudo P2S_ENDPOINT_B64=DAwbBFIeQVlWT0FERgFAWV5AX0RY \
  bash php2shell-monitor/dist/php2shell-monitor.sh --force \
  --project localgaba --chatid 1244302311
```

`--force` là bắt buộc: không có nó installer giữ cấu hình cũ và không đổi chat.

Kiểm tra sau khi chạy:

```bash
# chat đích phải là chat mới
curl -s http://127.0.0.1:8000/api/v1/whoami \
     -H "X-API-Key: $(sed -n 's/^API_KEY=//p' /opt/php2shell-monitor/conf/central.conf)"
# {"project_name":"localgaba","chat_id":"1244302311",...}
```

Nếu alert vẫn về group cũ, kiểm tiến trình còn sót:

```bash
ps aux | grep -E "supervisor.sh loop|central.sh agent" | grep -v grep
```

Trước 1.4.9, `--force` đổi project không dừng supervisor cũ (pidfile nằm ở
`projects/<PROJECT_CŨ>/devices/<DEVICE>/run/`), nên agent cũ vẫn gửi alert bằng
key cũ tới chat cũ. 1.4.9 dừng hẳn trước khi khởi động lại.

## 5. Cửa sổ retro (mốc UTC)

Mặc định quét từ **00:00 UTC hôm nay** = **07:00 sáng giờ VN**. Sự cố trong
khoảng 00:00–07:00 giờ VN **không** được retro bắt (mốc UTC, không phụ thuộc TZ máy).

Muốn phủ trọn ngày theo giờ VN — đặt 17:00Z hôm trước:

```bash
sudo RETRO_SINCE=$(date -u -d 'yesterday 17:00' +%Y-%m-%dT%H:%M:%SZ) \
     bash /opt/php2shell-monitor/discovery/retro_hunt.sh
```

Quét sâu nhiều ngày:

```bash
sudo RETRO_SINCE=2026-10-01T00:00:00Z bash /opt/php2shell-monitor/discovery/retro_hunt.sh
```

Biến môi trường **thắng** `conf/default.conf`, nên các lệnh trên không cần sửa conf.

## 6. Thử alert thật (không cần chờ tấn công)

Tạo log giả rồi chạy retro:

```bash
sudo tee /tmp/fake-access.log >/dev/null <<'LOG'
203.0.113.9 - - [03/Nov/2026:03:00:01 +0000] "GET /vuln.php?page=/etc/passwd HTTP/1.1" 200 1099 "-" "curl/8.18.0"
203.0.113.9 - - [03/Nov/2026:03:00:02 +0000] "GET /vuln.php?page=/var/lib/php/sessions/sess_x HTTP/1.1" 200 5 "-" "curl/8.18.0"
LOG

sudo NGINX_ACCESS=/tmp/fake-access.log \
     RETRO_SINCE=2026-11-03T00:00:00Z \
     bash /opt/php2shell-monitor/discovery/retro_hunt.sh
```

Alert đi qua queue → agent → server → Telegram trong ≤5 giây.
Tin phải có khối `🧩 Event logs (N nhóm / M events)` kèm dòng log thật.

## 7. Gỡ

```bash
sudo php2shell-monitor.sh clean
```
