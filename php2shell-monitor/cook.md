# 🛡️ PHP2SHELL MONITOR — KẾ HOẠCH TRIỂN KHAI (PLAN v4)

> ⚠️ **Tài liệu này là bản kế hoạch lịch sử.** Mô hình đã được đơn giản hoá và
> code hiện tại không còn correlator/scoring/dedup/baseline/watcher realtime.
> Hợp đồng hiện hành: **một batch 5 phút → tối đa một alert (severity cao nhất)
> + toàn bộ dòng log gốc kèm `file:line`**, lưu theo
> `projects/<project>/devices/<device>/`.
> Đọc `README.md`, `ARCHITECTURE.md`, `docs/OPERATIONS.md` trước; các mục dưới
> đây chỉ còn giá trị tham khảo về nguồn log, rule và bối cảnh CVE.

| Mục | Giá trị |
|---|---|
| Đối tượng giám sát | Khai thác CVE-2026-109618 / CVE-2026-109619 ("PHP2Shell") + dấu vết hậu khai thác |
| Nền tảng | Bash thuần. Source tách trong `src/`, build thành **1 file `.sh` tự giải nén (makeself)**. Chạy trên Linux server, **bắt buộc root**, chạy từ thư mục bất kỳ. Không cron/systemd: 1 supervisor tự lặp batch 5 phút + watcher realtime |
| Ngôn ngữ | Tiếng Việt (plan), code/comment tiếng Anh |
| Phạm vi xuất dữ liệu | JSON (chuẩn SIEM) + SQL. **Telebot / Splunk HEC / YARA → deferred** |
| Thay đổi trên hệ thống | **Chỉ duy nhất thư mục `/opt/php2shell-monitor`** (mục 5.2). Không cron, không systemd, không user mới, không đụng `/var` `/etc` `/usr`. Không sửa log_format/FPM/php.ini/auditd — chỉ đề xuất ở mục 8 |

---

## 0. NGUYÊN TẮC BẤT DI BẤT DỊCH

1. **Read-only trên hệ thống đích**: không sửa log_format, php.ini/pool, không cài package, không bật auditd/modsec. Monitor chỉ ĐỌC log có sẵn. Mọi thứ monitor ghi (code giải nén, state, alert, export, file tạm) **chỉ nằm trong `/opt/php2shell-monitor`** (mục 5.2).
2. Mọi lệnh discovery chỉ chạy khi được duyệt, và phải là lệnh đọc. **Output discovery phải lọc theo key cần thiết, không dump toàn bộ config** (tránh lộ credential trong upstream URL, env pool, basic-auth path).
3. Monitor phải **bao phủ được hệ thống "trống"** (chỉ access log). Nguồn log = plugin; thiếu nguồn nào bỏ qua nguồn đó, không crash, và **ghi rõ rule nào bị tắt vì thiếu nguồn** vào status report.
4. Không hardcode secret. Không gửi dữ liệu ra ngoài ở phase này.
5. **Không dùng version number để kết luận "đã vá"** (backport Ubuntu ESM/CloudLinux). Dùng package changelog (read-only).
6. **Mọi timestamp chuẩn hóa về UTC** ngay tại parser (access log có offset, FPM log không có tz, journald dùng local time).
7. **Bắt buộc chạy root.** Không phải root → in thông báo và thoát (exit 1). Không tạo user/group riêng, không có chế độ "chạy giảm quyền".
8. **Chạy từ bất kỳ đâu.** File `.sh` tự đủ, không phụ thuộc cwd hay đường dẫn cài đặt; archive giải nén thẳng vào workdir cố định `/opt/php2shell-monitor`, mọi việc làm trong đó.

---

## 1. THREAT INTEL — PHP2SHELL

| Mục | Chi tiết |
|---|---|
| 2 CVE | **CVE-2026-109618**: OOM giữa chừng parse request → cleanup dùng dữ liệu request CHƯA init đầy đủ → corruption → RCE. **CVE-2026-109619**: state của request cũ còn sống sau khi memory đã freed → request sau trên cùng worker dùng stale state → RCE (+ memory disclosure) |
| Tên chiến dịch | PHP2Shell. Chi tiết bị leak 20/10/2026; advisory chính thức + bản vá 21/10/2026 |
| Version dính | Mọi bản **< 8.2.35 / 8.3.36 / 8.4.27 / 8.5.12**. Các bản vá chính thức: **8.2.35 / 8.3.36 / 8.4.27 / 8.5.12**. PHP ≤ 8.1 (EOL): **không có patch chính thức** (chỉ có bản vendor trả phí, vd HeroDevs NES). *Mốc "từ 5.4.0" chỉ là báo cáo không chính thức (Kaspersky), ghi nhận nhưng không coi là chắc chắn* |
| CVSS | **9.2 (CVSS v4.0)** cho cả hai CVE. *Mức NVD 9.8 trước đây ghi trong plan: CHƯA xác minh → bỏ cho tới khi có nguồn* |
| SAPI ảnh hưởng | **mod_php** và **PHP-FPM**. Chuỗi RCE qua `session.upload_progress` đã được xác nhận trên cả hai; với FPM cần một thao tác phù hợp ở tầng ứng dụng |
| Cơ chế | **Không có payload string để match.** Memory pressure bằng cấu trúc multipart méo: field `PHP_SESSION_UPLOAD_PROGRESS`, field name lồng sâu `a[b][c]...`, nhiều `filename=""` rỗng, body ≥5MB, POST chunked/không Content-Length, urlencoded field name ~3.5MB chứa null bytes |
| Timeline | 20/10 leak → 21/10 advisory + bản vá; watchTowr thấy exploit trên honeypot ngày 21/10; Cloudflare bật WAF rule mặc định lúc **03:02 UTC 21/10** (theo docs của break-the-build) — trước công bố. **Mốc 17/10:** detqt ghi Amazon quan sát lần thử đầu vào 17/10 (nguồn thứ cấp, một nguồn) → **giữ 17/10 làm đầu cửa sổ retro-hunt** nhưng ghi rõ độ tin cậy. *Mốc "07:43 UTC 21/10" trong plan cũ: vẫn chưa có nguồn → bỏ* |
| Giảm thiểu tạm thời (vendor) | 109618: `memory_limit=-1` qua `php_admin_value`, restart toàn bộ worker; chặn multipart ở frontend nếu không dùng. 109619: `session.upload_progress.enabled=0` đặt trong ini/server config (KHÔNG qua `ini_set()` / `.user.ini`), restart worker. Lưu ý: tắt upload_progress chỉ chặn 1 đường của 109619, **không** chặn 109618. Chỉ là biện pháp tạm, không thay thế patch. Bổ sung (break-the-build `posture-check.sh`): PHP 8.5 chưa vá cần `fatal_error_backtraces=0`; `memory_limit=-1` phải đặt ở mức admin (pool/php.ini), **không** dùng RLIMIT_AS/RLIMIT_DATA. Docs của break-the-build trích Datadog: INI stopgap "không bảo vệ" (nguồn thứ cấp, chưa kiểm) |
| Hệ quả thiết kế | Tín hiệu mạnh nằm ở **response-side + host-side**. Access log thuần chỉ cho tín hiệu yếu → phải đa nguồn. **Nếu server áp `memory_limit=-1`, rule P2S-010 (memory exhausted) sẽ im lặng → phải dựa vào kernel OOM/segfault/restart** |

---

## 2. NGUỒN RULES / MÃ NGUỒN MỞ — KẾT QUẢ ĐỌC THỰC TẾ (23/10/2026)

- Kho local của người dùng: `/home/gaban/Downloads/php2shell-monitor/repos`
- Danh sách link gốc người dùng thu thập: **Phụ lục D**.
- Lần rà này đã clone (shallow, chỉ đọc, không chạy code) và đọc file rule/test thật, không còn dựa vào tóm tắt trang web. Mã khai thác/PoC trong các repo **không được dùng**; chỉ lấy logic phát hiện.

