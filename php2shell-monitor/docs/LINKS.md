# 🔗 PHP2SHELL DETECTION — CONSOLIDATED LINKS

**Purpose**: Curated collection of all reference URLs organized by category.

---

## 📢 OFFICIAL ADVISORIES

### Government & National Agencies

- **NCSC UK (National Cyber Security Centre)**
  - Title: Critical security issue affecting PHP
  - URL: https://www.ncsc.gov.uk/news/critical-security-issue-affecting-php
  - Type: National advisory
  - Date: 2026-10-21

### Vendor Security Pages

- **Red Hat Security — CVE-2026-109618**
  - URL: https://access.redhat.com/security/cve/cve-2026-109618
  - CVSS: 8.1/9.8
  - CWE: CWE-416 (Use After Free)
  - Analysis: mod_php vs FPM impact

- **Red Hat Security — CVE-2026-109619**
  - URL: https://access.redhat.com/security/cve/cve-2026-109619
  - CVSS: 9.2
  - Analysis: Stale state mechanism

- **Red Hat Security Bulletin — RHSB-2026-013**
  - URL: https://access.redhat.com/security/vulnerabilities/RHSB-2026-013
  - Type: Official mitigation guidance

- **Ubuntu Security — CVE-2026-109618**
  - URL: https://ubuntu.com/security/CVE-2026-109618
  - Note: Backports do not change version number

- **Ubuntu Security — CVE-2026-109619**
  - URL: https://ubuntu.com/security/CVE-2026-109619

- **Google Cloud Security Blog**
  - Title: Responding to Core PHP Vulnerabilities CVE-2026-109618 & CVE-2026-109619
  - URL: https://cloud.google.com/blog/products/identity-security/responding-to-core-php-vulnerabilities-cve-2026-109618-cve-2026-109619
  - Focus: Cloud Armor approach, fixed versions

### Official Databases

- **NVD (National Vulnerability Database) — CVE-2026-109618**
  - URL: https://nvd.nist.gov/vuln/detail/CVE-2026-109618
  - CVSS: 9.8 Critical

- **NVD — CVE-2026-109619**
  - URL: https://nvd.nist.gov/vuln/detail/CVE-2026-109619
  - CVSS: 9.2 Critical

- **GitHub Security Advisories — GHSA-w8hw-w9fx-j79w**
  - URL: https://github.com/advisories/GHSA-w8hw-w9fx-j79w
  - Type: Official PHP project advisory (109618)

- **GitHub Security Advisories — GHSA-6wmf-4rv5-p3rp**
  - URL: https://github.com/advisories/GHSA-6wmf-4rv5-p3rp
  - Type: Official PHP project advisory (109619)

---

## 🛡️ DETECTION RULES & WAF

### Primary Detection Sources

- **AWS Security Blog — PHP2Shell WAF**
  - Title: Using AWS WAF to Apply Mitigations for PHP2Shell RCE Vulnerabilities
  - URL: https://aws.amazon.com/blogs/security/using-aws-waf-to-apply-mitigations-for-php2shell-rce-vulnerabilities-cve-2026-109618-and-cve-2026-109619/
  - Format: AWS WAF JSON rules
  - Key Rule: POST + PHPSESSID + PHP_SESSION_UPLOAD_PROGRESS (AND condition)
  - Mapped to: P2S-006

- **break-the-build/php-uploadprogress-waf** ⭐⭐⭐
  - URL: https://github.com/break-the-build/php-uploadprogress-waf
  - Local: `repos/php-uploadprogress-waf/`
  - Type: Multi-platform ruleset (ModSec v3, Suricata, nginx njs, AWS WAF, Python)
  - Signals: R1–R8
  - Docs: `docs/detection-platforms.md`

- **Lexsah/php2shell-detection**
  - URL: https://github.com/Lexsah/php2shell-detection
  - Local: `repos/php2shell-detection/`
  - Type: Suricata rules (alert-only)
  - SID: 9109618xx series
  - Rules: UA php2shell, upload-progress field, repeat field detection

- **jaiswalakshansh — WAF-RULES.md**
  - URL: https://github.com/jaiswalakshansh/Reversing-Vulnerabilities/blob/main/CVE-2026-109618-109619/WAF-RULES.md
  - Local: `repos/Reversing-Vulnerabilities/CVE-2026-109618-109619/WAF-RULES.md`
  - Type: Cloudflare/AWS/ModSec rules + writeup
  - ModSec Rules: 1009618, 1009619, 1009620

