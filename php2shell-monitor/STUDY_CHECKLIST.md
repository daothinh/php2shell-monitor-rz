# 📚 PHP2SHELL DETECTION — STUDY CHECKLIST

**Mục đích**: Checklist học tập trước khi triển khai monitor. Check ✅ khi hoàn thành mỗi mục.

---

## 📖 PHASE 1: THREAT INTEL (Tuần 1)

### Official Advisory
- [ ] **NCSC UK Advisory** — https://www.ncsc.gov.uk/news/critical-security-issue-affecting-php
  - Timeline, impact statement UK
  
- [ ] **Red Hat CVE-2026-109618** — https://access.redhat.com/security/cve/cve-2026-109618
  - SAPI analysis: mod_php vs FPM, CVSS 8.1/9.8
  
- [ ] **Red Hat CVE-2026-109619** — https://access.redhat.com/security/cve/cve-2026-109619
  - UAF mechanism, stale state
  
- [ ] **Ubuntu CVE pages**
  - https://ubuntu.com/security/CVE-2026-109618
  - https://ubuntu.com/security/CVE-2026-109619
  - ⚠️ Chú ý: backport không đổi version number
  
- [ ] **NVD** — https://nvd.nist.gov/vuln/detail/CVE-2026-109618
  - CVSS, CWE-416, affected configurations

### Key Takeaways to Note:
```
CVE-2026-109618:
- OOM cleanup → corruption → RCE
- mod_php: trước app code
- CVSS: 9.8

CVE-2026-109619:
- UAF: state not reset
- FPM: upload-progress + OPcache variants
- CVSS: 9.2

Timeline:
- 17/10: honeypot attempts
- 20-21/10: public disclosure
- 21/10: Cloudflare attacks
```

---

## 🔍 PHASE 2: RULE SOURCES (Tuần 2)

### HIGH PRIORITY ⭐

- [ ] **break-the-build/php-uploadprogress-waf** ⭐⭐⭐
  - https://github.com/break-the-build/php-uploadprogress-waf
  - [ ] Đọc README overview
  - [ ] Đọc `docs/detection-platforms.md` — giới hạn từng platform
  - [ ] Study R1–R8 logic:
    - [ ] R1: 
    - [ ] R2: 
    - [ ] R3: 
    - [ ] R4: 
    - [ ] R5: Nested field names
    - [ ] R6: 
    - [ ] R7: 
    - [ ] R8: 
  - [ ] Xem cách convert sang ModSec / Suricata / AWS WAF / njs / Python
  - **KEY LEARNING**: Cách viết 1 signal cho nhiều platform

- [ ] **jaiswalakshansh WAF-RULES**
  - https://github.com/jaiswalakshansh/Reversing-Vulnerabilities/blob/main/CVE-2026-109618-109619/WAF-RULES.md
  - [ ] Giải thích "vì sao khó signature"
  - [ ] ModSec chain rules 1009618–1009620:
    - [ ] Rule 1: Upload-progress field
    - [ ] Rule 2: Nested ≥20
    - [ ] Rule 3: Lengthless multipart
  - **KEY LEARNING**: Convert chain logic → JSON AND/OR

- [ ] **AWS Security Blog PHP2Shell**
  - https://aws.amazon.com/blogs/security/using-aws-waf-to-apply-mitigations-for-php2shell-rce-vulnerabilities-cve-2026-109618-and-cve-2026-109619/
  - [ ] AND-condition rule: POST + PHPSESSID (cookie/body) + PHP_SESSION_UPLOAD_PROGRESS
  - [ ] AWS WAF JSON syntax → P2S-006 reference
  
- [ ] **Lexsah/php2shell-detection**
  - https://github.com/Lexsah/php2shell-detection
  - [ ] R1: UA `php2shell`
  - [ ] R2: Multipart POST chứa `PHP_SESSION_UPLOAD_PROGRESS` KHÔNG kèm `filename=`
  - [ ] R3: Lặp ≥2 field upload-progress
  - [ ] SID 9109618xx format

- [ ] **detqt PHP2Shell hunting**
  - https://detqt.com/blog/php2shell/index.md
  - [ ] SID 9000051: negative lookahead `filename=`
  - [ ] SID 9000002: nested ≥20
  - [ ] SID 9000061: chunked multipart
  - [ ] SID 9000023: PHPSESSID ≥512 chars
  - [ ] Các bẫy PCRE:
    - [ ] `request-body-limit` 100KB miss
    - [ ] `Set-Cookie` chỉ trong `http.cookie`
    - [ ] `;` escape `\x3b`