| Nguồn | Đã đọc gì | License | Dùng cho |
|---|---|---|---|
| **Lexsah/php2shell-detection** | Suricata 910961801–803; Sigma (UA, POST + marker trong URI/query, process spawn); ModSec 9109618–20; auditd `php_worker_exec`; Falco; YARA (4 rule); mitigation ini; `tests/fixtures` (benign/malicious access log) | MIT | P2S-008, P2S-017, P2S-021, P2S-024; fixture cho bats; P2S-040 (ingest) |
| **break-the-build/php-uploadprogress-waf** | `scripts/detection_rules.py` (classifier arming/groom/oom/cookie_progress), Suricata R1/R3/R5, ModSec R1/R3/R5/R7/R8, njs, `TUNING.md`, `docs/detection-platforms.md`, `posture/posture-check.sh`, `scripts/triage_events.py` | MIT | P2S-040 (ingest), correlator "same-worker", discovery posture, bài học FP/ngưỡng |
| **jaiswalakshansh/Reversing-Vulnerabilities** | **Chỉ** `CVE-2026-109618-109619/WAF-RULES.md` (repo còn chứa PoC/lab/exploit: **không dùng**) | Không thấy file LICENSE → chỉ lấy ý tưởng/ngưỡng, tự diễn đạt lại | P2S-002/003/004 (ngưỡng, header-only) |
| **detqt (bài blog)** | Đọc qua trích xuất trang (chưa clone): chuỗi Splunk, `log_format`/`LogFormat`, FPM pool, Sigma process, lời khuyên host-side | Chưa rõ → chỉ lấy dữ kiện (chuỗi log, ngưỡng), viết lại | P2S-010/012/018/020/022/024/025 |
| **cybaverse checker** | Trang web (Sigma: POST `.php` 500, từ khóa syslog, process spawn; lệnh hunt; mã thoát). Script `check-php2shell.sh` **chưa tải về** | Chưa rõ | P2S-016, retro-hunt persistence, quy ước exit code |
| **SigmaHQ web_win_webshells_in_access_logs** | Phần `detection` | Theo license SigmaHQ (chưa kiểm) | P2S-030+ |
| **nsacyber/Mitigating-Web-Shells** | README, `LogCheck.py` (URL ít IP/UA), `anomolous_uris.splunk.txt` (4 truy vấn), HIPS | `LICENSE.md` (chưa đọc nội dung) | P2S-026 (rare-URI), đề xuất "known-good compare" (8.2) |
| **AhmetPayaslioglu/web-log-anomaly-detector** | `rules/default.yaml` (388 dòng regex OWASP) | MIT | Chọn lọc `cmdi.*` cho P2S-025/030+; bỏ SQLi/XSS/SSTI/XXE (ngoài phạm vi) |
| **WoYinDao/CVE-2026-109618…** | README phân tích 3 chuỗi (A/B/C); **không** dùng code | MIT | Chỉ để hiểu giới hạn: chain B (`var_destroy` UAF) nằm ngoài 2 CVE |
| ekky19/WebShell-Analyzer | Chưa đọc nội dung | Không thấy LICENSE | Chỉ tham khảo parser, không đưa vào pack |
| *Chưa đọc*: AWS blog, Corelight `php2shell-detect` (Zeek+Suricata, được nhắc trong docs của break-the-build), ET, Elastic, Medium, StackShield, dev.to, Red Hat/Ubuntu/NCSC | — | — | Xem lại khi cần; ứng viên: Corelight nếu host có Zeek |

> Các nhãn nguồn trong plan cũ ("Lexsah R2/R3", "AWS SizeConstraint", "detqt Datadog variant") **không khớp** với nội dung thật đã đọc; đã sửa theo SID/ID thật ở mục 6.

---

## 3. 📁 BẢN ĐỒ LOG — HỆ THỐNG CÀI ĐẦY ĐỦ STACK

> **Mục tiêu:** nếu server cài đủ mọi thứ thì log sinh ra ở đâu. Monitor thiết kế theo superset; hệ thống đơn giản hơn = tập con, từng nguồn thiếu thì skip.

### 3.1. Sơ đồ lớp nguồn log

```
 Lớp 1 (YẾU - luôn có)     : access log webserver
 Lớp 2 (MẠNH - FPM/Apache) : php-fpm master/pool/slowlog + apache/nginx error log
 Lớp 3 (MẠNH - kernel)     : journald persistent + rsyslog + dmesg (segfault/OOM)
 Lớp 4 (CHỨNG CỨ - audit)  : auditd execve/write/connect + coredumps
 Lớp 5 (BODY - hiếm có)    : ModSecurity audit log / njs capture / FPM slowlog context
 Lớp 6 (HẬU KHAI THÁC)     : session files, webroot manifest, app/CMS logs, mail/cron logs
```

### 3.2. Chi tiết theo component

#### A. Nginx (nếu cài)
| Log | Đường dẫn mặc định | Ghi chú |
|---|---|---|
| Access | `/var/log/nginx/access.log` | Format `combined` mặc định **KHÔNG có** Content-Type / Cookie / body / **`$request_length`**. Có thể có per-site: `/var/log/nginx/<site>.access.log` |
| Error | `/var/log/nginx/error.log` | Tín hiệu phụ T2: `upstream prematurely closed connection`, `recv() failed (104: Connection reset by peer)`, `upstream timed out`, 502/504 loạt |
| njs (nếu có sẵn js_access) | ghi vào nginx error log | Chỉ dùng nếu đã được cài sẵn; plan không cài |
| Lưu ý | `client_max_body_size` mặc định 1MB → request ≥5MB trả **413**, thấy được ngay trong access log mặc định. Nếu log_format đã có `$request_length` → bật rule size chính xác; nếu không → dùng 413 làm proxy | nginx buffer request body và gửi upstream kèm Content-Length → rule "chunked / không Content-Length" gần như mù với nginx |

#### B. Apache httpd (nếu cài)
| Log | Debian/Ubuntu | RHEL/CentOS |
|---|---|---|
| Access | `/var/log/apache2/access.log` (+ `other_vhosts_access.log`) | `/var/log/httpd/access_log` |
| Error | `/var/log/apache2/error.log` | `/var/log/httpd/error_log` |
| Per-vhost CustomLog | theo `sites-enabled/*` | theo `conf.d/*.conf` |
| mod_php error | trộn vào error log | như bên trái |
| **mod_php crash** | error log: `AH00052: child pid N exit signal Segmentation fault (11)` — **dấu hiệu T2/T3 cho mod_php** | như bên trái |
| ModSecurity (nếu cài) | `/var/log/apache2/modsec_audit.log` | `/var/log/httpd/modsec_audit.log` |
| Ghi chú size | `%I` cần `mod_logio`; không có thì chỉ có Content-Length client tự khai (nếu log_format lấy được) | |

#### C. PHP-FPM (nguồn mạnh nhất)
| Log | Debian/Ubuntu (vd PHP 8.2) | RHEL/CentOS |
|---|---|---|
| Master error_log | `/var/log/php8.2-fpm.log` | `/var/log/php-fpm/error.log` |
| Pool error (`php_admin_value[error_log]`) | `/var/log/php8.2-fpm/www-error.log` | `/var/log/php-fpm/www-error.log` |
| Pool access log (tùy chọn, off mặc định) | nếu bật: `/var/log/php-fpm/access.log` | như bên trái |
| Slowlog (off mặc định) | nếu bật: `/var/log/php-fpm/www-slow.log` | như bên trái |
| Worker output (`catch_workers_output=yes`, off mặc định) | trộn vào master log/journald | như bên trái |
| Không đặt error_log → journald | `journalctl -u php8.2-fpm` | `journalctl -u php-fpm` |
| Nhiều bản PHP song song (cPanel/CloudLinux) | `/var/log/php*-fpm*.log`, `/opt/alt/php*/usr/php/...`, `/usr/local/cpanel/logs/php-fpm/` | tương tự |

