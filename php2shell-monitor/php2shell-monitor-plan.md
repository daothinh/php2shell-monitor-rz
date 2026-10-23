# 🛡️ PHP2SHELL MONITOR — KẾ HOẠCH TRIỂN KHAI (PLAN)

> **TRẠNG THÁI: PLAN ONLY — CHƯA TRIỂN KHAI.**
> File này là nguồn sự thật (single source of truth) — chỉnh sửa trực tiếp trong file.
> ⚠️ Nguyên tắc: **TUYỆT ĐỐI KHÔNG SỬA bất kỳ điều gì trên hệ thống đích.** Toàn bộ bước nào chạm hệ thống phải là **read-only**, và phải được duyệt trước khi chạy.

| Mục | Giá trị |
|---|---|
| Đối tượng giám sát | Khai thác CVE-2026-109618 / CVE-2026-109619 ("PHP2Shell") + dấu vết hậu khai thác |
| Nền tảng | Bash shell thuần, chạy trực tiếp trên Linux server, cron 5 phút + watcher realtime |
| Ngôn ngữ | Tiếng Việt (plan), code/comment tiếng Anh |
| Phạm vi xuất dữ liệu | JSON (chuẩn SIEM) + SQL. **Telebot / Splunk HEC / YARA →deferred** (làm sau) |
| Thay đổi trên hệ thống | **KHÔNG.** Kể cả augment log_format/FPM/auditd — chỉ đề xuất trong plan, không tự thực hiện |

---

## 0. NGUYÊN TẮC BẤT DI BẤT DỊCH

1. **Read-only tuyệt đối** trên server đích: không sửa log_format, không sửa php.ini/pool, không cài package, không bật auditd/modsec nếu chưa có. Script monitor chỉ ĐỌC log có sẵn.
2. Mọi lệnh discovery (`nginx -T`, `php -i`, `journalctl`, `find`...) chỉ chạy khi được duyệt, và phải là lệnh đọc.
3. Monitor phải **bao phủ được cả hệ thống "trống"** (chỉ có access log) — nếu nguồn log đầy đủ hơn thì tự động ăn thêm (thiết kế nguồn log = plugin list, thiếu nguồn nào bỏ qua nguồn đó, không crash).
4. Không hardcode secret. Không gửi dữ liệu ra ngoài ở phase này.

---

## 1. THREAT INTEL — PHP2SHELL

| Mục | Chi tiết |
|---|---|
| 2 CVE | **CVE-2026-109618**: OOM giữa chừng parse request → cleanup dùng memory request CHƯA init → corruption → RCE. **CVE-2026-109619**: state request cũ không reset sau khi freed → request sau trên cùng worker dùng stale state → UAF → RCE + memory disclosure |
| Tên chiến dịch | PHP2Shell (công bố 20–21/10/2026, Wiz Research + PHP core) |
| Version dính | PHP **5.4 → 8.5.11**. Fix: **8.2.35 / 8.3.36 / 8.4.27 / 8.5.12**. PHP ≤ 8.1 EOL: **không có patch chính thức** |
| CVSS | 9.2 Critical (NVD 9.8 cho 109618) |
| SAPI ảnh hưởng | **mod_php**: khai thác trước khi app code chạy. **FPM**: ảnh hưởng qua các đường "application-stage" (upload-progress unserializer, fatal-error backtrace, OPcache variants) — khó hơn nhưng thực tế có in-the-wild |
| Cơ chế | **KHÔNG có payload string để match.** Memory pressure bằng cấu trúc multipart méo: field `PHP_SESSION_UPLOAD_PROGRESS`, field name lồng sâu `a[b][c]...` (≥3–20 cấp), nhiều `filename=""` rỗng, body ≥5MB, POST chunked/không Content-Length, urlencoded POST field name ~3.5MB chứa null bytes |
| Timing in-the-wild | Honeypot thấy attempt từ ~17/10/2026; Cloudflare báo attack 07:43 UTC 21/10; PoC public |
| Hệ quả thiết kế | Tín hiệu mạnh nằm ở **response-side + host-side** (fatal memory, segfault, worker restart, session file, webshell drop). Access log thuần chỉ cho tín hiệu yếu T1 → phải đa nguồn |

---