### Rule Mapping Notes
```
Rule ID → Nguồn → Logic:
P2S-001: Lexsah R2, detqt 9000051
P2S-002: break-the-build R5, ModSec 1009619, detqt 9000002
P2S-003: ModSec 1009620, detqt 9000061
P2S-004: AWS SizeConstraint, break-the-build R3
P2S-006: AWS WAF bulletin
P2S-007: Lexsah R3
```

---

## 📝 PHASE 3: WRITEUPS & HOST SIGNALS (Tuần 3)

### Practical Triage

- [ ] **fixitect — verify FPM patched** ⭐⭐
  - https://fixitect.com/php2shell-cve-2026-109618-cve-2026-109619-verify-php-fpm-patched/
  - [ ] Dấu vết từ 17/10
  - [ ] Access log **có thể KHÔNG capture** shape
  - [ ] FPM log: key signals:
    - [ ] `Allowed memory size of N bytes exhausted (tried to allocate M)`
    - [ ] `child N exited on signal 11 (SIGSEGV)`
    - [ ] `script ... execution timed out`
    - [ ] Worker restart loop
  - **KEY LEARNING**: FPM log > access log cho T2 detection

- [ ] **StackShield — Laravel/PHP2Shell**
  - https://www.stackshield.io/blog/php2shell-critical-php-rce-laravel
  - [ ] Multipart parse TRƯỚC app code
  - [ ] Maintenance-mode/WAF app-level vô dụng
  - **KEY LEARNING**: Phải detect ở HTTP server / PHP engine layer

- [ ] **dev.to — post-patch triage**
  - https://dev.to/harryagustiana/post-patch-triage-for-php2shell-a-practical-checklist-for-laravel-servers-and-docker-1ffd
  - [ ] Xác nhận version **đang serve** (không phải CLI)
  - [ ] `apt changelog | grep CVE-2026-1096`
  - [ ] `ps lstart php-fpm master` vs install time
  - **KEY LEARNING**: Checklist read-only forensics

### Technical Deep Dives

- [ ] **WoYinDao analysis**
  - https://github.com/WoYinDao/CVE-2026-109618-CVSS-9.2-Critical/blob/main/README.md
  - [ ] Chain B (`var_destroy __destruct` reentry) = **NOT part** của 2 CVE
  - **KEY LEARNING**: Giới hạn của rule detection

- [ ] **Google Cloud blog**
  - https://cloud.google.com/blog/products/identity-security/responding-to-core-php-vulnerabilities-cve-2026-109618-cve-2026-109619
  - [ ] Tổng hợp 2 CVE
  - [ ] Fixed versions
  - [ ] Cloud Armor approach

---

## 📁 PHASE 4: LOG ARCHITECTURE (Tuần 4)

### Mapping Log Sources

- [ ] **Đọc bản đồ log** (REFERENCE_SOURCES.md section 3)
  - [ ] 6 lớp nguồn log: yếu → mạnh
  - [ ] Component A–I chi tiết
  - [ ] Ma trận full-stack vs subset

- [ ] **Discovery script local test** (READ-ONLY)
  - [ ] Chạy `php2shell_discovery.sh` trên local/test server
  - [ ] Map log paths thực tế:
    ```
    nginx access:
    nginx error:
    FPM master error:
    FPM pool error:
    journald persistent: yes/no
    auditd: yes/no
    ModSec audit: yes/no
    session path:
    ```

- [ ] **Hiểu plugin design**
  - [ ] Mỗi nguồn log = check tồn tại → skip nếu vắng
  - [ ] Superset design: full-stack → chạy được trên subset
  - [ ] Không fail vì thiếu nguồn

### Điểm mù ghi nhận

- [ ] POST body KHÔNG ở log mặc định
- [ ] Custom header KHÔNG vào access log
- [ ] Logrotate / gzip handling
- [ ] journald volatile vs persistent

---

## 🎯 PHASE 5: DETECTION MATRIX (Tuần 5)

### T1 — TRƯỚC khai thác (Access log)

- [ ] Hiểu tín hiệu yếu, phát hiện sớm:
  - [ ] POST multipart vào URI không trong baseline
  - [ ] POST `.php` + `$request_length` ≥5MB
  - [ ] POST multipart không Content-Length / chunked
  - [ ] Burst ≥N POST/5p từ 1 IP → cùng URI
  - [ ] UA scanning + POST .php lạ
  - [ ] PHPSESSID từ path chưa dùng session

- [ ] Baseline logic: 7 ngày history
- [ ] Scoring: T1 đơn lẻ = MEDIUM

### T2 — ĐANG khai thác (FPM + kernel logs)