> ⚠️ Access log chuẩn có thể KHÔNG capture shape khai thác. Tín hiệu vàng ở FPM log: `Allowed memory size of N bytes exhausted`, `child N exited on signal 11 (SIGSEGV)`, `execution timed out`, worker restart loop.
> ⚠️ `Allowed memory size ... exhausted` rất nhiều false positive với WordPress/CMS nặng → **bắt buộc baseline theo từng pool**. Nếu server đã set `memory_limit=-1`, tín hiệu này biến mất (xem mục 1).

#### D. PHP runtime / ini
| Mục | Đường dẫn điển hình | Ghi chú |
|---|---|---|
| `error_log` ini global | `/var/log/php/error.log`, `/var/log/php_errors.log`, hoặc rỗng → stderr → FPM/journald | Discovery bằng **`php-fpm<ver> -i` / `-tt`** (READ-ONLY). **`php -i` là CLI ini, KHÔNG phản ánh FPM pool** |
| Session files (`session.save_path`) | Debian/Ubuntu: `/var/lib/php/sessions/` — RHEL: `/var/lib/php/session/` — cPanel: `/var/cpanel/php/sessions/<ver>/` — unset: `/tmp` | Key `upload_progress_<name>` **xuất hiện cả khi upload hợp lệ** (tính năng bật mặc định) → chỉ cảnh báo khi bất thường (tên lạ, size đột biến, số lượng). **Chỉ grep tên key + size, KHÔNG lưu nội dung session** (dữ liệu người dùng) |
| OPcache file cache | `/var/cache/php-opcache/`, theo `opcache.file_cache` | Variant OPcache của 109619 — discovery nếu có |

#### E. Kernel / systemd / syslog
| Log | Đường dẫn | Dấu vết |
|---|---|---|
| journald persistent | `/var/log/journal/*` (nếu `Storage=persistent`); volatile: mất khi reboot | `journalctl -k`: `php-fpm[N]: segfault at ... in php-fpm8.x`; `Out of memory: Killed process N (php-fpm)` |
| rsyslog kernel | RHEL: `/var/log/messages`, `/var/log/secure` — Debian: `/var/log/syslog`, `/var/log/kern.log` | Bản persistent khi journald volatile |
| dmesg | `dmesg` (volatile) | Nguồn phụ |
| Unit journals | `journalctl -u nginx -u apache2 -u httpd -u 'php*-fpm'` | exit signal 11, restart loop, coredump events |

#### F. Core dumps (nếu bật)
| Cơ chế | Đường dẫn |
|---|---|
| systemd-coredump | `coredumpctl list`; file `/var/lib/systemd/coredump/core.php*-fpm.*` |
| abrt (RHEL) | `/var/spool/abrt/ccpp-*/` |
| apport (Ubuntu) | `/var/crash/*.crash` |
| core_pattern tùy chỉnh | theo config |

#### G. auditd (nếu cài)
| Log | Đường dẫn | Dấu vết |
|---|---|---|
| Audit log | `/var/log/audit/audit.log` (+ rotated) | `execve` của uid www-data/nginx/php-fpm (whoami/curl/nc/sh), write `.php` vào webroot, `connect` outbound từ worker — **chứng cứ RCE thực thi**. Cần quyền đọc (group `adm`/audit hoặc root) |

#### H. App / CMS / khác
| Log | Đường dẫn | Dấu vết |
|---|---|---|
| WordPress | `wp-content/debug.log` (chỉ khi WP_DEBUG_LOG) | fatal do shell/CVE |
| Laravel | `storage/logs/laravel.log` | tương tự |
| Mail | RHEL: `/var/log/maillog` — Debian: `/var/log/mail.log` | shell spam mail |
| Cron/persistence | RHEL: `/var/log/cron` — Debian: `journalctl -u cron` + syslog | persistence |
| Package history | `/var/log/dpkg.log`, `/var/log/dnf.log`, `/var/log/yum.log` | Đối chiếu thời điểm patch vs FPM master start time |

#### I. Logrotate
- Đọc cả `access.log.1`, `access.log.2.gz`, `access.log-YYYYMMDD(.gz)` (Debian) / `access_log-YYYYMMDD` (RHEL): vừa để không miss ranh giới rotate, vừa **phục vụ retro-hunt (mục 6.6)**.

#### J. Reverse proxy / CDN (MỚI)
- Nếu có Cloudflare / LB / proxy phía trước: IP trong access log là IP proxy. Parser phải ưu tiên `X-Forwarded-For` / `CF-Connecting-IP` / `$http_x_forwarded_for` **nếu đã có trong log_format**; nếu không có → ghi nhận "IP attribution unavailable" trong alert thay vì gán nhầm IP proxy.

### 3.3. Ma trận bao phủ

| # | Nguồn log | Đủ stack | Tối thiểu (chỉ webserver) | Tier | Nếu thiếu |
|---|---|---|---|---|---|
| 1 | access log nginx/apache | ✅ | ✅ | T1 (yếu) | — |
| 2 | FPM master/pool error log | ✅ | ❌ | **T2 (vàng)** | mất tín hiệu memory-exhausted/signal 11 sớm nhất |
| 2b | Apache/nginx error log (mod_php segfault, upstream closed) | ✅ | ✅ | **T2** | — |
| 3 | FPM slowlog / pool access log | ✅ (nếu bật) | ❌ | T1/T2 context | skip |
| 4 | journald persistent / rsyslog | ✅ | ✅ (thường có) | T2/T3 segfault+OOM | chỉ còn dmesg (volatile) |
| 5 | auditd | ✅ | ❌ | **T3** | bù bằng webroot diff |
| 6 | coredumps | ✅ | ❌ | T3 (offline) | không ảnh hưởng realtime |
| 7 | ModSec audit log (BODY markers) | ✅ | ❌ | T1 mạnh nhất về body | **mất khả năng thấy `PHP_SESSION_UPLOAD_PROGRESS`/nested names** — monitor vẫn chạy với size/burst/413/fatal |
| 8 | session files | ✅ | ✅ | T2 | skip |
| 9 | webroot manifest | ✅ | ✅ | T3 webshell drop | — |
| 10 | app/CMS logs | ✅ | ❌ | T3 phụ | skip |

> Thiết kế: **monitor không bao giờ fail vì thiếu nguồn** — mỗi nguồn là plugin có check tồn tại trước khi đọc.

### 3.4. Discovery script (READ-ONLY — chỉ chạy khi được duyệt; nằm ở `src/discovery/discovery.sh`, gọi bằng `sudo bash php2shell-monitor.sh -- discover`)

```bash
#!/usr/bin/env bash
# php2shell_discovery.sh — 100% READ-ONLY. Output is key-filtered (no full config dumps).
set -u
echo "== nginx (filtered) =="
nginx -T 2>/dev/null | grep -nE '^\s*(access_log|error_log|log_format|client_max_body_size|real_ip_header|set_real_ip_from)\b' || true
echo "== apache =="; (apachectl -S 2>/dev/null || httpd -S 2>/dev/null) || true
echo "== apache logformat/customlog (filtered) =="
grep -RhE '^\s*(LogFormat|CustomLog|ErrorLog|LogLevel)\b' /etc/apache2 /etc/httpd 2>/dev/null || true
echo "== fpm units =="; systemctl list-units 'php*' --no-pager 2>/dev/null || true
echo "== fpm conf (filtered) =="
grep -RhE '^\s*(error_log|access\.log|slowlog|catch_workers_output|request_slowlog_timeout|php_admin_value\[(error_log|memory_limit)\]|php_admin_flag\[session\.upload_progress\.enabled\])' /etc/php* /etc/php-fpm* 2>/dev/null || true
echo "== fpm effective ini (NOT cli php -i) =="
for b in $(ls /usr/sbin/php-fpm* /usr/local/sbin/php-fpm* 2>/dev/null); do
  echo "-- $b"; "$b" -i 2>/dev/null | grep -E '^(error_log|memory_limit|session\.save_path|session\.upload_progress\.enabled|opcache\.file_cache)\b' || true
done
echo "== php version / sapi =="; php -v 2>/dev/null | head -1 || true
echo "== PATCH STATUS (changelog, not version number) =="
for f in /usr/share/doc/php*/changelog.Debian.gz; do [ -r "$f" ] && { echo "-- $f"; zcat "$f" | grep -nE 'CVE-2026-10961[89]' | head; }; done
(rpm -qa 'php*' 2>/dev/null | while read -r p; do echo "-- $p"; rpm -q --changelog "$p" 2>/dev/null | grep -nE 'CVE-2026-10961[89]' | head; done) || true
echo "== auditd =="; ls -l /var/log/audit/audit.log 2>/dev/null || echo "no auditd log"
echo "== coredump =="; coredumpctl list --no-pager 2>/dev/null | tail -5 || ls /var/crash /var/spool/abrt 2>/dev/null || echo "no coredump handler"
echo "== modsec =="; find /var/log -maxdepth 2 -iname '*modsec*' 2>/dev/null || true
echo "== sessions =="; ls -ld /var/lib/php/sessions /var/lib/php/session /tmp 2>/dev/null | head -3
echo "== journal persistent =="; ls -ld /var/log/journal 2>/dev/null || echo "volatile journal"
echo "== kernel segfault sample (since leak window) =="
journalctl -k --since "2026-10-17" 2>/dev/null | grep -ciE 'php-fpm.*(segfault|signal 11)' || true
echo "== rotated access logs available (retro-hunt scope) =="
ls -l /var/log/nginx/access.log* /var/log/apache2/access.log* /var/log/httpd/access_log* 2>/dev/null | head -50 || true
```

