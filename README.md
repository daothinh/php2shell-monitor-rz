# PHP2SHELL MONITOR - Hệ thống Phát hiện Tấn công CVE-2026-109618/109619



[![Status](https://img.shields.io/badge/status-production--ready-brightgreen)]()

[![PHP](https://img.shields.io/badge/PHP-8.2.34--8.3.35-777BB4)]()

[![CVE](https://img.shields.io/badge/CVE-2026--109618%20|%202026--109619-critical)]()



Hệ thống giám sát thời gian thực bằng bash script, giúp phát hiện các nỗ lực khai thác lỗ hổng PHP2Shell (CVE-2026-109618/109619) mà không cần can thiệp hay sửa đổi cấu hình hệ thống hiện tại.



---



## 🚀 Hướng Dẫn Cài Đặt & Sử Dụng (Quick Start)



### 1. Chuẩn bị

*   **Tải công cụ:** [php2shell-monitor.sh (bản mới nhất)](https://github.com/daothinh/php2shell-monitor-rz/releases/latest/download/php2shell-monitor.sh)

*   **Checksum xác minh:** [php2shell-monitor.sh.sha256](https://github.com/daothinh/php2shell-monitor-rz/releases/latest/download/php2shell-monitor.sh.sha256)

*   **Trang Release:** [github.com/daothinh/php2shell-monitor-rz/releases](https://github.com/daothinh/php2shell-monitor-rz/releases)

*   **Bot Telegram hỗ trợ:** [t.me/p2shell_bot](https://t.me/p2shell_bot)

Tải và xác minh bằng một lệnh:

```bash
curl -LO https://github.com/daothinh/php2shell-monitor-rz/releases/latest/download/php2shell-monitor.sh
curl -LO https://github.com/daothinh/php2shell-monitor-rz/releases/latest/download/php2shell-monitor.sh.sha256
sha256sum -c php2shell-monitor.sh.sha256
chmod +x php2shell-monitor.sh
```



### 2. Thiết lập nhận thông báo qua Telegram

Bạn có thể chọn nhận cảnh báo bảo mật về tin nhắn cá nhân hoặc nhận chung trong một nhóm (Group chat).



#### Lựa chọn A: Nhận thông báo qua tin nhắn cá nhân

1. Truy cập vào link của bot: [t.me/p2shell_bot](https://t.me/p2shell_bot).

2. Bấm nút **Start** để khởi động bot.

3. Gõ /id để  một chuỗi số  **Chat ID**. Hãy copy và lưu lại mã này.



#### Lựa chọn B: Nhận thông báo trong Nhóm (Group Chat)

1. Thêm bot [t.me/p2shell_bot](https://t.me/p2shell_bot) vào nhóm Telegram mà bạn muốn nhận cảnh báo.

2. Lấy **Chat ID** của nhóm (Lưu ý: Chat ID của nhóm thường có dấu trừ `-` ở phía trước, ví dụ: `-100123456789`).


### 3. Khởi chạy công cụ giám sát

Sau khi tải công cụ về máy chủ và đã có được Chat ID, hãy mở Terminal (dòng lệnh) và chạy lệnh dưới đây với quyền root (`sudo`):



```bash

sudo ./php2shell-monitor.sh --project "<tên_dự_án>" --chatid "<Chat_ID_đã_lấy_ở_bước_2>"

```



**Giải thích tham số:**

*   `--project`: Đặt tên cho dự án của bạn (ví dụ: `x90-Tech-Stack`). Việc này giúp bạn dễ dàng nhận biết cảnh báo đó đến từ hệ thống nào nếu bạn giám sát nhiều máy chủ.

*   `--chatid`: Mã số Telegram bạn đã lấy ở Bước 2 để bot biết nơi gửi tin nhắn đến.

---