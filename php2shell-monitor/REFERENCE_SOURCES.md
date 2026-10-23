# 📚 PHP2SHELL DETECT — TỔNG HỢP NGUỒN THAM KHẢO

**Mục đích**: Tập hợp kinh nghiệm từ các nguồn uy tín để hiểu sâu cơ chế PHP2Shell trước khi triển khai monitor.

**Trạng thái**: Sinh thời 2026-10-23 (CVE công bố 20-21/10/2026)

---

## 📋 PHẦN 1: THREAT INTELLIGENCE — CƠ CHẾ CVE-2026-109618/109619

### 1.1. Tóm tắt sơ cấp

| Mục | Chi tiết |
|-----|---------|
| **CVE-2026-109618** | Out-of-Memory giữa chừng parse request body → cleanup xóa memory chưa init → heap corruption → RCE. Ảnh hưởng **mod_php** trước khi app code chạy. |
| **CVE-2026-109619** | Use-After-Free: state request cũ không reset sau khi freed → request tiếp theo trên worker cùng dùng stale state → UAF + memory disclosure. Ảnh hưởng **FPM** qua upload-progress unserializer + OPcache + fatal backtrace. |
| **Tên chiến dịch** | PHP2Shell (công bố 20–21/10/2026, Wiz Research + PHP core team) |
| **CVSS score** | NVD 9.8 (109618), 9.2 (109619) — Critical |
| **PHP version dính** | **5.4 → 8.5.11**. Fixed: **8.2.35 / 8.3.36 / 8.4.27 / 8.5.12**. PHP ≤8.1 EOL: không có patch chính thức |
| **Khác biệt mod_php vs FPM** | mod_php: RCE trực tiếp từ malformed request. FPM: phức tạp hơn, cần kết hợp upload-progress + reentry/backtrace. |
| **Thời gian in-the-wild** | Honeypot: ~17/10/2026. Cloudflare: 07:43 UTC 21/10. PoC public. |

### 1.2. Cơ chế khai thác chi tiết

#### Payload shape (KHÔNG có string signature)

Attacker gửi request POST multipart được **cấu trúc sai mục đích**:

1. **Field `PHP_SESSION_UPLOAD_PROGRESS`** (thường dùng để track upload):
   - Không kèm `filename=""` (cơ chế báo lệnh cho PHP parse)
   - Hoặc kèm tên field lồng sâu: `PHP_SESSION_UPLOAD_PROGRESS[a[b[c[d...]]]`

2. **Nested field names ≥ 3–20 cấp**:
   ```
   POST / HTTP/1.1
   Content-Type: multipart/form-data; boundary=xxx
   
   --xxx
   Content-Disposition: form-data; name="a[b[c[d[e[...]]]]]]"; filename=""
   --xxx
   ```

3. **Body kích thước ≥ 5MB** (hoặc chunked encoding):
   - Kích thích memory allocate → trigger OOM parser
   - Không có/không đúng Content-Length header

4. **NULL bytes trong POST field name**:
   - Variant urlencoded: field name ~3.5MB chứa `\x00` bytes
   - Gây logic confuse trong string parse

#### Hậu quả

- **Lập tức** (T2): FPM log: `Allowed memory size N bytes exhausted (tried to allocate M)`
- **Tiếp theo** (T3): Segfault `SIGSEGV (signal 11)` → worker restart loop
- **Nếu RCE** (T3): Kiểm soát memory → execute arbitrary code trước khi app code chạy

---

## 📚 PHẦN 2: NGUỒN RULES / MÃ NGUỒN MỞ

### 2.1. Ưu tiên cao — Chuyên cho PHP2Shell

#### 🔗 Lexsah/php2shell-detection
- **Link**: https://github.com/Lexsah/php2shell-detection
- **Loại**: Suricata rules (alert-only)
- **Học hỏi gì**:
  - 3 rule cơ bản (R1-R3):
    - R1: User-Agent chứa `php2shell`
    - R2: Multipart POST chứa `PHP_SESSION_UPLOAD_PROGRESS` **không kèm** `filename=`
    - R3: Lặp ≥2 field `upload-progress` trong 1 request
  - SID 9109618xx — mẫu convert sang JSON rule engine
- **Tài liệu**: README giải thích tín hiệu từng rule