### 3.5. Điểm mù chung (đã biết)

1. **POST body KHÔNG nằm ở log mặc định.** Chỉ thấy body markers qua ModSec audit log, nginx njs/lua capture, hoặc pcap. Không có → T1 dựa vào: 413, burst, status, `$request_length` (nếu có sẵn trong log_format).
2. **Access log mặc định không có Content-Type** → monitor **không thể phân biệt multipart với loại POST khác từ access log**. Mọi rule T1 phải viết theo "POST + `.php`", không phải "multipart".
3. Custom header (X-CMD...) không vào access log — chấp nhận miss.
4. Logrotate/gzip: đọc kèm file rotate.
5. journald volatile: mất log khi reboot — rsyslog file là backup.
6. Sau proxy/CDN: IP có thể là IP proxy (mục 3.2.J).

---

## 4. MA TRẬN PHÁT HIỆN (T1 TRƯỚC — T2 ĐANG — T3 THÀNH CÔNG)

### T1 — TRƯỚC khai thác (cron 5p, access log + baseline)
> Baseline: **loại trừ khoảng 17/10 → thời điểm triển khai khỏi dữ liệu học** (có thể đã nằm trong cửa sổ tấn công). Ưu tiên học từ log rotate trước mốc đó; nếu không đủ → chế độ "learning, low confidence" và gắn nhãn alert.
- POST vào `.php` **chưa từng nhận POST** trong baseline
- POST `.php` với **status 413** (request vượt `client_max_body_size`) hoặc `$request_length` ≥ 5MB (chỉ khi log_format có sẵn field)
- Burst ≥ N POST/5p từ 1 IP → cùng URI (cơ chế 109619 cần nhiều request lên cùng worker)
- Chuỗi 499/502/504 sau POST từ cùng IP
- UA scanning + POST `.php` lạ
- `PHPSESSID` set từ path chưa từng dùng session (nếu Set-Cookie có trong log; không có → skip)
- *(Chỉ khi có ModSec/njs)* các rule body-marker ở mục 6

### T2 — ĐANG khai thác (watcher realtime ≤60s)
- Tail FPM log: `Allowed memory size ... exhausted` (so với baseline pool) / `exited on signal 11` / `execution timed out` / restart loop
- **Apache error log**: `child pid N exit signal Segmentation fault (11)` (mod_php)
- **nginx error log**: `upstream prematurely closed connection`, `recv() failed (104)`, timeout/502 loạt
- Session file: key `upload_progress_` bất thường (tên lạ / size đột biến / số lượng)
- **Correlation với access log**: FPM log không có IP và chỉ có độ phân giải 1 giây → **xuất danh sách IP ứng viên có xếp hạng + confidence**, KHÔNG khẳng định 1 IP duy nhất. Cửa sổ mặc định ±5s, mở rộng theo thời gian xử lý request (`$request_time` nếu có)

### T3 — ĐÃ thành công (watcher realtime + sweep 5p)
- Kernel log: segfault php-fpm / OOM-killer
- auditd: `execve` bởi www-data/nginx/php-fpm uid; write `.php` vào webroot; `connect` outbound từ worker
- Webroot diff: file thực thi mới/đổi (`.php .phtml .phar .php5 .inc`, `.user.ini`, `.htaccess`)
- Outbound từ worker php-fpm qua `ss -tnp` (cần quyền root để thấy process; sweep 5p có thể miss kết nối ngắn → ưu tiên auditd `connect` khi có)
- App logs: fatal khớp thời điểm

### Scoring (đầy đủ trường hợp)
```
T1 đơn lẻ                              = MEDIUM   (LOW nếu baseline đang ở chế độ learning)
T2 đơn lẻ (memory exhausted)           = LOW → MEDIUM (nếu vượt baseline pool)
T2 đơn lẻ (signal 11 / segfault)       = HIGH     (không cần T1 đi kèm)
T1 + T2 (ứng viên IP khớp trong cửa sổ) = HIGH
T2 + T3 (segfault/OOM + execve/webshell)= CRITICAL
T3 webshell drop / execve www-data     = CRITICAL (+ path file trong alert)
Bất kỳ T3 đứng riêng                    = CRITICAL
```

---

## 5. KIẾN TRÚC MONITOR (BASH — MAKESELF, ROOT, WORKDIR /tmp)

```
 BATCH loop 300s (read-only, flock)         WATCHER realtime (read-only)
 ┌─────────────────────────────┐            ┌──────────────────────────────────┐
 │ php2shell_scan.sh            │            │ php2shell_watch.sh (tail -F)      │
 │ ├─ plugin: accesslog parser  │            │ ├─ tail FPM/apache/nginx error    │
 │ ├─ plugin: fpm logs          │            │ ├─ journalctl -kf (segfault/OOM)  │
 │ ├─ plugin: kernel/rsyslog    │            │ ├─ tail auditd log (nếu có)       │
 │ ├─ plugin: session dir scan  │            │ └─ ss -tnp sweep (read-only)      │
 │ ├─ plugin: webroot manifest  │            └───────────────┬──────────────────┘
 │ └─ rules T1 + baseline       │                            │
 └──────────────┬───────────────┘                            │
                ▼                                            ▼
        ┌─────────────────────────────────────────────────────────┐
        │ CORRELATOR (state/): IP(ranked)+time+source → T1/T2/T3   │
        │ scoring + dedup → alert queue JSONL                      │
        └───────────────────────────┬─────────────────────────────┘
                                    ▼
                     Export JSON (SIEM-ready) + SQL  ← phase này dừng ở đây
                     [DEFERRED: telebot] [DEFERRED: Splunk HEC] [DEFERRED: YARA]
```

### 5.1. Yêu cầu vận hành
- Dependency trên host đích: bash 4+, gawk, grep -P, jq, coreutils, flock, tar, gzip (makeself cần tar/gzip để giải nén). Máy build cần thêm `makeself`, `shellcheck`, `bats`. **SQL target: chốt ở mục 9 (đề xuất: sinh file `.sql` thuần, không phụ thuộc sqlite3/DB client; escape giá trị để chống injection khi import)**.
- **Root bắt buộc**: `bootstrap.sh` kiểm tra `id -u` = 0 ngay dòng đầu, sai thì thoát. Nhờ vậy đọc được mọi nguồn (journal, auditd, `ss -p`, session dir, webroot) mà không phải cấp group hay xử lý quyền từng nguồn.
- **Chạy từ bất kỳ thư mục nào**; khuyến nghị gọi bằng `bash php2shell-monitor.sh -- <mode>` để không phụ thuộc quyền execute / mount `noexec` của nơi chứa file.
- **`flock`** (lock file trong `workdir/run/`) để batch và các lần chạy không chồng nhau; `nice`/`ionice` để không tranh I/O với workload chính.
- Workdir `0700`, file alert/state `0600` (chứa IP, URI). **Giới hạn dung lượng + rotate** cho alert/log của chính monitor (vì /tmp có thể là tmpfs/RAM): ví dụ tổng ≤ 200MB, giữ N ngày, cấu hình ở `conf/default.conf`.
- Dedup alert theo (rule, IP, URI, 15 phút) để tránh flood.
- **Kênh nhận alert tạm thời** (khi Telebot deferred): JSONL ở `workdir/alerts/` + dòng tóm tắt ở `workdir/run/watcher.log`, xem nhanh bằng `-- status`. Chốt người chịu trách nhiệm đọc CRITICAL ở mục 9.

