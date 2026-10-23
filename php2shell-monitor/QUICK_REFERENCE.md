# 🚀 PHP2SHELL DETECTION — QUICK REFERENCE CHEAT SHEET

**Mục đích**: Tra cứu nhanh key information, cơ chế, rule ID, log paths.

---

## 🔴 QUICK FACTS

| Mục | Giá trị |
|-----|--------|
| **CVE** | 2026-109618 (mod_php, OOM) + 2026-109619 (FPM, UAF) |
| **CVSS** | 9.8 / 9.2 — CRITICAL |
| **Affected PHP** | 5.4 → 8.5.11 |
| **Fixed** | 8.2.35, 8.3.36, 8.4.27, 8.5.12 |
| **Disclosure** | 20–21/10/2026 |
| **Timeline** | 17/10 honeypot, 21/10 Cloudflare attacks |
| **Payload Type** | **NO string signature** — structure-based |
| **Mechanic** | Multipart POST: OOM/UAF → corruption → RCE |

---

## 🎯 PAYLOAD SHAPE

```
POST multipart {
  field: PHP_SESSION_UPLOAD_PROGRESS
    [a[b[c...]]]  ← nested ≥3–20 levels
    NO filename=  ← or wrong combination
  
  body: ≥5MB
  encoding: chunked OR missing Content-Length
  field_name: null bytes (urlencoded variant)
}
```

---

## 📋 RULE ID → LOGIC MAPPING

| ID | Rule Logic | Source | Platform |
|----|-----------|--------|----------|
| **P2S-001** | Multipart + `PHP_SESSION_UPLOAD_PROGRESS` NOT `filename=` | Lexsah R2, detqt SID 9000051 | Suricata, ModSec |
| **P2S-002** | Nested field ≥3–20 levels `a[b[c]...]` | break-the-build R5, ModSec 1009619, detqt SID 9000002 | All |
| **P2S-003** | Multipart NO Content-Length / chunked | ModSec 1009620, detqt SID 9000061 | All |
| **P2S-004** | POST `.php` + body ≥5MB | AWS, break-the-build R3 | All |
| **P2S-005** | urlencoded field name huge OR null bytes | detqt Datadog variant | Suricata |
| **P2S-006** | POST + (`PHPSESSID` cookie/body) + `PHP_SESSION_UPLOAD_PROGRESS` **AND** | AWS WAF | All |
| **P2S-007** | ≥2 `upload-progress` field in 1 request | Lexsah R3 SID 910961803 | Suricata |
| **P2S-010** | FPM fatal: `Allowed memory size ... exhausted` | fixitect, host-side | FPM log |
| **P2S-011** | FPM: `child N exited on signal 11 (SIGSEGV)` | fixitect, host-side, kernel | FPM/kernel log |
| **P2S-030+** | Webshell: `cmd=`, shell name, `.php` upload | Sigma, ET, errorlogs | Access log, app log |

---

## 📍 LOG PATHS (by distro)

### Debian/Ubuntu

```
Nginx:
  /var/log/nginx/access.log
  /var/log/nginx/error.log

FPM 8.2 (example):
  /var/log/php8.2-fpm.log (master)
  /var/log/php8.2-fpm/www-error.log (pool)
  /var/log/php8.2-fpm/www-slow.log (slowlog, if enabled)

PHP session:
  /var/lib/php/sessions/

PHP error_log:
  /var/log/php/error.log OR stderr → journald

Kernel/systemd:
  /var/log/journal/* (if persistent)
  /var/log/syslog
  /var/log/kern.log

auditd:
  /var/log/audit/audit.log (if installed)

ModSec (Apache):
  /var/log/apache2/modsec_audit.log

Logrotate:
  access.log.1, access.log.2.gz
  access.log-YYYYMMDD, access.log-YYYYMMDD.gz
```

### RHEL/CentOS