#### 🔗 break-the-build/php-uploadprogress-waf ⭐ **QUAN TRỌNG NHẤT**
- **Link**: https://github.com/break-the-build/php-uploadprogress-waf
- **Loại**: Multi-platform ruleset
- **Học hỏi gì**:
  - **8 signal (R1–R8)** — cùng 1 tập logic được triển khai cho:
    - ModSecurity v3 (`.conf` format)
    - Suricata (`.rules` format)
    - nginx njs (JavaScript)
    - AWS WAF (JSON)
    - Python classifier
  - `docs/detection-platforms.md`: phân tích **giới hạn & FP từng platform** → học cách realist
  - Thiết kế plugin-based → cách tổ chức tốt để mở rộng
- **Tài liệu**: Comprehensive — cách viết 1 signal cho nhiều target

#### 🔗 jaiswalakshansh WAF-RULES
- **Link**: https://github.com/jaiswalakshansh/Reversing-Vulnerabilities/blob/main/CVE-2026-109618-109619/WAF-RULES.md
- **Loại**: Writeup + rules (Cloudflare/AWS/ModSec)
- **Học hỏi gì**:
  - **Vì sao khó signature**: Không có payload string cố định → phải dựa vào structure + behavior
  - Tín hiệu: response 500 + lạ `PHPSESSID`, memory log markers
  - ModSec **chain rules** (1009618–1009620):
    - Rule 1: Upload-progress field existence
    - Rule 2: Nested field name depth ≥20
    - Rule 3: Lengthless multipart / chunked
  - Logic: convert qua JSON logic gate (AND/OR/NOT)

#### 🔗 AWS Security Blog — PHP2Shell WAF
- **Link**: https://aws.amazon.com/blogs/security/using-aws-waf-to-apply-mitigations-for-php2shell-rce-vulnerabilities-cve-2026-109618-and-cve-2026-109619/
- **Loại**: Vendor official rule JSON
- **Học hỏi gì**:
  - **CVE-109619 rule** (chuẩn AND-condition):
    ```
    POST 
    + (PHPSESSID trong cookie HOẶC body) 
    + PHP_SESSION_UPLOAD_PROGRESS trong body
    → ALERT
    ```
  - P2S-006 reference rule
  - AWS WAF JSON syntax → mẫu chuẩn hóa

#### 🔗 detqt — PHP2Shell hunting
- **Link**: https://detqt.com/blog/php2shell/index.md
- **Loại**: Suricata PCRE (production-tested trên 7.0.10)
- **Học hỏi gì**:
  - **5 rule chính**:
    - SID 9000051: `PHP_SESSION_UPLOAD_PROGRESS` **KHÔNG kèm** `filename=` (negative lookahead)
    - SID 9000002: nested field name ≥20 cấp
    - SID 9000061: chunked multipart encoding
    - SID 9000023: `PHPSESSID` ≥512 chars (memory leak variant)
    - SID 9000043: (supplementary)
  - **Bẫy PCRE cần nhớ**:
    - `request-body-limit` 100KB → miss body signal nếu body > 100KB
    - `Set-Cookie` chỉ ở field `http.cookie`, không phải `http.response-headers`
    - `;` trong PCRE phải escape `\x3b`
  - Regex pattern → convert sang grep -P

#### 🔗 WoYinDao/CVE-2026-109618 analysis
- **Link**: https://github.com/WoYinDao/CVE-2026-109618-CVSS-9.2-Critical/blob/main/README.md
- **Loại**: Technical analysis
- **Học hỏi gì**:
  - Chain B (`var_destroy __destruct` reentry UAF) = **NOT part of 2 CVE**
  - Giúp hiểu **giới hạn** của rule 2 CVE
  - Giới hạn nào cần acknowledge trong doc

#### 🔗 cybaverse.co.uk — PHP2Shell Checker
- **Link**: https://www.cybaverse.co.uk/threats/php2shell-checker
- **Loại**: Advisory + technical
- **Học hỏi gì**: Tóm tắt nhanh UK perspective

---

### 2.2. Advisory / Vendor — Nguồn sự thật cơ chế + mitigation