- [ ] Hiểu tín hiệu mạnh, in-progress:
  - [ ] FPM: memory exhausted / signal 11 / timed out
  - [ ] Correlate ±3s với access log
  - [ ] Session file: `upload_progress_` key lạ / size đột biến
  - [ ] nginx error: 502/timeout loạt

- [ ] Watcher realtime ≤60s
- [ ] Scoring:
  - [ ] T1 + T2 cùng IP/giờ = HIGH
  - [ ] T2 + T3 segfault/OOM = CRITICAL

### T3 — ĐÃ thành công (auditd + webroot)

- [ ] Hiểu tín hiệu xác nhận, post-exploit:
  - [ ] Kernel: segfault / OOM-killer
  - [ ] auditd: execve www-data / write .php webroot
  - [ ] Webroot diff: .php mới / owner www-data
  - [ ] Outbound conn từ worker php-fpm
  - [ ] App logs: fatal khớp thời điểm

- [ ] Scoring: T3 webshell drop = CRITICAL

---

## 🛠️ PHASE 6: WEBSHELL / POST-EXPLOIT (Tuần 6)

### Community Rules Study

- [ ] **SigmaHQ webserver rules**
  - https://github.com/SigmaHQ/sigma/tree/master/rules/web/webserver_generic
  - [ ] `web_win_webshells_in_access_logs.yml`

- [ ] **Elastic detection-rules**
  - https://github.com/elastic/detection-rules
  - [ ] Pattern: `bash -c`, `wget`, `/dev/tcp`, `base64`, cron paths

- [ ] **NSA Mitigating-Web-Shells**
  - https://github.com/nsacyber/Mitigating-Web-Shells
  - [ ] Heuristic: rare-URI-success (LogCheck.py)

- [ ] **Emerging Threats**
  - https://rules.emergingthreats.net/open/suricata/rules/
  - [ ] emerging-user_agents.rules
  - [ ] emerging-hunting.rules
  - [ ] emerging-exploit.rules

- [ ] **WebShells.app blog**
  - https://www.webshells.app/en/blog/yara-and-sigma-rules-for-web-shells
  - [ ] Pattern: `cmd=|exec=|command=` trên script files

---

## 📐 PHASE 7: ARCHITECTURE DESIGN (Tuần 7)

### Monitor Components

- [ ] **CRON batch (5 phút)**
  - [ ] Plugin: access log parser
  - [ ] Plugin: FPM logs
  - [ ] Plugin: kernel/rsyslog
  - [ ] Plugin: session dir scan
  - [ ] Plugin: webroot manifest
  - [ ] Rules T1 + baseline

- [ ] **WATCHER realtime (systemd unit)**
  - [ ] tail FPM error/pool logs
  - [ ] journalctl -kf (segfault/OOM)
  - [ ] tail auditd log (nếu có)
  - [ ] ss -tnp sweep (read-only)

- [ ] **CORRELATOR**
  - [ ] State tracking: IP + time + source
  - [ ] Scoring: T1/T2/T3
  - [ ] Alert queue JSONL
  - [ ] Export: JSON (SIEM-ready) + SQL

### Implementation Checklist

- [ ] Thư mục `/opt/php2shell/`
- [ ] Dependency check: bash 4+, gawk, grep -P, jq, coreutils
- [ ] Plugin architecture: check tồn tại → skip nếu vắng
- [ ] State persistence
- [ ] Logrotate handling

---

## ✅ COMPLETION GATES

### Gate 1: Threat Intel (end of Week 1)
- [ ] Hiểu rõ cơ chế CVE-2026-109618/109619
- [ ] Phân biệt mod_php vs FPM impact
- [ ] Timeline in-the-wild

### Gate 2: Rule Comprehension (end of Week 2)
- [ ] Map 7–10 rule chính → ID → nguồn
- [ ] Hiểu cách viết 1 logic cho nhiều platform
- [ ] Convert Suricata/ModSec → JSON gate logic

### Gate 3: Log Architecture (end of Week 4)
- [ ] Map log paths thực tế (via discovery script)
- [ ] Hiểu 6 lớp nguồn log
- [ ] Thiết kế plugin: superset → subset

### Gate 4: Detection Flow (end of Week 5)
- [ ] Hiểu T1/T2/T3 matrix
- [ ] Correlation logic: IP + time + source
- [ ] Scoring: MEDIUM/HIGH/CRITICAL

### Gate 5: Ready to Implement (end of Week 7)
- [ ] Architecture design hoàn chỉnh
- [ ] Rule JSON engine specification
- [ ] Plugin list + interfaces
- [ ] State + alert format

---

## 📌 NOTES / INSIGHTS

```
(Ghi chú trong quá trình học tập)





```

---

*Status: PRE-IMPLEMENTATION STUDY*
*Created: 2026-10-23*