## 2. NGUỒN RULES / MÃ NGUỒN MỞ — THAM KHẢO TRỰC TIẾP

> Ưu tiên nguồn uy tín (vendor, agency, cộng đồng SOC recommend). Dùng để **học pattern + convert ra JSON rule nội bộ**. KHÔNG kéo rule về chạy nguyên xi — tự viết rule engine đọc JSON.

### 2.1. Nguồn chuyên cho PHP2Shell (ưu tiên cao)

| Nguồn | Link | Loại | Ghi chú học hỏi |
|---|---|---|---|
| Lexsah/php2shell-detection | https://github.com/Lexsah/php2shell-detection | Suricata rules (alert-only) | 3 rule sẵn: UA `php2shell`, multipart POST chứa `PHP_SESSION_UPLOAD_PROGRESS`, lặp ≥2 field upload-progress trong 1 request. SID 9109618xx — mẫu convert sang JSON |
| break-the-build/php-uploadprogress-waf | https://github.com/break-the-build/php-uploadprogress-waf | Multi-platform ruleset | **Quan trọng nhất**: cùng 1 bộ signal (R1–R8) triển khai cho ModSec v3 / Suricata / nginx njs / AWS WAF / Python classifier + doc phân tích giới hạn từng platform (`docs/detection-platforms.md`). Học cách viết 1 signal nhiều format |
| jaiswalakshansh WAF-RULES.md | https://github.com/jaiswalakshansh/Reversing-Vulnerabilities/blob/main/CVE-2026-109618-109619/WAF-RULES.md | Writeup + rules Cloudflare/AWS/ModSec | Giải thích vì sao khó signature (không có payload string; tín hiệu nằm ở response 500/PHPSESSID lạ). ModSec chain rules 1009618–20 (upload-progress field, nested names, lengthless multipart) — copy logic sang JSON |
| AWS Security Blog (PHP2Shell WAF) | https://aws.amazon.com/blogs/security/using-aws-waf-to-apply-mitigations-for-php2shell-rce-vulnerabilities-cve-2026-109618-and-cve-2026-109619/ | Vendor rule JSON chính thức | Custom rule CVE-109619: POST + (`PHPSESSID` trong cookie/body) + `PHP_SESSION_UPLOAD_PROGRESS` trong body — đây là **AND-condition chuẩn** cho rule P2S-006 |
| detqt — PHP2Shell hunting | https://detqt.com/blog/php2shell/index.md | Suricata PCRE đã test trên 7.0.10 | Rule SID 9000051 (upload-progress **không kèm `filename=`** — negative lookahead), 9000002 (nested ≥20), 9000061 (chunked multipart), 9000023 (PHPSESSID ≥512 chars = memory leak), 9000043. Kèm các bẫy: `request-body-limit` 100KB miss signal, `Set-Cookie` chỉ có trong `http.cookie`, `;` trong PCRE phải viết `\x3b` |
| WoYinDao/CVE-2026-109618 analysis | https://github.com/WoYinDao/CVE-2026-109618-CVSS-9.2-Critical/blob/main/README.md | Phân tích kỹ thuật | Ghi nhận Chain B (`var_destroy __destruct` reentry UAF) **không thuộc** 2 CVE — dùng để hiểu giới hạn của rule 2 CVE |
|https://www.cybaverse.co.uk/threats/php2shell-checker|

### 2.2. Advisory / vendor (nguồn sự thật về cơ chế + mitigation)