| Nguồn | Link | Vai trò | Điểm học |
|-------|------|--------|---------|
| **NCSC UK** | https://www.ncsc.gov.uk/news/critical-security-issue-affecting-php | Advisory chính thức UK | Xác nhận timeline, impact statement |
| **Red Hat CVE-2026-109618** | https://access.redhat.com/security/cve/cve-2026-109618 | SAPI analysis: mod_php vs FPM, CVSS 8.1/9.8, CWE-416 | Phân tích runtime SAPI → quyết định ưu tiên rule |
| **Red Hat Bulletin RHSB-2026-013** | https://access.redhat.com/security/vulnerabilities/RHSB-2026-013 | Official mitigation + statement | Quy trình patch Red Hat |
| **Red Hat CVE-2026-109619** | https://access.redhat.com/security/cve/cve-2026-109619 | Stale state mechanism | UAF details |
| **Ubuntu CVE pages** | https://ubuntu.com/security/CVE-2026-109619 , https://ubuntu.com/security/CVE-2026-109618 | Patch status per-release | ⚠️ Backport **không đổi version number** → bẫy khi check server |
| **Google Cloud blog** | https://cloud.google.com/blog/products/identity-security/responding-to-core-php-vulnerabilities-cve-2026-109618-cve-2026-109619 | Tổng hợp 2 CVE, fixed versions, Cloud Armor | Vendor multi-layer approach |
| **GitHub Advisories** | https://github.com/advisories/GHSA-w8hw-w9fx-j79w , https://github.com/advisories/GHSA-6wmf-4rv5-p3rp | Official PHP project advisory | Mapping reference |
| **NVD** | https://nvd.nist.gov/vuln/detail/CVE-2026-109618 , https://nvd.nist.gov/vuln/detail/CVE-2026-109619 | Standard reference data | CVSS, CWE, affected configurations |
| **ThreatCluster** | https://threatcluster.io/cluster/php-cve-2026-109618-exploit-disclosed-6d38a87e | Timeline + in-the-wild tracking | Disclosure + active exploitation timeline |

---

### 2.3. Writeup thực chiến — Triage + dấu vết host

| Nguồn | Link | Vai trò | Học hỏi |
|-------|------|--------|---------|
| **fixitect — verify FPM patched** | https://fixitect.com/php2shell-cve-2026-109618-cve-2026-109619-verify-php-fpm-patched/ | **Dấu vết từ 17/10** | ⚠️ Access log chuẩn có thể **KHÔNG capture** shape khai thác. FPM log (fatal memory + upload-progress signal) = nơi đáng tin. Key signal: `Allowed memory size of N bytes exhausted (tried to allocate M)`, `child N exited on signal 11 (SIGSEGV)`, `script ... execution timed out`, worker restart loop liên tục. |
| **StackShield — Laravel/PHP2Shell** | https://www.stackshield.io/blog/php2shell-critical-php-rce-laravel | Cơ chế parse multipart | Multipart parser chạy **TRƯỚC app code** → maintenance-mode/WAF app-level vô dụng. Chứng minh phải ở tầng HTTP server / PHP engine. |
| **dev.to — post-patch triage** | https://dev.to/harryagustiana/post-patch-triage-for-php2shell-a-practical-checklist-for-laravel-servers-and-docker-1ffd | Post-patch forensics | Checklist read-only: xác nhận version **đang serve** (không phải CLI), `apt changelog \| grep CVE-2026-1096`, so sánh `ps lstart php-fpm master` vs `dpkg -l` install time. |

---

### 2.4. Webshell / Post-Exploit Detection — Phục vụ T3 Aftermath