```
Nginx:
  /var/log/nginx/access.log
  /var/log/nginx/error.log

FPM:
  /var/log/php-fpm/error.log (master)
  /var/log/php-fpm/www-error.log (pool)

PHP session:
  /var/lib/php/session/

Kernel/systemd:
  /var/log/journal/* (if persistent)
  /var/log/messages
  /var/log/secure

auditd:
  /var/log/audit/audit.log (if installed)

ModSec (Apache):
  /var/log/httpd/modsec_audit.log

Logrotate:
  access_log-YYYYMMDD
```

---

## 🚨 KEY SIGNALS — COPY GREP PATTERNS

### T2 — In-Progress Detection

**FPM log** (`/var/log/php*-fpm*.log`):
```bash
grep -i "Allowed memory size" /var/log/php*-fpm*.log
grep "exited on signal 11" /var/log/php*-fpm*.log
grep "execution timed out" /var/log/php*-fpm*.log
grep "child .* exited" /var/log/php*-fpm*.log
```

**Kernel / journald**:
```bash
journalctl -k --since "2026-10-17" | grep -i "segfault"
journalctl -k | grep "Out of memory"
journalctl -u php-fpm | grep -i "signal 11"
```

**Nginx error log**:
```bash
grep "502 Bad Gateway\|upstream timed out" /var/log/nginx/error.log
```

### T3 — Post-Exploit

**auditd** (`/var/log/audit/audit.log`):
```bash
grep "type=EXECVE" /var/log/audit/audit.log | grep "www-data\|nginx"
grep "type=WRITE" /var/log/audit/audit.log | grep "\.php"
```

**Webroot diff**:
```bash
find /var/www -name "*.php" -newer /path/to/manifest
find /var/www -name "*.php" -user www-data -ctime -1
```

---

## 🏗️ ARCHITECTURE BLOCKS

```
INPUT LAYER (Batch 5m + Realtime)
├─ Access log (nginx/apache)
├─ FPM error log
├─ Kernel log (journald/rsyslog)
├─ auditd log
├─ Session dir scan
└─ Webroot manifest

RULE LAYER (JSON engine)
├─ P2S-001 to P2S-007 (HTTP markers)
├─ P2S-010 to P2S-011 (FPM/kernel)
└─ P2S-030+ (webshell aftermath)

CORRELATION LAYER
├─ IP + time + source
├─ Baseline 7 days
├─ Scoring: T1/T2/T3
└─ Alert state persistence

OUTPUT LAYER
├─ JSONL alerts
├─ SQL export (phase 2)
└─ [DEFERRED: Splunk/telebot/YARA]
```

---

## 🔍 DISCOVERY ONE-LINER

```bash
nginx -T 2>/dev/null | grep log; \
grep -RhE '^(error_log|access.log|slowlog)' /etc/php* /etc/php-fpm* 2>/dev/null; \
php -i 2>/dev/null | grep -E '^(error_log|session\.save_path)'; \
ls -l /var/log/audit/audit.log 2>/dev/null; \
journalctl --disk-usage 2>/dev/null
```

---

## 📊 DETECTION MATRIX QUICK

| Tier | Signal | Source | Latency | Confidence |
|------|--------|--------|---------|------------|
| **T1** | POST multipart ≥5MB | access log | 5m (batch) | MEDIUM |
| **T1** | Burst POST to URI | access log | 5m | MEDIUM |
| **T2** | Memory exhausted | FPM log | <1m (realtime) | **HIGH** |
| **T2** | Signal 11 / segfault | FPM/kernel | <1m (realtime) | **HIGH** |
| **T2** | Session `upload_progress_` | session file scan | 5m | **HIGH** |
| **T3** | execve www-data | auditd | realtime | **CRITICAL** |
| **T3** | `.php` dropped webroot | webroot manifest | 5m | **CRITICAL** |

**Scoring**:
- T1 alone = MEDIUM
- T1 + T2 = HIGH
- T2 + T3 = CRITICAL

---