| Nguồn | Link | Vai trò |
|---|---|---|
| NCSC UK | https://www.ncsc.gov.uk/news/critical-security-issue-affecting-php | Advisory chính thức |
| Red Hat CVE-2026-109618 | https://access.redhat.com/security/cve/cve-2026-109618 | Phân tích SAPI: mod_php vs FPM, CVSS 8.1/9.8, CWE-416 |
| Red Hat Bulletin RHSB-2026-013 | https://access.redhat.com/security/vulnerabilities/RHSB-2026-013 | Mitigation + statement chính thức |
| Red Hat CVE-2026-109619 | https://access.redhat.com/security/cve/cve-2026-109619 | Cơ chế stale state |
| Ubuntu CVE-2026-109619 / 109618 | https://ubuntu.com/security/CVE-2026-109619 , https://ubuntu.com/security/CVE-2026-109618 | Trạng thái patch per-release (backport không đổi version number — bẫy cần nhớ khi check server) |
| Google Cloud blog | https://cloud.google.com/blog/products/identity-security/responding-to-core-php-vulnerabilities-cve-2026-109618-cve-2026-109619 | Tổng hợp cả 2 CVE, fixed versions, Cloud Armor approach |
| GitHub Advisories | https://github.com/advisories/GHSA-w8hw-w9fx-j79w , https://github.com/advisories/GHSA-6wmf-4rv5-p3rp | Advisory gốc PHP project |
| NVD | https://nvd.nist.gov/vuln/detail/CVE-2026-109618 , https://nvd.nist.gov/vuln/detail/CVE-2026-109619 | Dữ liệu chuẩn để map reference |
| ThreatCluster | https://threatcluster.io/cluster/php-cve-2026-109618-exploit-disclosed-6d38a87e | Timeline disclosure + in-the-wild |

### 2.3. Writeup thực chiến (triage + dấu vết host)

| Nguồn | Link | Vai trò |
|---|---|---|
| fixitect — verify FPM patched | https://fixitect.com/php2shell-cve-2026-109618-cve-2026-109619-verify-php-fpm-patched/ | **Dấu vết cần soi từ 17/10**: FPM logs nhiều multipart lạ + request chạm upload-progress; access log chuẩn có thể KHÔNG capture — cần tăng FPM logging; case staging server bị quên; memory disclosure không RCE vẫn phải rotate secrets |
| StackShield — Laravel/PHP2Shell | https://www.stackshield.io/blog/php2shell-critical-php-rce-laravel | Cơ chế multipart parse TRƯỚC app code; bẫy maintenance-mode/WAF app-level vô dụng |
| dev.to — post-patch triage | https://dev.to/harryagustiana/post-patch-triage-for-php2shell-a-practical-checklist-for-laravel-servers-and-docker-1ffd | Checklist read-only: xác nhận version đang SERVE (không phải CLI), `apt changelog \| grep CVE-2026-1096`, ps lstart php-fpm master vs package upgrade time |

### 2.4. Nguồn webshell/PRE/post-exploit (phục vụ T3, nền tảng cũ của plan v1)

| Nguồn | Link | Vai trò |
|---|---|---|
| SigmaHQ/sigma (webserver rules) | https://github.com/SigmaHQ/sigma/tree/master/rules/web/webserver_generic | Rule chuẩn webshell access-log: https://github.com/SigmaHQ/sigma/blob/master/rules/web/webserver_generic/web_win_webshells_in_access_logs.yml |
| Elastic detection-rules | https://github.com/elastic/detection-rules | Rule "Web Server Potential Command Injection Request" (pattern URL: bash -c, wget, /dev/tcp, base64, cron paths) |
| NSA Mitigating-Web-Shells | https://github.com/nsacyber/Mitigating-Web-Shells | Heuristic rare-URI-success (LogCheck.py) — phục vụ anomaly T1 |
| Emerging Threats (Suricata open) | https://rules.emergingthreats.net/open/suricata/rules/ | emerging-user_agents.rules, emerging-hunting.rules, emerging-exploit.rules |
| WebShells.app blog | https://www.webshells.app/en/blog/yara-and-sigma-rules-for-web-shells | Sigma web-request rule: `cmd=|exec=|command=` trên script files |
| CpanelInc YARA (rupde rules) | https://raw.githubusercontent.com/CpanelInc/tech-CSI/master/php_webshell_rules.yara | YARA file-based (dùng sau khi YARA phase bật) |
| WebShell-Analyzer | https://github.com/ekky19/WebShell-Analyzer | Tool đối chiếu cách parse IIS/Apache/Nginx |
| web-log-anomaly-detector | https://github.com/AhmetPayaslioglu/web-log-anomaly-detector | 90+ regex OWASP/webshell — tham khảo tuning FP |
| Medium — access log/WAF/AuditD | https://medium.com/@p.matkovski/detection-of-php-web-shells-with-access-log-waf-and-audit-deamon-e798d4c95ec | Chứng minh access log mặc định miss POST/header-cmd → phải đa nguồn |