| Nguồn | Link | Vai trò | Học hỏi |
|-------|------|--------|---------|
| **SigmaHQ/sigma** | https://github.com/SigmaHQ/sigma/tree/master/rules/web/webserver_generic | Rule chuẩn webshell | Chuẩn webshell access-log: https://github.com/SigmaHQ/sigma/blob/master/rules/web/webserver_generic/web_win_webshells_in_access_logs.yml |
| **Elastic detection-rules** | https://github.com/elastic/detection-rules | Web command injection | Rule pattern: `bash -c`, `wget`, `/dev/tcp`, `base64`, cron path trên URL |
| **NSA Mitigating-Web-Shells** | https://github.com/nsacyber/Mitigating-Web-Shells | Heuristic anomaly | Rare-URI-success pattern (LogCheck.py) — dùng cho T1 anomaly |
| **Emerging Threats (Suricata open)** | https://rules.emergingthreats.net/open/suricata/rules/ | Community rules library | `emerging-user_agents.rules`, `emerging-hunting.rules`, `emerging-exploit.rules` |
| **WebShells.app blog** | https://www.webshells.app/en/blog/yara-and-sigma-rules-for-web-shells | Sigma web-request | Pattern: `cmd=|exec=|command=` trên script files |
| **CpanelInc YARA (rupde rules)** | https://raw.githubusercontent.com/CpanelInc/tech-CSI/master/php_webshell_rules.yara | YARA file-based (phase sau) | Dùng khi YARA phase bật |
| **WebShell-Analyzer** | https://github.com/ekky19/WebShell-Analyzer | Parser học tập | Cách parse IIS/Apache/Nginx access log |
| **web-log-anomaly-detector** | https://github.com/AhmetPayaslioglu/web-log-anomaly-detector | Regex library | 90+ regex OWASP/webshell — tham khảo tuning FP |
| **Medium — access log/WAF/AuditD** | https://medium.com/@p.matkovski/detection-of-php-web-shells-with-access-log-waf-and-audit-deamon-e798d4c95ec | Hybrid detection | Chứng minh access log **miss POST/header-cmd** → phải đa nguồn |

---

## 📁 PHẦN 3: BẢN ĐỒ LOG — FULL-STACK SYSTEM

### 3.1. Lớp nguồn log (từ yếu đến mạnh)

```
Lớp 1 (YẾU - luôn có)        : access log webserver (HTTP request/response metadata only)
Lớp 2 (MẠNH - FPM)          : php-fpm master/pool/slowlog/worker error logs
Lớp 3 (MẠNH - kernel)       : journald persistent + rsyslog + dmesg (segfault/OOM markers)
Lớp 4 (CHỨNG CỨ - audit)    : auditd execve/write syscall (RCE execution proof)
Lớp 5 (BODY - hiếm)         : ModSecurity audit log / nginx njs capture (request body markers)
Lớp 6 (HẬU KHAI THÁC)       : session files, webroot manifest, app/CMS logs, mail/cron
```

### 3.2. Chi tiết component

#### A. Nginx
```
/var/log/nginx/access.log
  Format: combined (default) = NO Content-Type/Cookie/body
  Lưu ý: $request_length = full request size (header+body)
         → dùng để detect ≥5MB body

/var/log/nginx/error.log
  Tín hiệu phụ: upstream timeout/502 khi FPM chết (T2)

njs (nếu cài)
  Capture multipart field name → ghi vào error log (không mặc định)
```

#### B. Apache httpd
```
Debian/Ubuntu:
  /var/log/apache2/access.log
  /var/log/apache2/error.log
  /var/log/apache2/modsec_audit.log (nếu ModSec)

RHEL/CentOS:
  /var/log/httpd/access_log
  /var/log/httpd/error_log
  /var/log/httpd/modsec_audit.log

Per-vhost CustomLog: per-site config
mod_php error: trộn vào error log
```

#### C. PHP-FPM (NGUỒN MẠNH NHẤT)
```
Master error_log:
  Debian/Ubuntu: /var/log/php8.2-fpm.log (version-specific)
  RHEL/CentOS: /var/log/php-fpm/error.log

Pool error (`php_admin_value[error_log]`):
  Debian/Ubuntu: /var/log/php8.2-fpm/www-error.log
  RHEL/CentOS: /var/log/php-fpm/www-error.log

Pool access log (OFF mặc định):
  Nếu bật: /var/log/php-fpm/access.log

Slowlog (OFF mặc định):
  Nếu bật: /var/log/php-fpm/www-slow.log

Worker output (`catch_workers_output=yes` OFF):
  Trộn vào master log / journald

Không đặt error_log → journald:
  journalctl -u php8.2-fpm
  journalctl -u php-fpm

Multi-version cPanel/CloudLinux:
  /var/log/php*-fpm*.log
  /opt/alt/php*/usr/php/...
  /usr/local/cpanel/logs/php-fpm/

⚠️ KEY SIGNALS:
  "Allowed memory size of N bytes exhausted (tried to allocate M)"
  "child N exited on signal 11 (SIGSEGV)"
  "script ... execution timed out"
  (worker restart loop)
```