### 5.2. WORKDIR — THAY ĐỔI HỆ THỐNG DUY NHẤT

| Mục | Giá trị |
|---|---|
| Đường dẫn | `/opt/php2shell-monitor` (cố định; makeself `--target`) |
| Tạo / kiểm tra | `bootstrap.sh` tự tạo bằng `mkdir -m 0700`. Nếu đã tồn tại thì phải là **thư mục thật, owner root, mode 0700, không phải symlink**, sai bất kỳ điều kiện nào → dừng, không ghi gì. Lý do: `/tmp` ghi được bởi mọi user (kể cả `www-data` sau khi bị RCE) → chặn kịch bản kẻ khác dựng sẵn thư mục/symlink để root ghi vào |
| Ghi ngoài workdir | **Không**. Mọi file tạm dùng `$WORKDIR/tmp`; makeself giải nén trực tiếp vào workdir nên không có thư mục staging nào khác |
| Đọc ngoài workdir | Chỉ đọc log/config/webroot/session theo mục 3 (read-only) |
| Không tạo | cron, systemd unit, user/group, file trong `/var` `/etc` `/usr`, thay đổi package |
| Tiến trình | 1 supervisor chạy nền (`setsid`), PID lưu ở `workdir/run/supervisor.pid` |

```
/opt/php2shell-monitor/            (0700, root)
├── bin/ lib/ plugins/ rules/ engine/ export/ discovery/   ← code giải nén (ghi đè khi chạy lại bản mới)
├── conf/        default.conf, rules.conf, whitelist.conf   ← giữ nguyên khi cập nhật code
├── state/       offsets (inode:offset), baseline, manifest ← giữ nguyên khi cập nhật code
├── alerts/      JSONL queue
├── export/      JSON + .sql
├── reports/     log-map-actual.md, retro-hunt-report.*
├── run/         supervisor.pid, lock, watcher.log, status.json
└── tmp/         TMPDIR
```

### 5.3. CẤU TRÚC SOURCE & ĐÓNG GÓI (MAKESELF)

```
php2shell-monitor/                 (repo, trên máy build)
├── VERSION
├── build.sh                       ← shellcheck → bats → makeself → sha256
├── src/
│   ├── bootstrap.sh               ← startup script của makeself (root check, seed conf/, prune code cũ, exec main)
│   ├── main.sh                    ← dispatcher CLI (discover|retro|run|status|stop|export|clean)
│   ├── lib/                       ← common.sh, log.sh, time_utc.sh, safe_fs.sh, state.sh, json.sh, sql.sh
│   ├── discovery/                 ← discovery.sh (mục 3.4), retro_hunt.sh (mục 6.6), patch_status.sh
│   ├── plugins/                   ← 1 file / nguồn log: accesslog_nginx.sh, accesslog_apache.sh, fpm.sh, apache_error.sh,
│   │                                nginx_error.sh, kernel.sh, auditd.sh, sessions.sh, webroot_manifest.sh, modsec.sh, appcms.sh
│   ├── rules/                     ← 1 file / rule hoặc nhóm: t1_*.sh, t2_*.sh, t3_*.sh (ID theo mục 6)
│   ├── engine/                    ← supervisor.sh, scan.sh (batch), watch.sh (realtime), correlator.sh, scoring.sh, baseline.sh
│   ├── export/                    ← export_json.sh, export_sql.sh
│   └── conf/                      ← default.conf, rules.conf, whitelist.conf (mẫu)
├── tests/
│   ├── fixtures/                  ← log mẫu (golden files) cho từng plugin/rule
│   └── *.bats
└── dist/
    └── php2shell-monitor.sh       ← artifact cuối: 1 file tự giải nén
```

**Build (`build.sh`):**
```bash
shellcheck -x $(find src -name '*.sh')
bats tests/
makeself --sha256 --nox11 --noprogress --gzip src dist/php2shell-monitor.sh \
         "PHP2Shell Monitor $(cat VERSION)" ./bootstrap.sh
sha256sum dist/php2shell-monitor.sh > dist/php2shell-monitor.sh.sha256
```
- Luồng chạy: `makeself --needroot --target /opt/php2shell-monitor` kiểm tra root rồi giải nén **thẳng** vào workdir → chạy `bootstrap.sh` tại đó → seed `conf/` từ `conf.default/`, xoá code cũ không còn trong `MANIFEST`, `chown root` + `chmod 0700/0600` → `cd` vào workdir → `exec main.sh "$@"`. Không có bản copy thứ hai, không staging trong `/tmp`.
- Tham số truyền cho monitor đặt sau `--`: `sudo bash php2shell-monitor.sh -- <mode>`. Không có mode → in help, **không làm gì**.
- Toàn vẹn: phát hành kèm `.sha256`; makeself tự kiểm checksum nội bộ khi giải nén.
- Lưu ý khi build: `--target`/`--needroot` cần makeself ≥ 2.2; `build.sh` dùng đúng hai cờ này nên bootstrap không phải copy payload.

### 5.4. CLI & VÒNG ĐỜI

| Mode | Việc làm | Ghi chú |
|---|---|---|
| `discover` | Chạy discovery read-only (3.4) → `reports/log-map-actual.md` + patch status | Cần được duyệt |
| `retro` | Retro-hunt (6.6) → `reports/retro-hunt-report.*` | Chạy 1 lần, an toàn chạy lại |
| `run` | Khởi động supervisor nền: batch mỗi 300s + watcher realtime + correlator | Không cron/systemd. Có `flock`: chạy lần 2 báo "đã chạy" và thoát |
| `status` | In trạng thái supervisor, plugin ON/OFF, rule ON/OFF (và vì sao), 10 alert gần nhất | Đọc `run/status.json` |
| `stop` | Dừng supervisor (theo PID file) | State giữ nguyên, `run` lại sẽ tiếp tục từ offset cũ |
| `export` | Xuất JSON + SQL vào `export/` | Người dùng tự lấy file ra (scp…) |
| `clean` | `stop` rồi xóa toàn bộ workdir | Xóa luôn state/baseline/alert |

- **Không tự khởi động lại sau reboot** (không cron/systemd) → sau reboot phải chạy lại `-- run`. Ghi rõ trong tài liệu vận hành.
- **`/tmp` có thể bị xóa khi reboot hoặc là tmpfs** → state/baseline/alert mất. Muốn giữ, chạy `export` và lấy file ra trước khi reboot.

---

## 6. RULE PACK — MAP ID → NGUỒN (đã đối chiếu rule thật)

> **Nguyên tắc tích hợp:** monitor đọc *log* chứ không phải gói tin. Rule mạng/WAF (Suricata/ModSec/njs/AWS) **không chạy trong monitor**. Có hai đường:
> 1. **Ingest đầu ra** của WAF/IDS nếu host đã có (P2S-040): đọc các dòng cảnh báo mà ModSec/njs/Suricata đã ghi.
> 2. **Port logic sang log-side/host-side** (access log, error log, kernel, `/proc`, FS) — phần còn lại của bảng.
> Rule BODY tự parse (đọc body trong ModSec audit log) là **DEFERRED**; trước mắt dùng đường ingest.

### 6.1. Bảng rule