- **detqt — PHP2Shell hunting**
  - URL: https://detqt.com/blog/php2shell/index.md
  - Type: Suricata PCRE (tested on 7.0.10)
  - SID: 9000051, 9000002, 9000061, 9000023, 9000043
  - Special: Negative lookahead patterns, chunked detection

- **Cybaverse PHP2Shell Checker**
  - URL: https://www.cybaverse.co.uk/threats/php2shell-checker
  - Type: Advisory + checker tool

---

## 📝 WRITEUPS & TRIAGE GUIDES

### Post-Patch & Forensics

- **fixitect — Verify PHP-FPM Patched** ⭐⭐
  - URL: https://fixitect.com/php2shell-cve-2026-109618-cve-2026-109619-verify-php-fpm-patched/
  - Focus: FPM log markers from 2026-10-17
  - Key Signals:
    - `Allowed memory size of N bytes exhausted (tried to allocate M)`
    - `child N exited on signal 11 (SIGSEGV)`
    - `script ... execution timed out`
  - Warning: Access log may NOT capture exploit shape

- **StackShield — Laravel/PHP2Shell**
  - URL: https://www.stackshield.io/blog/php2shell-critical-php-rce-laravel
  - Focus: Multipart parse happens BEFORE app code
  - Insight: Maintenance-mode/WAF app-level ineffective

- **dev.to — Post-Patch Triage for PHP2Shell**
  - Title: A Practical Checklist for Laravel Servers and Docker
  - URL: https://dev.to/harryagustiana/post-patch-triage-for-php2shell-a-practical-checklist-for-laravel-servers-and-docker-1ffd
  - Type: Read-only checklist
  - Commands: `apt changelog | grep CVE-2026-1096`, `ps lstart` vs package time

### Technical Analysis

- **WoYinDao/CVE-2026-109618 Analysis**
  - URL: https://github.com/WoYinDao/CVE-2026-109618-CVSS-9.2-Critical/blob/main/README.md
  - Local: `repos/CVE-2026-109618-CVSS-9.2-Critical/README.md`
  - Focus: Chain B (`var_destroy __destruct` reentry UAF) NOT part of 2 CVEs
  - Purpose: Understanding detection limitations

---

## 🌐 WEBSHELL & POST-EXPLOIT DETECTION

### Community Rule Libraries

- **SigmaHQ/sigma — Webserver Generic Rules**
  - URL: https://github.com/SigmaHQ/sigma/tree/master/rules/web/webserver_generic
  - Local: `repos/sigma/rules/web/webserver_generic/`
  - Key File: `web_win_webshells_in_access_logs.yml`
  - Format: Sigma YAML

- **Elastic Detection Rules**
  - URL: https://github.com/elastic/detection-rules
  - Local: `repos/detection-rules/rules/`
  - Focus: Web server potential command injection
  - Patterns: `bash -c`, `wget`, `/dev/tcp`, `base64`, cron paths

- **NSA Cybersecurity — Mitigating-Web-Shells**
  - URL: https://github.com/nsacyber/Mitigating-Web-Shells
  - Local: `repos/Mitigating-Web-Shells/`
  - Tool: LogCheck.py (heuristic rare-URI-success)
  - Purpose: Anomaly detection T1

- **Emerging Threats — Suricata Rules (Open)**
  - URL: https://rules.emergingthreats.net/open/suricata/rules/
  - Local:
    - `repos/emerging-user_agents.rules` (165K)
    - `repos/emerging-hunting.rules` (941K)
    - `repos/emerging-exploit.rules` (1.5M)
  - Type: Community Suricata ruleset

- **WebShells.app Blog**
  - Title: YARA and Sigma Rules for Web Shells
  - URL: https://www.webshells.app/en/blog/yara-and-sigma-rules-for-web-shells
  - Focus: Sigma web-request patterns: `cmd=|exec=|command=`

- **CpanelInc — PHP Webshell YARA Rules**
  - URL: https://raw.githubusercontent.com/CpanelInc/tech-CSI/master/php_webshell_rules.yara
  - Local: `repos/php_webshell_rules.yara` (6912 lines)
  - Type: YARA file-based detection