#### D. PHP runtime / ini
```
error_log (global ini):
  /var/log/php/error.log
  /var/log/php_errors.log
  hoặc rỗng → stderr → FPM/journald
  → discovery bằng `php -i` READ-ONLY

session.save_path:
  Debian/Ubuntu: /var/lib/php/sessions/
  RHEL/CentOS: /var/lib/php/session/
  cPanel: /var/cpanel/php/sessions/<ver>/
  (unset: /tmp)
  
  Tín hiệu T2: File `sess_*` chứa key `upload_progress_<name>` lạ / kích thước đột biến

OPcache file cache (nếu cấu hình):
  /var/cache/php-opcache/
  theo `opcache.file_cache` directive
  → Variant WordPress-OPcache của CVE-109619
```

#### E. Kernel / systemd / syslog
```
journald persistent:
  /var/log/journal/* (nếu `Storage=persistent`)
  nếu volatile: chỉ journalctl tới khi reboot
  
  Signal: 
    journalctl -k
    "php-fpm[N]: segfault at ... error 4 in php-fpm8.x..."
    "Out of memory: Killed process N (php-fpm)"

rsyslog kernel (persistent bản backup):
  RHEL: /var/log/messages, /var/log/secure
  Debian: /var/log/syslog, /var/log/kern.log

dmesg (ring buffer, volatile):
  mất khi reboot — phụ trợ

Unit journals:
  journalctl -u nginx -u apache2 -u httpd -u 'php*-fpm'
  → child exit signal 11, restart loop, coredump events
```

#### F. Core dumps
```
systemd-coredump:
  coredumpctl list
  /var/lib/systemd/coredump/core.php*-fpm.*

abrt (RHEL):
  /var/spool/abrt/ccpp-*/

apport (Ubuntu):
  /var/crash/*.crash

kernel.core_pattern (custom):
  theo config (vd /var/crash/core.%e.%p)
```

#### G. auditd (nếu cài)
```
/var/log/audit/audit.log (+ rotated)

Signal:
  execve của uid www-data/nginx/php-fpm (whoami/curl/nc)
  write `.php` vào webroot
  → CHỨNG CỨ RCE thực thi (T3)
```

#### H. App / CMS / khác
```
WordPress:
  wp-content/debug.log (chỉ khi WP_DEBUG_LOG)
  → fatal do shell/CVE

Laravel:
  storage/logs/laravel.log (trong webroot)

Mail (PHP mail() abuse):
  RHEL: /var/log/maillog
  Debian: /var/log/mail.log

Cron/persistence:
  RHEL: /var/log/cron
  Debian: journalctl -u cron + /var/log/syslog

Package history (patch timeline):
  /var/log/dpkg.log, /var/log/dnf.log, /var/log/yum.log
  → so sánh PHP patch time vs FPM master start time
```

#### I. Logrotate — file scan thêm
```
access.log.1, access.log.2.gz, access.log-YYYYMMDD, access.log-YYYYMMDD.gz
access_log-YYYYMMDD (RHEL)

Monitor phải đọc **cả rotated file của ngày hiện tại**
→ không miss rotate boundary
```

### 3.3. Ma trận bao phủ: Full-Stack vs Subset

| # | Nguồn log | Full-Stack | Tối thiểu | Tier | Nếu thiếu |
|---|-----------|-----------|----------|------|-----------|
| 1 | Access log nginx/apache | ✅ | ✅ | T1 (yếu) | — |
| 2 | FPM master/pool error | ✅ | ❌ | **T2 (vàng)** | Mất signal memory-exhausted sớm |
| 3 | FPM slowlog/access log | ✅ (if enabled) | ❌ | T1/T2 context | Skip |
| 4 | journald persistent/rsyslog | ✅ | ✅ (thường có) | T2/T3 segfault+OOM | Chỉ còn dmesg volatile |
| 5 | auditd | ✅ | ❌ | **T3 (RCE execution)** | Bù bằng webroot diff |
| 6 | coredumps | ✅ | ❌ | T3 (offline evidence) | Không ảnh hưởng realtime |
| 7 | ModSec audit log (BODY) | ✅ | ❌ | **T1 (mạnh nhất)** | Mất hoàn toàn thấy `PHP_SESSION_UPLOAD_PROGRESS`/nested names |
| 8 | Session files | ✅ | ✅ (PHP nào cũng có) | T2 | Skip |
| 9 | Webroot manifest | ✅ | ✅ | T3 webshell drop | — |
| 10 | App/CMS logs | ✅ | ❌ | T3 phụ | Skip |