## 🛠️ PLUGIN CHECKLIST

| Plugin | Input | Output | Skip if |
|--------|-------|--------|---------|
| **AccessLogParser** | nginx/apache access.log | T1 signals | file missing |
| **FPMLogParser** | php-fpm error.log | T2 signals (P2S-010/011) | file missing |
| **KernelLogParser** | journalctl -k / rsyslog | T3 segfault/OOM | journal volatile + no rsyslog |
| **AuditdParser** | /var/log/audit/audit.log | T3 execve/write proof | auditd not installed |
| **SessionScanner** | session.save_path | T2 upload_progress_ marker | path not found |
| **WebrootManifest** | /var/www + manifest hash | T3 .php diff | no manifest baseline |
| **ModSecParser** | modsec_audit.log | T1 body markers (P2S-001/002) | file missing |

---

## 🔗 REFERENCE LINKS CHEAT

| Need | Link |
|------|------|
| **Suricata rules** | https://github.com/Lexsah/php2shell-detection |
| **Multi-platform signals** | https://github.com/break-the-build/php-uploadprogress-waf |
| **ModSec chain rules** | https://github.com/jaiswalakshansh/Reversing-Vulnerabilities/blob/main/CVE-2026-109618-109619/WAF-RULES.md |
| **FPM triage** | https://fixitect.com/php2shell-cve-2026-109618-cve-2026-109619-verify-php-fpm-patched/ |
| **AWS WAF reference** | https://aws.amazon.com/blogs/security/using-aws-waf-to-apply-mitigations-for-php2shell-rce-vulnerabilities-cve-2026-109618-and-cve-2026-109619/ |
| **PCRE rules** | https://detqt.com/blog/php2shell/index.md |
| **Red Hat CVSS** | https://access.redhat.com/security/cve/cve-2026-109618 |
| **Ubuntu patch status** | https://ubuntu.com/security/CVE-2026-109618 |

---

## ⚠️ COMMON PITFALLS

| Pitfall | Issue | Fix |
|---------|-------|-----|
| **Access log only** | Misses POST body structure (P2S-001/002/005) | Add FPM log + ModSec if available |
| **Ignore FPM log** | Miss memory exhausted signal (T2 early warning) | Tail FPM error.log realtime |
| **No baseline** | False positive surge | Build 7-day baseline, correlate with timestamp |
| **journald volatile** | Lose segfault evidence on reboot | Check rsyslog as backup |
| **Version check only CLI** | PHP CLI != SAPI serving | Use `ps` + `lstart` vs package install time |
| **Ignore logrotate** | Miss requests at rotate boundary | Read rotated files same day |
| **ModSec `request-body-limit` 100KB** | Miss body if >100KB | Disable limit or increase |

---

## 🧮 CORRELATION EXAMPLE

```
13:45:23 access.log: POST /upload.php, 5.2MB, IP=1.2.3.4
13:45:24 fpm.log: "Allowed memory size ... exhausted"
13:45:25 journalctl -k: "segfault php-fpm8.2[1234]"
13:45:26 auditd: execve /bin/bash by www-data
13:45:27 webroot: new shell.php owner=www-data

Correlation: IP 1.2.3.4, ±3s window, T1+T2+T3 all present
Score: CRITICAL
Alert: {"time": "13:45:23", "ip": "1.2.3.4", "score": "CRITICAL", "evidence": [...]}
```

---

## 📋 BEFORE IMPLEMENTATION

- [ ] **Read**: REFERENCE_SOURCES.md (full)
- [ ] **Study**: STUDY_CHECKLIST.md (7 weeks)
- [ ] **Map**: Local log paths via discovery script
- [ ] **Design**: JSON rule engine spec
- [ ] **Design**: Plugin interfaces
- [ ] **Design**: Correlator state format
- [ ] **Design**: Alert format + export

---

*Last updated: 2026-10-23*
*Version: 1.0 — REFERENCE ONLY*