---

## 3. 📁 BẢN ĐỒ LOG — HỆ THỐNG CÀI ĐẦY ĐỦ STACK

> **Mục tiêu:** xác định NGAY tại đây: nếu server cài đủ mọi thứ (LEMP + LAMP + FPM + auditd + journald persistent + rsyslog + coredump + ModSecurity + app log) thì log sinh ra ở đâu. Monitor thiết kế theo superset này; **hệ thống đơn giản hơn = tập con** — từng nguồn thiếu thì skip, độ phủ giảm dần có kiểm soát.

### 3.1. Sơ đồ lớp nguồn log

```
 Lớp 1 (YẾU - luôn có)     : access log webserver
 Lớp 2 (MẠNH - FPM)        : php-fpm master/pool/slowlog/worker logs
 Lớp 3 (MẠNH - kernel)     : journald persistent + rsyslog + dmesg (segfault/OOM)
 Lớp 4 (CHỨNG CỨ - audit)  : auditd execve/write + coredumps
 Lớp 5 (BODY - hiếm có)    : ModSecurity audit log / njs capture / FPM slowlog context
 Lớp 6 (HẬU KHAI THÁC)     : session files, webroot manifest, app/CMS logs, mail/cron logs
```

### 3.2. Chi tiết theo component

#### A. Nginx (nếu cài)
| Log | Đường dẫn mặc định | Ghi chú |
|---|---|---|
| Access | `/var/log/nginx/access.log` | Format mặc định `combined` **không có** Content-Type/Cookie/body. Có thể tự đặt per-site: `/var/log/nginx/<site>.access.log` |
| Error | `/var/log/nginx/error.log` | Upstream timeout/502 khi FPM chết — tín hiệu phụ T2 |
| njs (nếu cài js_access) | ghi vào nginx error log | Cơ chế duy nhất trên nginx thấy field name multipart mà không cần ModSec (chỉ khi ai đó đã cài sẵn — plan không cài) |
| Lưu ý field | `$request_length` = kích thước request + body → **dùng được cho rule size ≥5MB mà không cần augment**. `$content_length` là header client gửi | Apache tương đương cần `mod_logio` (%I) — nếu không có thì chỉ có header Content-Length client tự khai |

#### B. Apache httpd (nếu cài)
| Log | Debian/Ubuntu | RHEL/CentOS |
|---|---|---|
| Access | `/var/log/apache2/access.log` (+ `other_vhosts_access.log`) | `/var/log/httpd/access_log` |
| Error | `/var/log/apache2/error.log` | `/var/log/httpd/error_log` |
| Per-vhost CustomLog | theo `sites-enabled/*` | theo `conf.d/*.conf` |
| mod_php error | trộn vào error log (trừ khi vhost đặt `php_value error_log`) | như bên trái |
| ModSecurity (nếu cài) | `/var/log/apache2/modsec_audit.log` | `/var/log/httpd/modsec_audit.log` |

#### C. PHP-FPM (nguồn mạnh nhất)
| Log | Debian/Ubuntu (vd PHP 8.2) | RHEL/CentOS |
|---|---|---|
| Master error_log (`php-fpm.conf`) | `/var/log/php8.2-fpm.log` | `/var/log/php-fpm/error.log` |
| Pool error (`php_admin_value[error_log]`) | `/var/log/php8.2-fpm/www-error.log` | `/var/log/php-fpm/www-error.log` |
| Pool access log (`access.log` directive — tùy chọn, off mặc định) | thường không bật → nếu bật: `/var/log/php-fpm/access.log` | như bên trái |
| Slowlog (`slowlog` + `request_slowlog_timeout` — off mặc định) | thường không bật → nếu bật: `/var/log/php-fpm/www-slow.log` | như bên trái |
| Worker output (`catch_workers_output=yes` — off mặc định) | trộn vào master log/journald | như bên trái |
| Không đặt error_log → journald | `journalctl -u php8.2-fpm` | `journalctl -u php-fpm` |
| PHP-FPM versions nhiều bản cài song song (cPanel/CloudLinux) | `/var/log/php*-fpm*.log`, `/opt/alt/php*/usr/php/...`, `/usr/local/cpanel/logs/php-fpm/` | tương tự |