**Thiết kế**: Monitor không bao giờ fail vì thiếu nguồn — mỗi nguồn = plugin check tồn tại → skip nếu vắng.

### 3.4. Discovery script (READ-ONLY)

```bash
#!/usr/bin/env bash
# php2shell_discovery.sh — 100% READ-ONLY. Mapping log thực tế trên server.

echo "== nginx =="; \
  nginx -T 2>/dev/null | grep -nE 'access_log|error_log' || true

echo "== apache =="; \
  (apachectl -S 2>/dev/null || httpd -S 2>/dev/null) || true

echo "== fpm units =="; \
  systemctl list-units 'php*' --no-pager 2>/dev/null || true

echo "== fpm conf =="; \
  grep -RhE '^(error_log|access.log|slowlog|catch_workers_output|php_admin_value\[error_log\])' \
    /etc/php* /etc/php-fpm* 2>/dev/null || true

echo "== php ini =="; \
  php -i 2>/dev/null | grep -E '^(error_log|session\.save_path|opcache\.file_cache)' || true

echo "== auditd =="; \
  ls -l /var/log/audit/audit.log 2>/dev/null || echo "no auditd log"

echo "== coredump =="; \
  coredumpctl list --no-pager 2>/dev/null | tail -5 || \
  ls /var/crash /var/spool/abrt 2>/dev/null || echo "no coredump handler"

echo "== modsec =="; \
  find /var/log -maxdepth 2 -iname '*modsec*' 2>/dev/null || true

echo "== sessions =="; \
  ls -ld /var/lib/php/sessions /var/lib/php/session /tmp 2>/dev/null | head -3

echo "== journal persistent =="; \
  ls -ld /var/log/journal 2>/dev/null || echo "volatile journal"

echo "== kernel segfault sample =="; \
  journalctl -k --since "2026-10-17" 2>/dev/null | grep -ciE 'php-fpm.*(segfault|signal 11)' || true
```

### 3.5. Điểm mù chung (Known Blind Spots)

1. **POST body KHÔNG nằm log mặc định**
   - Chỉ thấy markers (`PHP_SESSION_UPLOAD_PROGRESS`, nested names, null bytes) qua:
     - ModSec audit log
     - nginx njs/lua capture
     - pcap
   - Không có → T1 dựa vào size, burst, status

2. **Custom header (X-CMD, Accept-Language cmd...)**
   - Không vào access log → chấp nhận miss, ghi trong doc

3. **Logrotate / gzip**
   - Đọc kèm file rotate

4. **journald volatile**
   - Mất log khi reboot → rsyslog file = bản backup

---

## 🎯 PHẦN 4: MA TRẬN PHÁT HIỆN (T1/TRƯỚC — T2/ĐANG — T3/THÀNH CÔNG)

### T1 — TRƯỚC khai thác (Batch 5 phút + baseline 7 ngày)

**Tín hiệu yếu, phát hiện sớm**:

- POST multipart vào URI **không có** trong baseline upload
- POST `.php` với `$request_length` / Content-Length **≥ 5MB**
- POST multipart **không Content-Length** / chunked encoding (nếu thấy được header)
- **Burst** ≥ N POST/5 phút từ 1 IP → cùng URI (chấm worker — CVE-109619 reentry)
- UA scanning + POST `.php` lạ
- `PHPSESSID` được set từ path **chưa từng dùng** session

**Scoring**: T1 đơn lẻ = **MEDIUM**

### T2 — ĐANG khai thác (Watcher realtime ≤ 60 giây)

**Tín hiệu mạnh, in-progress**:

- Tail FPM log: `Allowed memory size ... exhausted` / `exited on signal 11` / `timed out`
- Correlate ±3s với access log → định danh IP attacker
- Session file bỗng chứa `upload_progress_` key lạ / **kích thước đột biến**
- nginx error log: 502/timeout **loạt** từ 1 IP

