# PHP2SHELL MONITOR - Công cụ giám sát & phát hiện CVE-2026-109618/109619

[![Status](https://img.shields.io/badge/status-production--ready-brightgreen)]() [![PHP](https://img.shields.io/badge/PHP-8.2.34--8.3.35-777BB4)]() [![CVE](https://img.shields.io/badge/CVE-2026--109618%20|%202026--109619-critical)]()

Hệ thống giám sát thời gian thực bằng Bash script, tự động phát hiện các nỗ lực khai thác lỗ hổng PHP2Shell mà không cần thay đổi cấu hình hệ thống hiện tại.

---

## 🚀 Quick Start

### 1. Tải công cụ
- **Tải trực tiếp:** [php2shell-monitor.sh](https://github.com/daothinh/php2shell-monitor-rz/releases/latest/download/php2shell-monitor.sh)
- **Checksum:** [php2shell-monitor.sh.sha256](https://github.com/daothinh/php2shell-monitor-rz/releases/latest/download/php2shell-monitor.sh.sha256)
- **Trang Release:** [github.com/daothinh/php2shell-monitor-rz/releases](https://github.com/daothinh/php2shell-monitor-rz/releases)

```bash
curl -LO https://github.com/daothinh/php2shell-monitor-rz/releases/latest/download/php2shell-monitor.sh
curl -LO https://github.com/daothinh/php2shell-monitor-rz/releases/latest/download/php2shell-monitor.sh.sha256
echo "$(cut -d' ' -f1 php2shell-monitor.sh.sha256)  php2shell-monitor.sh" | sha256sum -c -
chmod +x php2shell-monitor.sh
```

> File `.sha256` sinh từ pipeline build nên bên trong ghi đường dẫn `dist/php2shell-monitor.sh`; lệnh trên ghép lại checksum với tên file sau khi tải để xác minh đúng.

### 2. Thiết lập nhận thông báo qua Telegram

Bạn có thể chọn nhận cảnh báo bảo mật về tin nhắn Cá nhân hoặc nhận chung trong một nhóm (Group chat).



#### Lựa chọn A: Nhận thông báo qua tin nhắn cá nhân

1. Truy cập bot: [@p2shell_bot](https://t.me/p2shell_bot).

2. Bấm nút **Start** để khởi động bot.

3. Gõ /id để  một chuỗi số  **Chat ID**. Hãy copy và lưu lại mã này.



#### Lựa chọn B: Nhận thông báo trong Nhóm (Group Chat)

1. Thêm bot [@p2shell_bot](https://t.me/p2shell_bot) vào nhóm muốn nhận cảnh báo.

2. Gõ `/id` vào nhóm để lấy **Chat ID** (Lưu ý: Chat ID nhóm thường có dấu `-` ở đầu, vd: `-100123456789`).


### 3. Kết nối & kích hoạt giám sát
Mở Terminal trên máy chủ, cấp quyền thực thi (nếu cần) và chạy lệnh sau với quyền root:

```bash
chmod +x php2shell-monitor.sh
sudo ./php2shell-monitor.sh --project "<tên_dự_án>" --chatid "<Chat_ID>"