- **WebShell-Analyzer**
  - URL: https://github.com/ekky19/WebShell-Analyzer
  - Local: `repos/WebShell-Analyzer/`
  - Purpose: Parse comparison IIS/Apache/Nginx access logs

- **web-log-anomaly-detector**
  - URL: https://github.com/AhmetPayaslioglu/web-log-anomaly-detector
  - Local: `repos/web-log-anomaly-detector/`
  - Contains: 90+ regex OWASP/webshell patterns
  - Purpose: FP tuning reference

- **Medium — Detection of PHP Web Shells**
  - Title: Detection with Access Log, WAF and Audit Daemon
  - URL: https://medium.com/@p.matkovski/detection-of-php-web-shells-with-access-log-waf-and-audit-deamon-e798d4c95ec
  - Proof: Access log misses POST/header-cmd → multi-source required

---

## 📊 THREAT INTELLIGENCE

### Timeline & Campaigns

- **ThreatCluster — PHP CVE-2026-109618 Exploit**
  - URL: https://threatcluster.io/cluster/php-cve-2026-109618-exploit-disclosed-6d38a87e
  - Focus: Disclosure timeline + in-the-wild tracking
  - Timeline:
    - 2026-10-17: Honeypot attempts
    - 2026-10-20/21: Public disclosure
    - 2026-10-21 07:43 UTC: Cloudflare attacks

---

## 📦 LOCAL REPOSITORY MAP

```
repos/
├── CVE-2026-109618-CVSS-9.2-Critical/       [WoYinDao technical analysis]
├── Mitigating-Web-Shells/                   [NSA guidance + LogCheck.py]
├── Reversing-Vulnerabilities/               [jaiswalakshansh WAF-RULES.md]
│   └── CVE-2026-109618-109619/
├── WebShell-Analyzer/                       [Log parser comparison]
├── detection-rules/                         [Elastic rules library]
│   └── rules/
├── emerging-exploit.rules                   [ET exploit signatures - 1.5M]
├── emerging-hunting.rules                   [ET hunting rules - 941K]
├── emerging-user_agents.rules               [ET UA patterns - 165K]
├── php-uploadprogress-waf/                  [⭐ Multi-platform R1-R8 signals]
│   ├── docs/detection-platforms.md
│   ├── modsecurity/
│   ├── suricata/
│   ├── nginx-njs/
│   ├── aws-waf/
│   └── python/
├── php2shell-detection/                     [Lexsah Suricata SID 9109618xx]
├── php_webshell_rules.yara                  [cPanel YARA - 6912 lines]
├── sigma/                                   [SigmaHQ webserver rules]
│   └── rules/web/webserver_generic/
└── web-log-anomaly-detector/                [90+ regex patterns]
```

---

## 🔍 SEARCH QUERIES FOR UPDATES

### Google Dorks
```
"CVE-2026-109618" OR "CVE-2026-109619" after:2026-10-21
"PHP2Shell" detection rules
"PHP_SESSION_UPLOAD_PROGRESS" exploit
site:github.com "CVE-2026-109618" rules
```

### GitHub Search
```
CVE-2026-109618 language:python OR language:bash
PHP2Shell detection waf modsecurity
php-uploadprogress exploit signature
```

### Suricata/Snort SID Tracking
```
SID:9109618* (Lexsah series)
SID:9000051, 9000002, 9000061 (detqt)
SID:1009618, 1009619, 1009620 (ModSec chain)
```

---

## 📌 PRIORITY READING ORDER

1. **Week 1: Official Context**
   - [ ] NCSC UK advisory
   - [ ] Red Hat CVE-2026-109618 analysis
   - [ ] fixitect FPM markers

2. **Week 2: Rules Deep Dive**
   - [ ] break-the-build multi-platform (R1-R8)
   - [ ] Lexsah Suricata rules
   - [ ] AWS WAF blog
   - [ ] jaiswalakshansh ModSec chains

3. **Week 3: Host-Side Detection**
   - [ ] StackShield (parse timing)
   - [ ] dev.to (post-patch checklist)
   - [ ] NSA LogCheck.py

4. **Week 4-5: Implementation**
   - [ ] Study local repos
   - [ ] Extract patterns → JSON rules
   - [ ] Build plugin architecture

---

## 🔄 UPDATE POLICY

- **Daily**: Check ThreatCluster for new campaigns
- **Weekly**: GitHub search for new detection repos
- **Monthly**: Emerging Threats rule updates
- **Quarterly**: Review vendor advisories for backport status