**Scoring**: 
- T1 + T2 cùng IP/giờ = **HIGH**
- T2 + T3 (segfault/OOM) = **CRITICAL**

### T3 — ĐÃ thành công (Watcher realtime + sweep 5 phút)

**Tín hiệu xác nhận, post-exploit**:

- Kernel log: segfault php-fpm / OOM-killer
- auditd: `execve` www-data, write `.php` webroot
- Webroot diff: `.php` **mới** / owner `www-data` so manifest
- Outbound conn mới từ worker php-fpm (`ss -tnp` — read-only)
- App logs: fatal khớp **thời điểm chính xác**

**Scoring**:
- T3 webshell drop = **CRITICAL** (+ path file trong alert)

---

## 🛠️ PHẦN 5: KIẾN TRÚC MONITOR

### Sơ đồ thành phần

```
CRON 5p (batch, read-only)              WATCHER realtime (systemd unit, read-only)
┌──────────────────────────┐            ┌─────────────────────────────┐
│ php2shell_scan.sh        │            │ php2shell_watch.sh (tail)   │
│ ├─ plugin: accesslog     │            │ ├─ tail FPM error/pool      │
│ ├─ plugin: fpm logs      │            │ ├─ journalctl -kf           │
│ ├─ plugin: kernel/rsys   │            │ ├─ tail auditd log          │
│ ├─ plugin: session scan  │            │ └─ ss -tnp sweep (read-only)│
│ ├─ plugin: webroot       │            └────────────┬────────────────┘
│ └─ rules T1 + baseline   │                         │
└────────┬─────────────────┘                         │
         ▼                                           ▼
    ┌────────────────────────────────────────────────────┐
    │ CORRELATOR (state/): IP+time+source → T1/T2/T3    │
    │ scoring → JSONL alert queue                        │
    └──────────────┬─────────────────────────────────────┘
                   ▼
         Export JSON (SIEM-ready) + SQL
         [DEFERRED: telebot]
         [DEFERRED: Splunk HEC]
         [DEFERRED: YARA]
```

### Triển khai

- **Thư mục**: `/opt/php2shell/` (chỉ script + state là file MỚI — không sửa file hệ thống)
- **Dependency**: bash 4+, gawk, grep -P, curl (deferred), jq, coreutils
  - **KHÔNG pip/apt** cài gì thêm
- **Plugin design**: Mỗi nguồn log = check tồn tại → skip nếu vắng
  - **Bao phủ superset, chạy được trên subset**

---

## 📋 PHẦN 6: RULE SEED — MAP ID → NGUỒN THAM KHẢO

| ID | Rule | Nguồn |
|----|------|-------|
| **P2S-001** | Multipart POST chứa `PHP_SESSION_UPLOAD_PROGRESS` **KHÔNG kèm** `filename=` | Lexsah R2, detqt 9000051 (PCRE lookahead) |
| **P2S-002** | Field name lồng sâu ≥3–20 cấp `a[b][c]...` | break-the-build R5, jaiswalakshansh ModSec 1009619, detqt 9000002 |
| **P2S-003** | Multipart POST không Content-Length / chunked | jaiswalakshansh 1009620, detqt 9000061 |
| **P2S-004** | POST `.php` + body ≥5MB (`$request_length`) | AWS SizeConstraint, break-the-build R3 |
| **P2S-005** | urlencoded POST field name khổng lồ / null bytes | detqt (Datadog variant) |
| **P2S-006** | POST + `PHPSESSID` (cookie/body) + `PHP_SESSION_UPLOAD_PROGRESS` (AND) | AWS WAF bulletin |
| **P2S-007** | Lặp ≥2 field upload-progress trong 1 request | Lexsah R3 (SID 910961803) |
| **P2S-010** | FPM fatal `Allowed memory size ... exhausted` | fixitect, host-side |
| **P2S-011** | FPM `exited on signal 11` / kernel segfault | fixitect, host-side |
| **P2S-020+** | Webshell access pattern (cmd=, tên shell, .php upload) | Sigma, ET, errorlogs |

---

## 🎓 PHẦN 7: STUDY PATH — THỨ TỰ HỌC TẬP