| ID | Rule (log-side) | Nguồn (ID thật) | Cần (`needs`) | Mặc định |
|---|---|---|---|---|
| P2S-001 | Multipart POST có field `PHP_SESSION_UPLOAD_PROGRESS` (+ `PHPSESSID` trong body hoặc cookie; biến thể "không `filename=`") | Lexsah 910961802; break-the-build R1/R8; detqt 9000051 | body | **Qua P2S-040**; tự parse = DEFERRED |
| P2S-002 | Field name lồng sâu: **≥8 tầng = MEDIUM**, **≥20 = HIGH**, ≥3 chỉ hunt/LOW. Thêm: ≥96 dòng header liên tiếp trong 1 part | break-the-build R5 (ModSec ≥8; Suricata ≥96 header); detqt 9000002 (≥20); jaiswalakshansh 1009619 (≥3, **tác giả tự cảnh báo FP** với upload kiểu mảng) | body | Qua P2S-040 |
| P2S-003 | Multipart POST không Content-Length / chunked | jaiswalakshansh 1009620; break-the-build R7; detqt 9000061 (chunked + multipart: nhiều FP) | header | OFF với nginx (nginx buffer body); ON nếu log có header |
| P2S-004 | Body ≥5 MiB. **Size đơn lẻ là tín hiệu yếu** (break-the-build tự ghi "không chứng minh OOM") → chỉ LOW; R3 gốc đòi kèm field progress | break-the-build R3; Cloudflare custom (Content-Length ≥7 chữ số); fallback: status **413** | `$request_length`/`%I` hoặc 413 | ON (LOW) |
| P2S-005 | urlencoded POST có field name khổng lồ / null bytes | *Nguồn cũ ghi "detqt (Datadog variant)": **chưa xác minh** trong lần đọc này* | body | OFF |
| P2S-006 | POST + `PHPSESSID` + marker (AND) | break-the-build R1/R8 (AND-condition); jaiswalakshansh AWS rule **chỉ** khớp marker + multipart | body | Qua P2S-040 |
| P2S-007 | Marker lặp ≥2 trong 1 request; `t[]` ≥40 phần; OOM-shape: marker + ≥4 phần form-data ≥128 KiB và body ≥512 KiB | Lexsah 910961803; break-the-build classifier (`groom`, `oom`) | body | Qua P2S-040; tự parse = DEFERRED |
| **P2S-008** | **User-Agent chứa `php2shell`** (không phân biệt hoa thường) | Lexsah 910961801 + Sigma `web_php2shell_user_agent` (level high) | access log | ON. Dễ né, chỉ là IOC rẻ |
| P2S-010 | Memory/parse-exhaustion trong error log: `Allowed memory size of`, `PHP Fatal error: Out of memory`, `Hard memory limit of`, `in Unknown on line 0`; **gộp ≥5 lần / 5 phút / host** | detqt (Splunk); cybaverse Sigma syslog; fixitect | FPM/Apache error, syslog, journal, docker | ON; **im lặng nếu `memory_limit=-1`** |
| P2S-011 | `exited on signal 11` / kernel segfault / Apache `exit signal Segmentation fault (11)` | host-side; cybaverse Sigma | error log, kernel | ON |
| P2S-012 | `Set-Cookie: PHPSESSID` dài bất thường (session ID bình thường ~26–32 ký tự): **≥129 = MEDIUM**, **≥512 = HIGH** | detqt (nginx map ≥129; Suricata 9000023 / KQL ≥512) | log có Set-Cookie (nginx map / Apache `%{Set-Cookie}o`) | ON nếu log có; nếu không: DEFERRED (đề xuất augment ở 8.2) |
| P2S-013 | Session file chứa `upload_progress_` key bất thường | host-side | session dir | ON |
| P2S-014 | nginx `upstream prematurely closed connection` / `recv() failed (104)` / `upstream sent unexpected FastCGI record: 3` loạt sau POST | detqt; host-side | nginx error | ON |
| P2S-015 | POST `.php` → 413 / 499 / 502 / 504 chuỗi từ 1 IP | host-side | access log | ON |
| **P2S-016** | **POST `.php` trả 500, ≥5 lần / 10 phút từ 1 IP** | cybaverse Sigma (level low); break-the-build docs ("unusual multipart followed by repeated 500") | access log | ON |
| **P2S-017** | **POST có `PHP_SESSION_UPLOAD_PROGRESS` trong URI/query** | Lexsah Sigma `web_php_upload_progress_post` (level medium) | access log | ON |
| **P2S-018** | FPM worker thoát với **exit code 70 / 137** (137 trông giống OOM-kill, đừng bỏ qua) | detqt (Splunk) | FPM/journal | ON. *Xác nhận cách FPM in dòng này trên máy thật trước khi chốt regex* |
| **P2S-019** | Worker churn: restart nhiều hơn mức `pm.max_requests` giải thích được | break-the-build docs (Wiz) | FPM log/journal | ON, LOW |
| P2S-020 | File thực thi mới/đổi trong webroot: `.php .phtml .phar .php5 .inc .sh`, do user web ghi; sau đợt T1/T2 | NSA/DFIR; detqt | manifest | ON |
| P2S-021 | auditd `execve` của uid web (key `php_worker_exec` nếu rule đã có; uid 33 Debian/Ubuntu, 48 RHEL `apache`, 82 Alpine) | Lexsah auditd; Medium AuditD writeup | auditd | ON nếu có |
| **P2S-022** | `.user.ini` / `.htaccess` chứa `auto_prepend_file`/`php_value auto_prepend_file` | detqt | webroot | ON |
| **P2S-024** | **Quét process:** cha ∈ {`php-fpm`, `php-fpm[0-9.]+`, `php-cgi`, `lsphp`, `frankenphp`, `httpd`, `apache2`} sinh con ∈ {`sh bash dash zsh busybox python3 perl nc ncat socat curl wget`}. Khóa theo **shell** (vì `system()` chạy `sh -c`). Allowlist theo script cha + cmdline, **không** theo tên binary (mail(), ImageMagick, wkhtmltopdf, git) | Lexsah Sigma/Falco (high/critical); detqt Sigma (high); cybaverse (medium) | `/proc` (root) hoặc auditd | ON, HIGH |
| **P2S-025** | Cmdline đáng ngờ: `/dev/tcp/`, `mkfifo`, `base64 -d \|`, `bash -i`, `sh -i`, `nc -e`, `python.*socket`, chạy từ `/tmp` hoặc `/dev/shm`; user web đọc `wp-config.php`/`.env`/`settings.php` ngoài luồng app | detqt; AhmetP `cmdi.reverse_shell` | `/proc`, auditd | ON, CRITICAL nếu khớp |
| **P2S-026** | Rare-URI: URL `.php` trả 2xx nhưng chỉ có ≤5 IP hoặc ≤5 UA khác nhau; hoặc 2xx với referer trống và URI ≠ `/` | NSA `LogCheck.py` + `anomolous_uris.splunk.txt` | access log + baseline | ON, LOW (nhiều FP) |
| **P2S-027** | **Chuỗi cùng worker:** (memory/fatal error) → (PHPSESSID bất thường hoặc diagnostic pre-init) trong ≤300 giây, **khóa theo PID worker**, không khóa theo IP | break-the-build `triage_events.py` (`same_worker_error_then_cookie_anomaly`, `same_worker_producer_then_preinit_diagnostic`) | FPM log có PID (`catch_workers_output`) | ON nếu log có PID; HIGH |
| P2S-030+ | Webshell access: GET có `=whoami`, `=curl`/`=curl+`, `=wget`, `=python`/`=python3`, `=ssh`, `=certutil`, `=ipconfig`… (Sigma có cả từ khóa Windows; chỉ giữ phần dùng được trên Linux, thêm `cmd=`/`exec=`/`command=`), `.php` trong thư mục uploads | Sigma `web_win_webshells_in_access_logs`; WebShells.app; AhmetP `cmdi` | access log | ON |
| **P2S-040** | **Ingest cảnh báo WAF/IDS có sẵn** (xem 6.3) | Lexsah, break-the-build, jaiswalakshansh | WAF/IDS đang chạy | ON nếu thấy nguồn |

