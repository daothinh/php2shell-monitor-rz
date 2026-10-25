# php2shell-monitor

Phát hiện khai thác CVE-2026-109618 / CVE-2026-109619 trên một host, theo mô hình
**một alert cho mỗi batch 5 phút**, kèm **toàn bộ dòng log gốc** đã khớp rule.

- Bash 4+ thuần, chỉ đọc log của host. Lần chạy duy nhất tạo ra thay đổi trên
  hệ thống là giải nén vào `/opt/php2shell-monitor`; sau đó mọi thứ chỉ diễn ra
  trong thư mục này.
- Một install = một **device**. Nhiều device gom vào một **project**.

---

## 1. Mô hình alert

Mỗi batch (mặc định 300s) chạy đúng một lần:

1. mọi plugin đọc phần log mới (offset theo inode/byte/**số dòng**);
2. rule pack khớp trên từng field (không phải trên cả dòng TSV);
3. **tối đa một alert** được tạo cho batch đó.

| Thuộc tính alert | Giá trị |
|---|---|
| `severity` | mức cao nhất trong các hit của batch (CRITICAL > HIGH > MEDIUM > LOW > INFO) |
| `hits` | tổng số dòng khớp rule |
| `rules` | `[{rule_id, hits}]` — đếm theo từng rule |
| `evidence[]` | từng dòng log gốc: `rule_id, severity, source, file, line, ip, method, uri, status, ua, pid, raw, ts_utc` |
| `evidence_file` | file JSONL chứa **đầy đủ** hit (kể cả khi `evidence[]` bị cắt bớt) |

Không có dedup, không có correlation, không có scoring. Một batch có hit ⇒ một alert.
Batch không có hit ⇒ không alert, chỉ một dòng `no-hits` trong `run/batches.log`.

`evidence[]` inline bị giới hạn bởi `MAX_EVIDENCE_INLINE` (mặc định 500 dòng);
`evidence_file` luôn chứa tất cả.

---

## 2. Cấu trúc lưu trữ

Toàn bộ tool — code, cấu hình, state, alert, evidence, file tạm — nằm trong
**một thư mục duy nhất**: `/opt/php2shell-monitor`.

```
/opt/php2shell-monitor/                (0700, root)
├── conf/
│   ├── device.conf            ← PROJECT + DEVICE (giữ nguyên khi nâng cấp)
│   ├── default.conf           ← BATCH_INTERVAL, đường dẫn log, plugin switch
│   ├── whitelist.conf         ← 1 PCRE/dòng, loại nhiễu
│   └── rules.d/*.jsonl        ← override rule (tắt/tune) không cần build lại
├── conf.default/              ← template của bản build; chỉ dùng để seed conf/ lần đầu
├── rules/pack/{t1,t2,t3}.jsonl
├── engine/  lib/  plugins/  discovery/  export/
├── main.sh  bootstrap.sh  MANIFEST
├── projects/
│   └── <project>/
│       └── devices/
│           └── <device>/
│               ├── alerts/queue.jsonl      ← 1 dòng / batch có hit
│               ├── evidence/<batch>.jsonl  ← mọi dòng gốc đã khớp
│               ├── state/offsets.tsv       ← path \t inode \t byte \t line
│               ├── state/capabilities.txt  ← nguồn log có trên host
│               └── run/{batches.log,scan.log,plugin_status.tsv,supervisor.pid}
├── reports/      ← discovery + retro-hunt
├── export/       ← bản sao alert để mang đi
└── run/  tmp/
```

Ví dụ thật:

```
/opt/php2shell-monitor/projects/khach-hang-a/devices/web01/
├── alerts/queue.jsonl
├── evidence/20261024T000500Z.jsonl
├── state/offsets.tsv
└── run/batches.log
```

Đặt tên:

```bash
# conf/device.conf
PROJECT="khach-hang-a"     # một khách/site, gom nhiều device
DEVICE="web01"             # host đang chạy monitor
```

---

## 2b. Cài đặt

```bash
sudo bash php2shell-monitor.sh -- status
```

Lần chạy đầu: makeself giải nén **trực tiếp** vào `/opt/php2shell-monitor`
(không qua `/tmp`, không copy lần hai), `bootstrap.sh` seed `conf/` từ
`conf.default/` rồi `chown root` + `chmod 0700/0600` toàn bộ cây. Mọi lần chạy
sau (kể cả nâng cấp) chỉ ghi trong thư mục đó: code bị ghi đè, `conf/` và
`projects/` giữ nguyên, file code cũ không còn trong `MANIFEST` bị xoá.

Không tạo cron, systemd unit, user, hay file nào trong `/etc`, `/var`,
`/usr/local/bin`. Gỡ hoàn toàn bằng `-- clean`.

## 3. Dùng

```bash
sudo bash php2shell-monitor.sh -- discover   # map log + patch status (read-only)
sudo bash php2shell-monitor.sh -- once       # chạy 1 batch ngay
sudo bash php2shell-monitor.sh -- run        # supervisor: batch mỗi BATCH_INTERVAL
sudo bash php2shell-monitor.sh -- status     # project/device, plugin, batch gần nhất, alert cuối
sudo bash php2shell-monitor.sh -- stop
sudo bash php2shell-monitor.sh -- retro      # hunt log cũ (kể cả .gz) -> 1 alert
sudo bash php2shell-monitor.sh -- export     # copy alert ra export/
sudo bash php2shell-monitor.sh -- clean
```

Xem alert mới nhất:

```bash
D=/opt/php2shell-monitor/projects/khach-hang-a/devices/web01
tail -1 "$D/alerts/queue.jsonl" | jq '{severity,hits,rules}'
# mở đúng dòng log đã khớp
tail -1 "$D/alerts/queue.jsonl" | jq -r '.evidence[] | "\(.file):\(.line)"'
```

---

## 4. Rule pack

Mỗi rule là một dòng JSONL:

```json
{"id":"P2S-010","severity":"HIGH",
 "source":["fpm_error","apache_error","kernel"],
 "match":{"type":"regex","field":"msg",
          "pcre":"Allowed memory size of|Hard memory limit of","min":5}}
```

| Trường | Ý nghĩa |
|---|---|
| `source[]` | chỉ khớp record từ các nguồn này (rỗng = mọi nguồn) |
| `match.field` | tên field trong stream: `ts source file line ip method uri status ua pid msg` |
| `match.pcre` | PCRE áp lên **giá trị của field đó** (nên `^500$` hoạt động đúng) |
| `match.and[]` | điều kiện phụ `{field, pcre, neg}` — tất cả phải đúng |
| `match.min` | số hit tối thiểu trong batch để rule được tính (mặc định 1) |
| `needs[]` | chỉ bật khi host có capability tương ứng (`auditd`, `proc`, ...) |
| `enabled` | `false` để tắt |

Rule bị loại vì `min` được ghi lại trong `run/batches.log` (`suppressed ...`).

---

## 5. Plugin & nguồn log

`accesslog_nginx`, `accesslog_apache`, `fpm`, `apache_error`, `nginx_error`,
`kernel`, `auditd`, `sessions`, `webroot_manifest`, `proc_tree`, `modsec`,
`docker_logs`, `appcms`.

Mỗi plugin tự bỏ qua khi nguồn không tồn tại (exit 0) và ghi trạng thái vào
`run/plugin_status.tsv`. Plugin lỗi không làm hỏng batch.

Đường dẫn log có thể ép trong `conf/default.conf`:
`NGINX_ACCESS`, `NGINX_ERROR`, `APACHE_ACCESS`, `APACHE_ERROR`, `FPM_LOG`,
`AUDIT_LOG`, `SESSION_DIRS`, `WEBROOTS`; tắt plugin bằng `PLUGINS_DISABLED="..."`.

---

## 6. Build

```bash
./build.sh     # shellcheck + tests + makeself -> dist/php2shell-monitor.sh
```

Test: `bash tests/run_tests.sh` (hoặc `bats tests/unit`).

---

## 7. Triển khai + gửi về central — MỘT lệnh

```bash
sudo bash php2shell-monitor.sh \
  --project khach-hang-A \
  --chatid  812345678
```

Một lệnh làm hết, không cần bước nào khác:

1. ghi `conf/device.conf`: `PROJECT` theo `--project`, `DEVICE` = hostname máy;
2. ghép nối với central server theo **Chat ID Telegram** (private hoặc group)
   — lấy Chat ID bằng cách nhắn `/id` cho bot; ghép nối **TỰ ĐỘNG ngay**
   (không /confirm, nhiều máy không spam chat; mỗi máy nhận một API key
   riêng, key cũ vẫn sống), lưu vào `conf/central.conf` (0600);
3. bật supervisor rà log mỗi 5 phút + forwarder đẩy alert lên server
   (tail `alerts/queue.jsonl`, spool khi mất mạng);
4. in bảng tổng kết dự án / thiết bị.

| Tham số | Bắt buộc | Ý nghĩa |
|---|---|---|
| `--project` | ✅ | tên dự án khách hàng, `[A-Za-z0-9._-]{1,64}` |
| `--chatid` | ✅ | Chat ID Telegram (chat riêng dương, group âm) |

Địa chỉ central server nằm sẵn trong mã nguồn (đã obfuscate), người dùng
không cần và không nên truyền. `--server` vẫn được nhận nhưng bị bỏ qua để
không phá các lệnh cũ.

Thiếu tham số nào → script dừng và liệt kê đúng tham số còn thiếu.
**Hostname là danh tính THIẾT BỊ**, không phải tên dự án: không có tham số
`--device`, và tên dự án không bao giờ lấy từ hostname.

**Chạy lại khi thiết bị đã thiết lập** → không làm gì cả, chỉ báo và thoát:

```
╔══════════════════════════════════════════════════════════════╗
║   ℹ️   THIẾT BỊ ĐÃ ĐƯỢC THIẾT LẬP MONITOR php2Shell          ║
╚══════════════════════════════════════════════════════════════╝
 Máy này đã cài đặt và ghép nối xong — không chạy lại lệnh triển khai.

 Dự án      :  khach-hang-A
 Thiết bị    :  egghead
```

Điều kiện "đã thiết lập": `conf/device.conf` có `PROJECT` thật (khác
`default`) **và** `conf/central.conf` có `API_KEY`. Khi đó lệnh triển khai
**không** ghi đè conf, **không** gọi `register-chatid`, **không** cấp key mới,
**không** đổi chat nhận alert — kể cả khi bạn truyền `--project`/`--chatid`
khác. Cấu hình đang chạy là bất biến ngoài ý muốn.

Pair dở dang (có project nhưng mất `API_KEY`, hoặc chưa có `central.conf`)
thì **không** bị chặn: chạy lại sẽ ghép nối tiếp.

Muốn đổi dự án / chat → thêm `--force`:

```bash
sudo php2shell-monitor.sh --force \
  --project khach-hang-B \
  --chatid  999888777
```

```bash
sudo bash php2shell-monitor.sh status   # trạng thái
sudo bash php2shell-monitor.sh test     # alert thử lên Telegram
sudo bash php2shell-monitor.sh stop     # dừng
```

Chạy trần `sudo bash php2shell-monitor.sh` (không tham số) → báo thiếu tham số
và dừng. Không có wizard, không prompt: không có giá trị mặc định nào để hỏi.
Xem `../central-alert-server/README.md`.

---

## 8. Giới hạn

- Access log mặc định không có body ⇒ rule dựa vào body (upload-progress,
  multipart) chỉ sống qua ingest WAF (P2S-040).
- FPM/kernel không có IP ⇒ `ip` để trống hoặc lấy từ nguồn có IP; không suy đoán.
- Nếu host đặt `memory_limit=-1`, P2S-010 im lặng; dựa vào P2S-011/kernel.
- Dữ liệu nằm trong `/opt/php2shell-monitor` (không dùng `/tmp`, không tmpfs ⇒
  state/offset/alert sống qua reboot).
- Không tự sống lại sau reboot (không cron/systemd) ⇒ sau reboot phải chạy lại
  `sudo bash /opt/php2shell-monitor/main.sh -- run`.