1. **Tuần 1: Threat Intel**
   - Đọc: NCSC UK advisory
   - Đọc: Red Hat CVE analysis
   - Xem: fixitect — FPM log signal
   - **Kết quả**: Hiểu cơ chế CVE-2026-109618/109619, SAPI impact

2. **Tuần 2: Rule sources**
   - Đọc: break-the-build/php-uploadprogress-waf (→ R1–R8 logic)
   - Đọc: Lexsah/php2shell-detection
   - Đọc: jaiswalakshansh WAF-RULES
   - Đọc: detqt PCRE rules
   - **Kết quả**: Hiểu 7–10 rule chính, cách viết 1 logic cho nhiều platform

3. **Tuần 3: Log architecture**
   - Đọc: section 3 (bản đồ log full-stack)
   - Chạy: discovery script trên local/test server (READ-ONLY)
   - **Kết quả**: Map log paths, hiểu plugin design

4. **Tuần 4: Detection matrix**
   - Đọc: T1/T2/T3 matrix (section 4)
   - Đọc: StackShield — multipart parse timing
   - Đọc: NSA Mitigating-Web-Shells (T3 aftermath)
   - **Kết quả**: Hiểu detection flow, correlation logic, scoring

5. **Tuần 5–6: Implementation**
   - Convert rule seed → JSON engine
   - Viết bash plugin cho mỗi log source
   - Viết correlator (state, alert queue)
   - Test trên local + test server

---

## 📖 REFERENCES DUMP (Để copy-paste nhanh)

### Official Advisory
- NCSC UK: https://www.ncsc.gov.uk/news/critical-security-issue-affecting-php
- Red Hat: https://access.redhat.com/security/cve/cve-2026-109618
- Ubuntu: https://ubuntu.com/security/CVE-2026-109618
- NVD: https://nvd.nist.gov/vuln/detail/CVE-2026-109618

### Rule Sources (HIGH PRIORITY)
- Lexsah: https://github.com/Lexsah/php2shell-detection
- break-the-build: https://github.com/break-the-build/php-uploadprogress-waf ⭐
- jaiswalakshansh: https://github.com/jaiswalakshansh/Reversing-Vulnerabilities/blob/main/CVE-2026-109618-109619/WAF-RULES.md
- AWS: https://aws.amazon.com/blogs/security/using-aws-waf-to-apply-mitigations-for-php2shell-rce-vulnerabilities-cve-2026-109618-and-cve-2026-109619/
- detqt: https://detqt.com/blog/php2shell/index.md

### Writeups (PRACTICAL)
- fixitect: https://fixitect.com/php2shell-cve-2026-109618-cve-2026-109619-verify-php-fpm-patched/
- StackShield: https://www.stackshield.io/blog/php2shell-critical-php-rce-laravel
- dev.to: https://dev.to/harryagustiana/post-patch-triage-for-php2shell-a-practical-checklist-for-laravel-servers-and-docker-1ffd

### Webshell / Post-Exploit
- SigmaHQ: https://github.com/SigmaHQ/sigma/tree/master/rules/web/webserver_generic
- Elastic: https://github.com/elastic/detection-rules
- NSA: https://github.com/nsacyber/Mitigating-Web-Shells
- ET: https://rules.emergingthreats.net/open/suricata/rules/

### Technical Analysis
- WoYinDao: https://github.com/WoYinDao/CVE-2026-109618-CVSS-9.2-Critical/blob/main/README.md
- Google Cloud: https://cloud.google.com/blog/products/identity-security/responding-to-core-php-vulnerabilities-cve-2026-109618-cve-2026-109619/
- ThreatCluster: https://threatcluster.io/cluster/php-cve-2026-109618-exploit-disclosed-6d38a87e

---

## 📌 NEXT STEPS

1. **Phase A (tuần 1-2)**: Đọc toàn bộ reference này + các link primary
2. **Phase B (tuần 3-4)**: Thiết kế rule JSON engine + plugin architecture
3. **Phase C (tuần 5-6)**: Implement monitor bash scripts
4. **Phase D (tuần 7)**: Test, verify, dokumentasi

---

*Generated: 2026-10-23*
*Status: REFERENCE ONLY — CHƯA TRIỂN KHAI*