> P2S-001/002/003/005/006/007 là rule BODY: monitor không tự thấy body. Chúng "sống" qua P2S-040. Không có WAF/IDS → các rule này tắt và được ghi rõ trong `status`.
> **Marker động:** `session.upload_progress.name` có thể bị đổi → discovery đọc tên thật và nạp vào P2S-017/P2S-001 (rule dùng literal mặc định sẽ bị né; break-the-build `TUNING.md` cũng cảnh báo).

### 6.2. Định dạng rule pack (dữ liệu, không phải code)

Mỗi rule là một dòng JSONL trong `src/rules/pack/*.jsonl`. Engine `rule_eval.sh` chỉ hiểu vài loại matcher; thêm rule = thêm một dòng.

| Trường | Ý nghĩa |
|---|---|
| `id`, `tier`, `severity` | ID (mục 6.1), T1/T2/T3, mức mặc định |
| `source` | Danh sách plugin nguồn: `access_log`, `fpm_error`, `apache_error`, `nginx_error`, `syslog`, `journal`, `docker_logs`, `auditd`, `proc_tree`, `webroot`, `sessions`, `waf_ingest` |
| `needs` | Năng lực bắt buộc: `body`, `header`, `response`, `auditd`, `proc`. Thiếu → **rule tự tắt** và ghi lý do vào `status` |
| `match` | `type` ∈ `regex` (grep -P), `literal`, `seq` (A rồi B cùng khóa trong N giây), `proc` (cha/con), `fs` (đường dẫn/đuôi/mtime), `cfg` (kỳ vọng INI) |
| `filter`, `agg` | Lọc (vd status) và gộp (`by`, `window_s`, `min`, hoặc `dc` cho distinct count) |
| `refs`, `license`, `upstream` | Nguồn, license, tên file/commit gốc (provenance) |

Ví dụ:

```jsonl
{"id":"P2S-008","tier":"T1","source":["access_log"],"needs":[],"match":{"type":"regex","field":"ua","pcre":"(?i)php2shell"},"severity":"high","refs":["lexsah:910961801","sigma:web_php2shell_user_agent"],"license":"MIT"}
{"id":"P2S-016","tier":"T1","source":["access_log"],"needs":[],"match":{"type":"regex","field":"request","pcre":"^POST [^ ?]*\\.php(\\?| )"},"filter":{"status":[500]},"agg":{"by":"src_ip","window_s":600,"min":5},"severity":"medium","refs":["cybaverse:sigma-web-500"]}
{"id":"P2S-010","tier":"T2","source":["fpm_error","apache_error","syslog","journal","docker_logs"],"needs":[],"match":{"type":"regex","pcre":"Allowed memory size of|PHP Fatal error: +Out of memory|Hard memory limit of|in Unknown on line 0"},"agg":{"by":"host","window_s":300,"min":5},"severity":"low","refs":["detqt","cybaverse:sigma-syslog"]}
{"id":"P2S-027","tier":"T2","source":["fpm_error"],"needs":["worker_pid"],"match":{"type":"seq","a":"P2S-010","b":"P2S-012","same":"worker_pid","within_s":300},"severity":"high","refs":["break-the-build:triage_events.py"],"license":"MIT"}
{"id":"P2S-024","tier":"T3","source":["proc_tree"],"needs":["proc"],"match":{"type":"proc","parent_pcre":"(^|/)(php-fpm|php-cgi|lsphp|frankenphp|httpd|apache2)[0-9.]*$","child_pcre":"(^|/)(sh|bash|dash|zsh|busybox|python3|perl|nc|ncat|socat|curl|wget)$"},"severity":"high","refs":["lexsah:sigma-proc","detqt:sigma-proc"]}
```

- **Converter lúc build** (`tools/`, chạy trên máy build, **không** có trên máy đích): chuyển Sigma → dòng pack; trích regex/chuỗi từ Suricata/ModSec cho P2S-040. Kết quả luôn review tay, vì chuyển rule gói tin sang log-grep làm mất ngữ nghĩa.
- **Override tại chỗ:** `conf/rules.d/*.jsonl` trong workdir đè hoặc tắt rule, không cần build lại.
- **Test:** mỗi rule có ít nhất một fixture dương và một fixture âm trong `tests/fixtures/` (lấy từ Lexsah `tests/fixtures`, MIT, kèm notice).

### 6.3. P2S-040 — ingest đầu ra của WAF/IDS có sẵn

Plugin `waf_ingest` chỉ đọc, chỉ bật khi thấy nguồn. Nó tìm các dòng cảnh báo mà rule bên thứ ba đã ghi:

| Nguồn | Dấu hiệu cần khớp | Ghi chú |
|---|---|---|
| **nginx njs** (break-the-build) | Dòng trong nginx error log chứa: `PHP upload-progress field with body session id`; `PHP upload-progress field with session cookie`; `PHP upload-progress field with large multipart body`; `PHP multipart request without usable Content-Length` | Chuỗi lấy từ `php-multipart-signals.njs` (`r.log`) |
| **ModSecurity** | ID rule: Lexsah `9109618`, `9109619`, `9109620`; break-the-build `20260001`, `20260004`, `20260006`, `20260007`, `20260008`; jaiswalakshansh `1009618`–`1009620` | Định dạng dòng khác nhau giữa v2/v3 (error log vs audit log JSON): **xác nhận trên log thật**. Cần `SecRequestBodyAccess On`, và audit log phải đang ghi phần cần thiết |
| **Suricata `eve.json`** | `alert.signature_id` ∈ {910961801, 910961802, 910961803, 20260001, 20260004, 20260006} | Chỉ khi Suricata chạy trên host |
| **Corelight/Zeek** | Notice `PHP_Crash_Sequence`, `Multipart_Header_Flood`, `Large_Form_Key`, … | **Chưa đọc** repo `corelight/php2shell-detect`; ứng viên nếu có Zeek |

Mức độ: WAF/IDS chỉ *quan sát* (pass/log) nên cảnh báo từ đây là MEDIUM; HIGH khi kèm tín hiệu host-side (T2/T3) trong cùng cửa sổ.

### 6.4. Bài học từ các nguồn (để tránh lặp lỗi)

- **Một IP không định danh được một PHP worker.** break-the-build đã *gỡ* rule tương quan theo IP của chính họ vì lý do này. Correlator phải khóa theo PID worker khi log có PID; nếu không thì mọi liên kết theo IP chỉ là "ứng viên + confidence thấp".
- **Không có chuỗi payload để khớp**; tín hiệu tốt nhất ở phía response/origin: 500, lỗi memory-limit, `PHPSESSID` lạ, worker churn.
- **Ngưỡng lồng ≥3 gây FP** với upload kiểu mảng (`files[]`, `images[a][b]`); dùng 8/20 như bảng.
- **Marker có thể bị đổi tên** qua `session.upload_progress.name`.
- **Cookie `PHPSESSID` trong request upload là bình thường** (R8 của break-the-build tự ghi); đừng cảnh báo riêng lẻ.
- **`session.upload_progress.enabled=0` chỉ giảm bề mặt**: docs của break-the-build trích Datadog nói biện pháp cộng đồng này "không bảo vệ" (nguồn thứ cấp, chưa kiểm). Bản vá PHP mới là biện pháp duy nhất đầy đủ.
- **Tuyên bố "8.5.12 chưa vá hết"** (chain `var_destroy`) trong docs của break-the-build là *chưa được xác minh*; không đổi rule nào, nhưng theo dõi advisory mới.

### 6.5. Provenance & license

- Mỗi dòng pack ghi `refs`/`license`/`upstream`. Thư mục `third_party/` chứa `LICENSE`/`NOTICE` của nguồn MIT đã dùng (Lexsah, break-the-build, AhmetPayaslioglu).
- Nguồn **không thấy LICENSE** (jaiswalakshansh, ekky19) hoặc chưa rõ (detqt, cybaverse): **chỉ lấy dữ kiện** (chuỗi log, ngưỡng) và viết lại bằng lời/regex của mình, không sao chép nguyên văn.
- Sigma: kiểm license SigmaHQ trước khi nhúng rule nguyên văn.