---

*Last updated: 2026-10-23*
*All links verified: 2026-10-23*
*Local repos synced: 2026-10-23*

---

## 🎯 CYBAVERSE — COMPREHENSIVE REMEDIATION GUIDE

### Official Page
- **URL**: https://www.cybaverse.co.uk/threats/php2shell-checker
- **Type**: Complete remediation + hunting guide
- **Focus**: 24-hour action plan + free detection scripts
- **Last Updated**: 21 Oct 2026, 17:25 BST

### Key Resources

#### Checker Scripts (Free)

- **Linux Script** (`check-php2shell.sh`): 
  - Finds all PHP binaries (CLI, FPM, cgi, mod_php, cPanel, Plesk, Bitnami, XAMPP, containers)
  - Reads versions + checks distro backports
  - Hunts logs for memory exhaustion/worker crashes
  - Usage: `sudo bash check-php2shell.sh`
  - Local: `repos/check-php2shell.sh`

- **Windows Script** (`Check-PHP2Shell.ps1`):
  - Finds PHP for IIS, FastCGI, XAMPP, WAMP, Laragon, Plesk
  - Hunts event log for PHP crashes
  - Usage: `powershell -ExecutionPolicy Bypass -File .\Check-PHP2Shell.ps1`
  - Download: Full pack (zip)

- **Full Pack Download**:
  - URL: https://www.cybaverse.co.uk/hubfs/php2shell-detection-pack-v8/php2shell-detection-pack.zip
  - Includes: Both scripts, README, examples

#### Key Information

| Item | Value |
|------|-------|
| **CVSS** | 9.2 (v4.0) |
| **CVEs** | CVE-2026-109618, CVE-2026-109619 |
| **Fixed Versions** | 8.5.12, 8.4.27, 8.3.36, 8.2.35 |
| **Fix Release** | 21 Oct 2026, 14:00 UTC |
| **Status** | Public PoC, active exploitation |
| **Timeline** | Disclosure 20 Oct, patch 21 Oct |

#### What to Do (24 Hours)

**Proactive**:
- Inventory all PHP (vendors, Windows, cPanel, Plesk)
- Update to fixed versions (mod_php first)
- Apply interim settings if can't update today
- PHP 8.1+ EOL: backport or upgrade or isolate

**Reactive**:
- Alert on shells spawned from PHP workers
- Scan webroot for new .php files
- Review logs: multipart POSTs, memory exhaustion
- Check persistence: cron, SSH keys, users

#### Proactive Steps (6-Step Verification)

1. Check PHP version (`php -v`)
2. Use phpinfo safely (`php -i | grep -i version`)
3. Identify SAPI (FPM/CGI/mod_php)
4. List packages (`dpkg -l | grep php`)
5. Check control panels (cPanel MultiPHP, Plesk)
6. Interim mitigation settings (if can't update):
   ```ini
   session.upload_progress.enabled = 0
   post_max_size = 8M
   upload_max_filesize = 4M
   php_admin_value[memory_limit] = -1
   ```

#### Reactive Hunts (5 Hunts)

1. **Shell spawning**: `ps -ef --forest | grep php-fpm; ausearch -i -sc execve | grep php-fpm | grep bash`
2. **New webshells**: `find /var/www -name "*.php" -mtime -2 -printf "%T+ %p\n"`
3. **Log anomalies**: multipart POSTs, memory exhaustion, timeouts, exits
4. **Persistence**: outbound connections, cron jobs, SSH keys, users
5. **Post-compromise**: isolate, preserve logs, hunt webshells, check backdoors

#### Script Verdicts

- **PATCHED**: Changelog mentions both CVEs OR version ≥ fixed
- **LIKELY VULNERABLE**: Version < fixed AND no CVE in changelog
- **UNKNOWN**: Version unreadable, only 1 CVE, vendor-specific

#### Exit Codes (for RMM/Automation)

- 0 = PATCHED or no PHP
- 1 = At least one LIKELY VULNERABLE
- 2 = At least one UNKNOWN, none vulnerable
- 3 = Log entries to review

#### Local Reference

- **Markdown guide**: `docs/CYBAVERSE_GUIDE.md` (comprehensive)
- **Linux script**: `repos/check-php2shell.sh` (12 KB)
- **README**: `repos/CYBAVERSE_README.md` (official)

---