> ⚠️ Cảnh báo từ fixitect: access log chuẩn có thể KHÔNG capture được shape khai thác — FPM log (fatal memory exhausted + request chạm upload-progress) là nơi đáng tin hơn. Signal vàng: `Allowed memory size of N bytes exhausted (tried to allocate N)`, `child N exited on signal 11 (SIGSEGV)`, `script ... execution timed out`, worker restart loop.

#### D. PHP runtime / ini
| Mục | Đường dẫn điển hình | Ghi chú |
|---|---|---|
| `error_log` ini global | `/var/log/php/error.log`, `/var/log/php_errors.log`, hoặc rỗng → stderr → FPM/journald | Phải discovery bằng `php -i` READ-ONLY |
| Session files (`session.save_path`) | Debian/Ubuntu: `/var/lib/php/sessions/` — RHEL: `/var/lib/php/session/` — cPanel: `/var/cpanel/php/sessions/<ver>/` — unset: `/tmp` | File `sess_*` chứa key `upload_progress_<name>` bất thường/to bất thường = dấu vết abuse T2 |
| OPcache file cache (nếu cấu hình) | `/var/cache/php-opcache/`, theo `opcache.file_cache` | Variant WordPress-OPcache của 109619 — discovery nếu có |

#### E. Kernel / systemd / syslog
| Log | Đường dẫn | Dấu vết |
|---|---|---|
| journald persistent | `/var/log/journal/*` (nếu `Storage=persistent`) — nếu volatile: chỉ `journalctl` tới khi reboot | `journalctl -k`: `php-fpm[N]: segfault at ... error 4 in php-fpm8.x...`; `Out of memory: Killed process N (php-fpm)` |
| rsyslog kernel | RHEL: `/var/log/messages`, `/var/log/secure` — Debian: `/var/log/syslog`, `/var/log/kern.log` | Đây là bản persistent của kernel log khi journald volatile |
| dmesg ring buffer | `dmesg` (volatile — mất khi reboot) | Nguồn phụ, monitor vẫn đọc |
| Unit journals | `journalctl -u nginx -u apache2 -u httpd -u 'php*-fpm'` | Child exit signal 11, restart loop, coredump events |

#### F. Core dumps (nếu bật)
| Cơ chế | Đường dẫn |
|---|---|
| systemd-coredump | `coredumpctl list` ; file: `/var/lib/systemd/coredump/core.php*-fpm.*` |
| abrt (RHEL) | `/var/spool/abrt/ccpp-*/` |
| apport (Ubuntu) | `/var/crash/*.crash` |
| kernel.core_pattern tùy chỉnh | theo config (vd `/var/crash/core.%e.%p`) |

#### G. auditd (nếu cài)
| Log | Đường dẫn | Dấu vết |
|---|---|---|
| Audit log | `/var/log/audit/audit.log` (+ rotated) | `execve` của uid www-data/nginx/php-fpm (whoami/curl/nc), write `.php` vào webroot — **chứng cứ RCE thực thi** |

#### H. App / CMS / khác
| Log | Đường dẫn | Dấu vết |
|---|---|---|
| WordPress | `wp-content/debug.log` (chỉ khi WP_DEBUG_LOG) | fatal do shell/CVE |
| Laravel | `storage/logs/laravel.log` (trong webroot) | tương tự |
| Mail (PHP `mail()` abuse) | RHEL: `/var/log/maillog` — Debian: `/var/log/mail.log` | shell spam mail |
| Cron/persistence | RHEL: `/var/log/cron` — Debian: journalctl -u cron + `/var/log/syslog` | attacker persistence |
| Package history (đối chiếu patch time) | `/var/log/dpkg.log`, `/var/log/dnf.log`, `/var/log/yum.log` | Xác nhận PHP được patch lúc nào so với FPM master start time |

#### I. Logrotate — file phải quét thêm
- `access.log.1`, `access.log.2.gz`, `access.log-YYYYMMDD`, `access.log-YYYYMMDD.gz` (Debian) / `access_log-YYYYMMDD` (RHEL) — monitor đọc **cả file rotate của ngày hiện tại** để không miss ranh giới rotate.

### 3.3. Ma trận bao phủ: đủ stack vs đơn giản

