# Hướng dẫn đem php2shell-monitor đi quét tại máy khách hàng

Tình huống: kỹ thuật viên mang tool đến máy chủ PHP của khách, cài đặt, quét
dấu vết khai thác CVE-2026-109618/109619 (PHP session upload_progress),
bật giám sát đẩy alert về Telegram, thu bằng chứng đem về.

Mọi thứ trên máy khách đều nằm gọn trong `/opt/php2shell-monitor` (root-only,
0600/0700) — tool không ghi bất cứ đâu ngoài thư mục đó.

---

## 0. Chuẩn bị TRƯỚC KHI ĐI (trên máy của mình)

1. **Mang theo file cài** `php2shell-monitor.sh` (+ file `.sha256`) — lấy từ
   repo `php2shell-monitor/dist/` hoặc bản build mới nhất từ dev2. Copy vào USB:
   ```bash
   sha256sum -c php2shell-monitor.sh.sha256   # kiểm tra file nguyên vẹn
   ```
2. **Chọn nơi nhận alert trên Telegram** — nên tạo MỖI KHÁCH HÀNG một group
   (alert không lẫn vào nhau):
   - Tạo group → mời `@p2shell_bot` vào group → trong group nhắn `/id`
   - Bot trả lời kèm **Chat ID** (group là số ÂM, ví dụ `-1001234567890`) → lưu lại
3. **Điều kiện trên máy khách**: Linux có `bash` + `curl` + `awk`, có quyền
   `sudo`, và **ra được internet tới `45.124.93.136:8000`**:
   ```bash
   curl -s http://45.124.93.136:8000/api/v1/healthz   # mong muốn: {"ok":true,...}
   ```
   Máy khách KHÔNG cần Telegram — chỉ cần gọi được server trung tâm.

---

## 1. Cài + ghép nối = MỘT LỆNH (trên máy khách)

Copy file vào máy khách rồi chạy (lần đầu tự cài vào `/opt/php2shell-monitor`,
tự bật supervisor nền rà log mỗi 5 phút):

```bash
sudo bash php2shell-monitor.sh -- --chatid -1001234567890 --project ten-khachhang
```

| Tham số | Ý nghĩa |
|---|---|
| `-- --chatid` | Chat ID đã lấy ở bước 0 (số âm của group, hoặc số dương nếu nhận vào chat riêng) |
| `--project` | Tên dự án/khách hàng — nhiều máy của cùng khách dùng chung một tên, mỗi máy tự thành một device (theo hostname) |

> ⚠️ **Chú ý dấu `--` đứng trước**: file cài là archive makeself, mọi tham số
> muốn tới cho tool phải đặt sau `--` (thiếu `--` sẽ báo "Unrecognized flag").
> Sau khi cài xong có thể gọi thẳng không cần `--`:
> `sudo bash /opt/php2shell-monitor/main.sh --chatid -1001234567890`.

Script in hướng dẫn từng bước, rồi bot Telegram gửi
**"🔔 Yêu cầu ghép nối mới"** vào đúng group → trong group nhắn **`/confirm`**
(trong vòng 10 phút). Script tự nhận API key và lưu cấu hình — không phải gõ gì thêm.

> Nếu bot chưa nhắn được vào group: kiểm tra bot đã được thêm vào group và
> đã có ai nhắn `/start` cho bot chưa, rồi nhắn `/confirm` — yêu cầu ghép nối
> vẫn còn hiệu lực, không cần chạy lại từ đầu.

## 2. Kiểm tra hoạt động

```bash
sudo bash php2shell-monitor.sh -- status   # sức khoẻ device, batch gần nhất, alert gần nhất
sudo bash php2shell-monitor.sh -- test     # gửi 1 alert thử -> thấy trên Telegram là xong
```

Trên Telegram nhắn `/list` cho bot để thấy các server đang quản lý của chat đó.

## 3. Quét dấu vết KHỨA trong quá khứ (quan trọng khi đi đánh giá)

```bash
sudo bash php2shell-monitor.sh -- retro     # quét one-shot toàn bộ log cũ đã rotate
sudo bash php2shell-monitor.sh -- discover  # (tuỳ chọn) map các log thực tế có trên máy
```

`retro` sinh một alert tổng hợp cho cả cửa sổ thời gian của log cũ — nếu khách
đã từng bị khai thác trước đây, đây là cách phát hiện.

## 4. Thu bằng chứng đem về

Alert + raw evidence (mỗi hit kèm `file:line`) đã tự đẩy về server trung tâm
và lưu ở đó. Nếu cần bản sao tại chỗ:

```bash
sudo bash php2shell-monitor.sh -- export
# -> /opt/php2shell-monitor/export/ (JSON, chỉ root đọc được) — scp về máy mình
```

## 5. Trước khi rời khách hàng

**Phương án A — để lại giám sát dài hạn** (khuyến nghị):
```bash
sudo bash php2shell-monitor.sh -- run      # đảm bảo supervisor đang chạy nền
```
Supervisor không dùng cron/systemd nên **không tự sống lại sau reboot**. Để lại
giám sát bền, thêm 1 dòng crontab trên máy khách:
```bash
sudo bash -c 'echo "@reboot root /bin/bash /opt/php2shell-monitor/main.sh -- run" > /etc/cron.d/php2shell-monitor'
```

**Phương án B — gỡ sạch** (khách không muốn để lại):
```bash
sudo bash php2shell-monitor.sh -- clean     # stop supervisor + xoá toàn bộ /opt/php2shell-monitor
```
Bằng chứng đã an toàn trên server trung tâm, gỡ máy khách không mất dữ liệu.

## 6. Mô hình alert (giải thích cho khách hàng)

- Rà log mỗi **5 phút**; mỗi batch tối đa **1 alert/thiết bị**, severity là mức
  **cao nhất** trong các hit (CRITICAL > HIGH > MEDIUM > LOW > INFO) — không spam.
- Mọi raw hit đều lưu evidence kèm `file:line`, cả trên máy khách
  (`/opt/php2shell-monitor/projects/.../evidence/`) lẫn server trung tâm.
- Mất mạng: alert nằm queue/spool tại máy khách, tự đẩy bù khi có mạng lại.

## 7. Sự cố thường gặp

| Triệu chứng | Xử lý |
|---|---|
| `không gọi được http://45.124.93.136:8000` | Máy khách chặn egress — mở firewall cho IP:port này (chỉ cần outbound) |
| Bot không gửi yêu cầu ghép nối | Group chưa thêm bot / chưa ai `/start` bot — làm rồi nhắn `/confirm` |
| Muốn đổi nơi nhận alert | Chạy lại lệnh ở bước 1 với `-- --chatid` mới rồi `/confirm` ở chat mới |
| Quên Chat ID | Nhắn `/id` trong group/chat đó, bot trả lại ngay |
| Xem máy nào đang ghép | Nhắn `/list` cho bot |