### 6.6. RETRO-HUNT (MỚI — ưu tiên cao nhất sau discovery)
- Chạy **một lần** các rule T1/T2/T3 trên toàn bộ log hiện có + rotate (nginx/apache access+error, FPM, kernel/journal `--since 2026-10-17`, auditd rotated).
- Webroot sweep theo mtime/ctime từ **17/10/2026** (cửa sổ rộng có chủ đích, vì mốc 17/10 chưa xác minh): file thực thi mới/đổi, `.user.ini`, `.htaccess`, owner lạ.
- Session dir: liệt kê `sess_*` bất thường (size/key), không lưu nội dung.
- Output: `retro-hunt-report.md/json` + danh sách IP ứng viên + IOC (path, thời điểm).
- Nếu có hit CRITICAL: dừng triển khai monitor, chuyển sang quy trình incident response (mục 8).

---

## 7. ROADMAP (đã sắp lại theo mức khẩn cấp)

| Phase | Nội dung | Deliverable | Ước tính |
|---|---|---|---|
| P0 | Skeleton `src/`, `bootstrap.sh` (root check + workdir safe-init), `build.sh` (makeself), `main.sh` dispatcher, discovery-runner (read-only), plugin loader, **patch-status check**, chuẩn hóa UTC | `dist/php2shell-monitor.sh` chạy được `-- discover` + `log-map-actual.md` + patch status | 0.5d |
| P0.5 | **Retro-hunt** (6.6) trên log rotate + webroot sweep | `retro-hunt-report` | 0.5d |
| P1 | **Watcher realtime host-side** (FPM/Apache/nginx error, kernel, auditd) + correlator (IP ranked) + scoring + alert queue JSONL | Detect T2/T3 sớm nhất | 1d |
| P2 | Rules T1 + baseline learner (loại trừ cửa sổ tấn công) + state offset/inode-safe + dedup | Detect T1 | 1d |
| P3 | Export JSON (schema Splunk-ready, KHÔNG push) + SQL + whitelist + tune + định nghĩa alert schema | Deliverable | 0.5d |
| P4 | **Test**: smoke test bản `dist/*.sh` trên máy sạch (chạy từ cwd bất kỳ, không phải root thì bị chặn, workdir sai owner/mode/symlink thì dừng, xác nhận không ghi ngoài workdir), fixture log (golden files) cho từng plugin/rule, shellcheck + bats, replay trên staging; lab kích fatal bằng big legit upload + memory_limit thấp (không exploit thật). **Tiêu chí sign-off**: mọi rule ON có test pass; FP rate trên 24h log sạch ≤ ngưỡng chốt ở mục 9 | Sign-off | 1d |
| DEFERRED | Telebot consumer, Splunk HEC push, YARA webroot scan, ModSec/njs augment (đề xuất, cần duyệt) | Sau | — |

### Alert JSON schema (tối thiểu)
```json
{
  "ts_utc": "2026-10-23T10:12:00Z",
  "host": "…",
  "rule_id": "P2S-011",
  "tier": "T2",
  "severity": "HIGH",
  "confidence": "low|medium|high",
  "src_ip_candidates": [{"ip": "…", "score": 0.0, "via": "xff|direct|proxy"}],
  "uri": "…",
  "evidence": [{"source": "fpm_error", "file": "…", "line_ref": "inode:offset"}],
  "baseline_mode": "learned|learning",
  "notes": ""
}
```

---

## 8. RỦI RO, GIỚI HẠN & ĐỀ XUẤT (CHƯA THỰC HIỆN)

### 8.1. Rủi ro
1. Không có body log → rule BODY tắt → T1 dựa vào 413/burst/status/size.
2. FPM log có thể trỏ path khác distro mặc định → discovery bắt buộc trước.
3. Backport không đổi version → dùng package changelog, không dùng version number.
4. Access log miss POST/header → chấp nhận.
5. Baseline có thể đã chứa traffic tấn công → loại trừ cửa sổ, gắn nhãn confidence.
6. `memory_limit=-1` (mitigation) làm P2S-010 im lặng → dựa vào kernel/segfault/OOM.
7. IP attribution không chắc chắn (proxy, độ phân giải 1s) → trả danh sách ứng viên.
8. Alert không ai đọc khi Telebot deferred → chốt kênh tạm thời và người chịu trách nhiệm.

9. **`/tmp` là vùng volatile**: có thể là tmpfs (tốn RAM), bị dọn khi reboot/định kỳ (`systemd-tmpfiles`) → mất state/baseline/alert; giảm thiểu bằng giới hạn dung lượng, `export` định kỳ, và ghi rõ trong tài liệu.
10. **`/tmp` ghi được bởi mọi user** (kể cả `www-data` sau RCE): root làm việc ở đây nên bắt buộc kiểm owner/mode/symlink của workdir (5.2); không tin bất kỳ file nào trong `/tmp` ngoài workdir.
11. **Kẻ tấn công có root có thể thấy/sửa workdir** (state, alert, code) → alert chỉ đáng tin khi host chưa bị chiếm quyền cao nhất; với CRITICAL nên `export` ra ngoài ngay.
12. **Không tự sống lại sau reboot** (không cron/systemd) → khoảng trống giám sát nếu host reboot mà không ai chạy lại.

### 8.2. Đề xuất (KHÔNG tự thực hiện — cần duyệt riêng)
- **Vá PHP** lên 8.2.35 / 8.3.36 / 8.4.27 / 8.5.12 (hoặc bản vendor cho EOL). Đây là biện pháp duy nhất thực sự khắc phục; monitor chỉ phát hiện.
- Mitigation tạm: `memory_limit=-1` (php_admin_value) + restart worker; `session.upload_progress.enabled=0` trong ini/server config (không qua `ini_set`/`.user.ini`) + restart worker; chặn multipart ở frontend nếu không dùng. Lưu ý đánh đổi: ảnh hưởng P2S-010; upload_progress=0 chỉ chặn 1 đường của 109619.
- **Bảo toàn chứng cứ trước khi patch/restart** trên host nghi ngờ: restart worker xóa state trong bộ nhớ mà 109619 lợi dụng. Chụp: `ps`, `ss -tnp`, danh sách `sess_*`, bản sao log liên quan, `coredumpctl` trước khi restart.
- Augment log (cần duyệt): thêm `$request_length`, `$http_content_type`, `$request_time`, XFF vào log_format; bật FPM `slowlog`/`access.log`; ModSec/njs để thấy body markers.
- Nếu retro-hunt có hit: cô lập host, thu thập chứng cứ, rotate credential/secret của app, rà soát persistence (cron, `authorized_keys`, systemd, `.htaccess`).

---

## 9. CẦN CHỐT TRƯỚC KHI CODE

1. Cho phép chạy discovery script read-only (3.4) trên server đích? → sinh `log-map-actual.md` + patch status.
2. Stack thật: nginx? apache? mod_php hay FPM? version PHP (thuộc dải dính? đã vá theo changelog?) -> Kiem tra truoc
3. **Có CDN/WAF/reverse proxy phía trước không?** Header nào mang IP thật? Log_format hiện tại có chứa không? 
4. **Một host hay cả fleet?** (ảnh hưởng cách chạy retro-hunt và gom alert)
5. **Server đã vá chưa?** (đổi ưu tiên: nếu đã vá, vẫn cần retro-hunt vì có thể bị khai thác trước khi vá)
6. Chấp nhận mô hình v3: root bắt buộc, chỉ ghi `/opt/php2shell-monitor`, không cron/systemd (mất giám sát sau reboot cho tới khi chạy lại)?
7. Webroot + `session.save_path` chính thức của server?
8. Định dạng SQL đích (file `.sql` thuần? DB nào?) và tiêu chí FP rate cho sign-off P4?
9. **Ai nhận & xử lý alert CRITICAL** khi Telebot còn deferred, và kênh tạm thời là gì? 
10. Giữ export JSON+SQL ở P3, Telebot/Splunk/YARA deferred — confirm lần cuối?

---