| # | Nguồn log | Đủ stack | Stack tối thiểu (chỉ webserver) | Tier phục vụ | Nếu thiếu |
|---|---|---|---|---|---|
| 1 | access log nginx/apache | ✅ | ✅ | T1 (yếu) | — |
| 2 | FPM master/pool error log | ✅ | ❌ | **T2 (vàng)** | mất tín hiệu memory-exhausted sớm nhất |
| 3 | FPM slowlog / pool access log | ✅ (nếu bật) | ❌ | T1/T2 context | skip |
| 4 | journald persistent / rsyslog | ✅ | ✅ (thường có) | T2/T3 segfault+OOM | chỉ còn dmesg (volatile) |
| 5 | auditd | ✅ | ❌ | **T3 (RCE thực thi)** | bù bằng webroot diff |
| 6 | coredumps | ✅ | ❌ | T3 (offline evidence) | không ảnh hưởng realtime |
| 7 | ModSec audit log (BODY markers) | ✅ | ❌ | T1 (mạnh nhất về body) | **mất hoàn toàn khả năng thấy `PHP_SESSION_UPLOAD_PROGRESS`/nested names** — monitor vẫn chạy với size/burst/fatal |
| 8 | session files | ✅ | ✅ (PHP nào cũng có) | T2 | skip |
| 9 | webroot manifest | ✅ | ✅ | T3 webshell drop | — |
| 10 | app/CMS logs | ✅ | ❌ | T3 phụ | skip |

> Thiết kế: **monitor không bao giờ fail vì thiếu nguồn** — mỗi nguồn là plugin có check tồn tại trước khi đọc.

### 3.4. Discovery script (READ-ONLY — chỉ chạy khi được duyệt)

```bash
#!/usr/bin/env bash
# php2shell_discovery.sh — 100% READ-ONLY. Mapping log thực tế trên server.
echo "== nginx ==";   nginx -T 2>/dev/null | grep -nE 'access_log|error_log' || true
echo "== apache ==";  (apachectl -S 2>/dev/null || httpd -S 2>/dev/null) || true
echo "== fpm units =="; systemctl list-units 'php*' --no-pager 2>/dev/null || true
echo "== fpm conf =="; grep -RhE '^(error_log|access.log|slowlog|catch_workers_output|php_admin_value\[error_log\])' /etc/php* /etc/php-fpm* 2>/dev/null || true
echo "== php ini =="; php -i 2>/dev/null | grep -E '^(error_log|session\.save_path|opcache\.file_cache)' || true
echo "== auditd ==";  ls -l /var/log/audit/audit.log 2>/dev/null || echo "no auditd log"
echo "== coredump =="; coredumpctl list --no-pager 2>/dev/null | tail -5 || ls /var/crash /var/spool/abrt 2>/dev/null || echo "no coredump handler"
echo "== modsec ==";  find /var/log -maxdepth 2 -iname '*modsec*' 2>/dev/null || true
echo "== sessions =="; ls -ld /var/lib/php/sessions /var/lib/php/session /tmp 2>/dev/null | head -3
echo "== journal persistent =="; ls -ld /var/log/journal 2>/dev/null || echo "volatile journal"
echo "== kernel segfault sample =="; journalctl -k --since "2026-10-17" 2>/dev/null | grep -ciE 'php-fpm.*(segfault|signal 11)' || true
```

### 3.5. Điểm mù chung (đã biết, ghi nhận để không kỳ vọng sai)

1. **POST body KHÔNG nằm ở bất kỳ log mặc định nào.** Chỉ thấy markers body (`PHP_SESSION_UPLOAD_PROGRESS`, nested names, null bytes) qua: ModSec audit log, nginx njs/lua capture, hoặc pcap. Không có → T1 dựa vào size ($request_length), burst, và status.
2. Custom header (X-CMD, Accept-Language cmd...) không vào access log — chấp nhận miss, ghi trong doc.
3. Logrotate/gzip: đọc kèm file rotate.
4. journald volatile: mất log khi reboot — rsyslog file là bản backup khi có.

---

## 4. MA TRẬN PHÁT HIỆN (T1/TRƯỚC — T2/ĐANG — T3/THÀNH CÔNG)

### T1 — TRƯỚC khai thác (cron 5p, access log + baseline 7 ngày)
- POST multipart vào URI không có trong baseline upload
- POST `.php` với `$request_length`/Content-Length ≥ 5MB
- POST multipart không Content-Length / chunked (nếu thấy được header)
- Burst ≥ N POST/5p từ 1 IP → cùng URI (chấm worker — cơ chế 109619)
- UA scanning + POST .php lạ
- `PHPSESSID` được set từ path chưa từng dùng session

### T2 — ĐANG khai thác (watcher realtime ≤60s)
- Tail FPM log: `Allowed memory size ... exhausted` / `exited on signal 11` / timed out
- Correlate ±3s với access log → định danh IP attacker
- Session file bỗng chứa `upload_progress_` key lạ / to đột biến
- nginx error log: 502/timeout loạt từ 1 IP

### T3 — ĐÃ thành công (watcher realtime + sweep 5p)
- Kernel log: segfault php-fpm / OOM-killer
- auditd: `execve` www-data, write `.php` webroot
- Webroot diff: `.php` mới / owner www-data so manifest
- Outbound conn mới từ worker php-fpm (`ss -tnp` — read-only)
- App logs: fatal khớp thời điểm

### Scoring
```
T1 đơn lẻ              = MEDIUM
T1 + T2 cùng IP/giờ    = HIGH
T2 + T3 (segfault/OOM) = CRITICAL
T3 webshell drop       = CRITICAL (+ path file trong alert)
```

---

## 5. KIẾN TRÚC MONITOR (BASH — KHÔNG CHẠM HỆ THỐNG)

```
 CRON 5p (batch, read-only)                 WATCHER realtime (systemd unit, read-only)
 ┌─────────────────────────────┐            ┌──────────────────────────────────┐
 │ php2shell_scan.sh            │            │ php2shell_watch.sh (tail -F)      │
 │ ├─ plugin: accesslog parser  │            │ ├─ tail FPM error/pool logs       │
 │ ├─ plugin: fpm logs          │            │ ├─ journalctl -kf (segfault/OOM)  │
 │ ├─ plugin: kernel/rsyslog    │            │ ├─ tail auditd log (nếu có)       │
 │ ├─ plugin: session dir scan  │            │ └─ ss -tnp sweep (read-only)      │
 │ ├─ plugin: webroot manifest  │            └───────────────┬──────────────────┘
 │ └─ rules T1 + baseline       │                            │
 └──────────────┬───────────────┘                            │
                ▼                                            ▼
        ┌─────────────────────────────────────────────────────────┐
        │ CORRELATOR (state/): ghép IP+time+source → T1/T2/T3      │
        │ scoring → alert queue JSONL (/var/lib/php2shell/alerts/) │
        └───────────────────────────┬─────────────────────────────┘
                                    ▼
                     Export JSON (SIEM-ready) + SQL  ← phase này dừng ở đây
                     [DEFERRED: telebot] [DEFERRED: Splunk HEC] [DEFERRED: YARA]
```

- Toàn bộ script cài ở `/opt/php2shell/` (chỉ có script + state của monitor là file MỚI — không đụng file hệ thống).
- Dependency: bash 4+, gawk, grep -P, curl (deferred), jq, coreutils. Không pip/apt.
- Mỗi plugin nguồn log = check tồn tại → skip nếu vắng. **Bao phủ superset, chạy được trên subset.**

---

## 6. RULE SEED — MAP ID → NGUỒN

| ID | Rule | Nguồn tham khảo (link ở mục 2) |
|---|---|---|
| P2S-001 | Multipart POST chứa `PHP_SESSION_UPLOAD_PROGRESS` **không kèm `filename=`** | Lexsah R2, detqt 9000051 (PCRE lookahead) |
| P2S-002 | Field name lồng sâu ≥3–20 cấp `a[b][c]` | break-the-build R5, jaiswalakshansh ModSec 1009619, detqt 9000002 |
| P2S-003 | Multipart POST không Content-Length / chunked | jaiswalakshansh 1009620, detqt 9000061 |
| P2S-004 | POST `.php` + body ≥5MB (`$request_length`) | AWS SizeConstraint, break-the-build R3 |
| P2S-005 | urlencoded POST field name khổng lồ / null bytes | detqt (Datadog variant) |
| P2S-006 | POST + `PHPSESSID` (cookie/body) + `PHP_SESSION_UPLOAD_PROGRESS` (AND) | AWS WAF bulletin rule |
| P2S-007 | Lặp ≥2 field upload-progress trong 1 request | Lexsah R3 (sid 910961803) |
| P2S-010 | FPM fatal `Allowed memory size ... exhausted` | host-side, fixitect signal |
| P2S-011 | FPM `exited on signal 11` / kernel segfault | host-side |
| P2S-012 | Response `PHPSESSID` ≥512 chars (memory leak) | detqt 9000023 (cần nguồn log response — augment deferred) |
| P2S-013 | Session file chứa `upload_progress_` key bất thường | host-side |
| P2S-020 | `.php` mới trong webroot sau đợt T1/T2 | NSA/DFIR pattern |
| P2S-021 | auditd execve www-data | Medium AuditD writeup |
| P2S-030+ | Webshell access pattern (cmd=, tên shell, .php trong uploads) | Sigma web_win_webshells, ET, errorlogs patterns |

> ⚠️ P2S-001/002/005/006/007 cần thấy BODY → chỉ enable tự động khi phát hiện ModSec/njs có sẵn. Không có → rule stays disabled, không tự bật, không tự cài gì.

---

## 7. ROADMAP

| Phase | Nội dung | Deliverable |
|---|---|---|
| P0 (0.5d) | Skeleton, config, discovery-runner (read-only), plugin loader | Khung + file log-map thực tế của server |
| P1 (1d) | Rules T1 + baseline learner + engine + state offset/inode-safe | Detect T1 |
| P2 (1d) | Watcher realtime + correlator + scoring + alert queue JSONL | Detect T2/T3 kịp thời |
| P3 (0.5d) | Export JSON (schema Splunk-ready, KHÔNG push) + SQL + whitelist + tune | Deliverable |
| P4 (0.5d) | Test lab: replay request shape bằng big legit upload + memory_limit thấp để kích fatal (không exploit thật) | Sign-off |
| DEFERRED | Telebot consumer (interface sẵn), Splunk HEC push, YARA webroot scan, ModSec/njs augment (đề xuất, cần duyệt) | Sau |

---

## 8. RỦI RO & GIỚI HẠN

1. Không có body log → các rule body-marker tắt → độ phủ T1 phụ thuộc size/burst/fatal correlation.
2. FPM log có thể trỏ path khác distro mặc định → discovery bắt buộc trước khi chạy.
3. Backport không đổi version (Ubuntu ESM/CloudLinux) → không dùng version number để kết luận đã vá; dùng package changelog (read-only).
4. Access log miss POST/header → chấp nhận, đã ghi mục 3.5.
5. Watcher cần systemd unit (file mới trong /etc/systemd/system — **cần duyệt**, là thay đổi hệ thống duy nhất của plan; fallback: `nohup` loop từ cron @reboot).

---

## 9. CẦN CHỐT TRƯỚC KHI CODE

1. Cho phép chạy discovery script read-only (mục 3.4) trên server đích? → sinh `log-map-actual.md`
2. Stack thật: nginx? apache? mod_php hay FPM? version PHP nào (thuộc 5.4–8.5.11? đã vá?)
3. Chấp nhận systemd unit cho watcher (thay đổi hệ thống duy nhất) hay ép cron-only?
4. Webroot + session.save_path chính thức của server?
5. Giữ export JSON+SQL ở P3, tele/splunk/yara deferred — confirm lần cuối?

---

## 10. NHẬT KÝ THAY ĐỔI PLAN

| Ngày | Thay đổi |
|---|---|
| v1 | Plan ban đầu: webshell monitor tổng quát (access log, ~115 rules, tele/splunk/yara) |
| v2 | Trọng tâm PHP2Shell (CVE-2026-109618/109619), đa nguồn log host, T1/T2/T3, tele/splunk/yara deferred |
| v3 | Tạo file plan này; thêm mục 2 (link nguồn rules mã nguồn mở, ưu tiên uy tín); thêm mục 3 (bản đồ log đầy đủ-stack superset + ma trận subset + discovery script read-only); cam kết zero-change hệ thống |
