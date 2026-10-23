# 🔍 CYBAVERSE PHP2SHELL CHECKER — COMPREHENSIVE GUIDE

**Source**: https://www.cybaverse.co.uk/threats/php2shell-checker  
**Last Updated**: 21 October 2026, 17:25 BST  
**Status**: Official comprehensive remediation + hunting guide

---

## 🎯 EXECUTIVE SUMMARY

| Attribute | Value |
|-----------|-------|
| **CVSS Score** | 9.2 (CVSS v4.0) |
| **CVEs** | CVE-2026-109618, CVE-2026-109619 |
| **Type** | Two unauthenticated RCE vulnerabilities |
| **Impact** | Code execution as web worker account |
| **Fixed Versions** | PHP 8.5.12, 8.4.27, 8.3.36, 8.2.35 |
| **Release Date** | 21 Oct 2026, 14:00 UTC |
| **Status** | Public exploit code exists, active exploitation reported |
| **Recommendation** | **UPDATE IMMEDIATELY** — mod_php servers first |

---

## 📅 TIMELINE

| Date | Event |
|------|-------|
| 20 Oct 2026 | Leak of two PHP RCE flaws; PHP publishes advance notice same evening |
| 21 Oct 14:00 UTC | PHP releases 8.5.12, 8.4.27, 8.3.36, 8.2.35 with full advisories |
| **Every version below these in each branch is affected** |
| Now | Update internet-facing PHP first; mod_php servers highest priority |

---

## ⚡ ACTION PLAN — NEXT 24 HOURS

### Proactive Track (Left — Prevention)

1. **Inventory every PHP install**
   - Include vendor appliances, Windows bundles, cPanel, Plesk
   - Check every site in shared hosting environments

2. **Update to fixed versions**
   - PHP 8.5.12, 8.4.27, 8.3.36, or 8.2.35
   - Internet-facing servers FIRST
   - **Apache mod_php servers BEFORE anything else** (highest risk)

3. **If cannot update today**
   - Apply interim settings (Step 6 below)
   - Restart every worker
   - Note: Reduces but does NOT guarantee safety

4. **PHP 8.1 and older (EOL)**
   - Apply vendor or PHP source backport
   - OR upgrade to supported version
   - OR take system offline immediately

### Reactive Track (Right — Detection)

1. **Alert on shell spawning**
   - Monitor: php-fpm, php-cgi, httpd, apache2 launching shells/interpreters/download tools
   - Watch for: recon commands from web stack

2. **Scan for webshells**
   - New .php files in web roots
   - Unexpected files in upload directories

3. **Review logs**
   - Odd multipart POSTs
   - Fatal errors
   - "Maximum execution time exceeded"
   - Unexpected PHP-FPM child exits

4. **Check persistence**
   - Outbound connections from PHP workers
   - New cron jobs
   - New users and SSH keys

5. **If compromise suspected**
   - ISOLATE immediately
   - Preserve web and PHP logs
   - Hunt for webshells and persistence

---

## 🛡️ PROACTIVE: CHECK YOUR SERVERS

### Step 1: Check PHP Version

**Command**:
```bash
php -v
```

**Important Notes**:
- CLI PHP may differ from web server PHP
- Check installed version serving websites
- On Windows: run from PHP install folder
- Check vendor bundles (cPanel, Plesk, XAMPP, etc.)

**Fixed Versions**:
- 8.5.12, 8.4.27, 8.3.36, 8.2.35
- Anything lower in same branch = AFFECTED
- 8.1 and older = NEEDS BACKPORT or UPGRADE

---

### Step 2: Use phpinfo Safely

**Preferred (safer) method**:
```bash
php -i | grep -iE "PHP Version|Server API"
```

**If must use web page**:
- Use random file name
- Restrict to your IP only
- Delete immediately after

**Why**: phpinfo() exposes configuration helping attackers

---

### Step 3: Check PHP Runtime Mode

**Determine which SAPI is in use**:
```bash
ps aux | grep -E "php-fpm|php-cgi|httpd|apache2" | grep -v grep
systemctl list-units --type=service | grep -i php
php-fpm -v
apachectl -M 2>/dev/null | grep -i php
grep -Rni "fastcgi_pass" /etc/nginx 2>/dev/null
```

**Affected SAPIs** (all are vulnerable):
- Apache mod_php (⚠️ **HIGHEST RISK** — update first)
- PHP-FPM (FrankenPHP, LiteSpeed also affected)
- php-cgi

---

### Step 4: List Installed PHP Packages

**Check for distro backports** (often undetectable by version alone):

```bash
# Debian / Ubuntu
dpkg -l | grep php

# RHEL family
rpm -qa | grep -i php

# Alpine
apk info | grep -i php

# Docker
docker images | grep -i php
```

**Important**: Distributions received fix in advance and often backport without changing version number.  
**Action**: Check package changelog or vendor security tracker for CVE-2026-109618 and CVE-2026-109619.

---

### Step 5: Check Hosting Control Panels

| Platform | Location | Steps |
|----------|----------|-------|
| **cPanel** | MultiPHP Manager | View PHP version set for each domain |
| **Plesk** | Tools & Settings → PHP Settings | Check each subscription's Hosting Settings |
| **Shared Hosting** | Per-site config | Check EVERY site, not just server default |
| **Managed WordPress** | Per-site setting | Verify each individual site |

---

### Step 6: Interim Settings (If Cannot Update Today)

**PHP's temporary mitigation measures** (reduce but do NOT eliminate exposure):

```ini
; In php.ini, FPM pool config, or server config
; NOT in ini_set() or .user.ini

session.upload_progress.enabled = 0
post_max_size = 8M              ; increase to 32M if uploads needed
upload_max_filesize = 4M        ; keep below post_max_size
fatal_error_backtraces = 0      ; PHP 8.5 only

; Enforce memory_limit (prevent app override)
php_admin_value[memory_limit] = -1          ; FPM pool
php_admin_value memory_limit -1             ; Apache mod_php
```

**After configuration changes**:
1. Restart every PHP worker
2. Enforce request size/field/part/header/nesting limits at web server or proxy
3. Include requests WITHOUT Content-Length header
4. Use container or cgroup memory limit (NOT RLIMIT_AS/RLIMIT_DATA)
5. Hiding errors (error_reporting, display_errors, @) does NOT help

**Post-patch action**:
After updating PHP, review `memory_limit` and `post_max_size` settings. Patch adds hard limit above `memory_limit` that terminates PHP process immediately if exceeded. PHP recommends conservative `post_max_size` and proxy request limits post-patching.

---

## 🧪 CYBAVERSE CHECKER SCRIPTS

**Source**: Free tools tested by CybaVerse threat hunt team  
**Local**: `repos/check-php2shell.sh` (Linux), `repos/CYBAVERSE_README.md`  
**Download Full Pack**: https://www.cybaverse.co.uk/hubfs/php2shell-detection-pack-v8/php2shell-detection-pack.zip

### Linux Script: `check-php2shell.sh`

**What it finds**:
- Every PHP binary (CLI, FPM, cgi, mod_php, cPanel, Plesk, Bitnami, XAMPP, containers)
- Reads version from each
- Checks package changelog for distro backports (Debian, Ubuntu, RHEL, Rocky, Alma)
- Alpine: package version only (changelog not available)
- Reports key ini values and partial mitigations
- Hunts PHP-FPM, Apache, nginx, PHP, syslog, journald logs for:
  - Memory exhaustion
  - Worker crashes

**Usage**:
```bash
sudo bash check-php2shell.sh
```

Run as root for full access to logs and package databases.

**Download**:
```bash
curl -L "https://www.cybaverse.co.uk/hubfs/php2shell-detection-pack-v8/check-php2shell.sh" -o check-php2shell.sh
sudo bash check-php2shell.sh
```

### Windows Script: `Check-PHP2Shell.ps1`

**What it finds**:
- PHP for IIS, FastCGI, XAMPP, WAMP, Laragon, Plesk, PATH
- Reads version and key ini values
- Hunts PHP/web server logs
- Hunts Application event log for PHP executable crashes

**Usage**:
```powershell
powershell -ExecutionPolicy Bypass -File .\Check-PHP2Shell.ps1
```

Unzip first, run from elevated PowerShell for log/event log access.

**Download**:
```
https://www.cybaverse.co.uk/hubfs/php2shell-detection-pack-v8/Check-PHP2Shell.zip
```

### Security Design (Read-Only)

**Both scripts**:
- ✅ Read files and query package/event databases only
- ✅ Run only PHP binaries with `-v` and `-i` flags + timeout
- ✅ Linux: Run files only if named like `php*` and compiled binary (skips phpunit, phpcs, wrappers)
- ✅ Windows: Run only `php.exe` and `php-cgi.exe`
- ❌ Do NOT change configuration
- ❌ Do NOT restart services
- ❌ Do NOT write files

**Review before executing** — understand what you're running

### Verdicts Explained

| Verdict | Meaning | Action |
|---------|---------|--------|
| **PATCHED** | Changelog mentions both CVEs OR version ≥ fixed release | No action needed |
| **LIKELY VULNERABLE** | Version < fixed release AND changelog mentions neither CVE | **UPDATE NOW** |
| **UNKNOWN** | Version unreadable, only 1 CVE in changelog, vendor-specific, RC/beta/-dev build | Check with vendor |

### Exit Codes

| Code | Meaning | RMM Use |
|------|---------|---------|
| 0 | Everything PATCHED or no PHP found | ✅ Safe |
| 1 | At least one LIKELY VULNERABLE | 🚨 Escalate |
| 2 | At least one UNKNOWN, none vulnerable | ⚠️ Review |
| 3 | Nothing vulnerable/unknown but log hunt found entries | ⚠️ Manual review |

**MSP/IT Use**: Integrate exit codes into RMM tooling for fleet-wide flagging.

### Script Limitations

⚠️ **Know these limits**:

1. **Verdicts rely on versions + changelogs only**
   - Cannot confirm patch in custom builds, vendor-bundled PHP, changelogs without CVE mention
   - Confirm with whoever built your PHP

2. **PHP 7.4, 8.0, 8.1 minimal backports**
   - Scripts cannot detect these in custom builds
   - Reports as LIKELY VULNERABLE — confirm with builder

3. **Per-site overrides missed**
   - Scripts see: php.ini, conf.d
   - Scripts MISS: FPM pool settings, .htaccess, .user.ini, IIS web.config
   - Manual check required

4. **Standard log paths only**
   - Clean log ≠ proof of safety
   - Failure can occur before PHP writes log

---

## 🔎 REACTIVE: HOW TO HUNT

Hunt on behavior: look for activity following successful PHP RCE exploitation.

### Hunt 1: PHP Workers Spawning Shells

**Detection**: Exploitation usually shows as unexpected child process from web server.

**Alert on**: php-fpm, php-cgi, httpd, apache2 launching:
- Command shell (bash, sh, cmd, powershell)
- Scripting interpreter (python, perl, ruby)
- Network download utility (curl, wget, nc)
- Recon commands (whoami, id, ps, netstat)

**Commands**:

```bash
# Live process tree visualization
ps -ef --forest | grep -E "php-fpm|php-cgi|httpd|apache2" | head -80

# Extract PHP worker children from audit logs
ausearch -i -sc execve 2>/dev/null | \
  grep -E "php-fpm|php-cgi|apache2|httpd" | \
  grep -Ei "bash|curl|wget|python|perl" | \
  tail -50
```

---

### Hunt 2: New PHP Files in Web Roots

**Detection**: Recently changed PHP files after exploitation.

**Commands**:

```bash
# Last 48 hours of .php files in common roots (adjust paths)
find /var/www /home/*/public_html /usr/share/nginx/html \
  -type f -name "*.php" -mtime -2 \
  -printf "%T+ %p\n" 2>/dev/null | sort

# Recently changed PHP in upload directories
find /var/www -type d \
  \( -iname "*upload*" -o -iname "*tmp*" \) 2>/dev/null | \
  while read d; do
    find "$d" -type f -name "*.php" -mtime -2 -ls 2>/dev/null
  done
```

---

### Hunt 3: Suspicious Log Activity

**What to review**:
- Odd multipart POST requests
- Fatal errors with memory exhaustion
- "Maximum execution time exceeded" errors
- Unexpected PHP-FPM worker child exits
- Segmentation faults

**Commands**:

```bash
# FPM log: memory exhaustion
grep -i "memory.*exhausted\|fatal error" /var/log/php*-fpm*.log

# Access log: multipart requests to odd paths
grep -E "multipart|POST.*\.php|POST.*\.phtml" /var/log/nginx/access.log | tail -50

# Nginx error log: 502 / upstream timeout
grep -E "502 Bad Gateway|upstream timed out" /var/log/nginx/error.log | tail -20

# PHP-FPM exits
grep -E "child.*exited|SIGSEGV|signal 11" /var/log/php*-fpm*.log
```

---

### Hunt 4: Persistence Mechanisms

**What to check**:
- Outbound connections from PHP workers
- New cron jobs
- New system users
- New/modified SSH keys

**Commands**:

```bash
# Check outbound connections from PHP processes
ss -tnp 2>/dev/null | grep -E "php-fpm|php-cgi|apache2|httpd"

# Review cron jobs
crontab -l
ls -la /etc/cron.d/
grep -i "php\|apache\|nginx" /var/log/auth.log

# Check for new SSH keys
ls -la /home/*/.ssh/authorized_keys 2>/dev/null
find /root -name "authorized_keys*" -mtime -1 2>/dev/null
```

---

### Hunt 5: After Compromise Discovery

**Immediate actions**:

1. ✅ **ISOLATE** the server immediately
2. ✅ **PRESERVE** web and PHP logs (copy before any cleanup)
3. ✅ **LOOK FOR** webshells:
   ```bash
   find /var/www -type f -name "*.php" -exec grep -l "eval\|system\|passthru\|exec\|shell_exec" {} \;
   ```
4. ✅ **LOOK FOR** persistence:
   - New cron jobs
   - Modified /etc/passwd
   - New SSH keys
   - Backdoored scripts
5. ✅ **COMPARE** file timestamps with logs to determine access path
6. ✅ **NOTIFY** security team for full incident response

---

## 📊 ONLINE PASSIVE CHECK

**CybaVerse Domain Checker**: Enter a domain you own/manage  
**Passive detection**: Single HTTP request to home page, checks for PHP version markers

**Limitations**:
- Cannot prove server is SAFE
- Many servers hide PHP version
- PHP runs on paths/subdomains not visible
- Use as starting point only
- **Confirm on server with steps above**

---

## 🔗 RELATED RESOURCES

**CybaVerse Full Detection Pack**:
- Download: https://www.cybaverse.co.uk/hubfs/php2shell-detection-pack-v8/php2shell-detection-pack.zip
- Includes: check-php2shell.sh, Check-PHP2Shell.ps1, README.md

**Official PHP Advisory**:
- https://www.php.net/releases/8.2.35  
- https://www.php.net/releases/8.3.36  
- https://www.php.net/releases/8.4.27  
- https://www.php.net/releases/8.5.12

**CVE Details**:
- CVE-2026-109618: https://nvd.nist.gov/vuln/detail/CVE-2026-109618
- CVE-2026-109619: https://nvd.nist.gov/vuln/detail/CVE-2026-109619

---

## 📝 IMPLEMENTATION CHECKLIST

### For Your Organization

- [ ] Run discovery script (Linux/Windows) on all PHP hosts
- [ ] Document PHP inventory (versions, SAPI, control panels)
- [ ] Prioritize Apache mod_php servers for immediate patching
- [ ] For unpatched servers: Apply interim settings + restart workers
- [ ] Set up log alerting for shell spawning, memory exhaustion
- [ ] Baseline webroot file inventory
- [ ] Configure cron/alert for new .php files
- [ ] Review auditd/syslog for execve patterns
- [ ] Document remediation timeline per server
- [ ] Plan post-patch verification

### For Detection/Hunting

- [ ] Enable auditd (if not already)
- [ ] Configure access log with full multipart details
- [ ] Set memory_limit alert threshold in PHP
- [ ] Create detection queries:
  - PHP worker → shell spawning
  - New .php in webroot
  - Memory exhaustion signals
  - Unexpected exits

---

## ⚠️ CRITICAL REMINDERS

1. **UPDATE IS THE ONLY COMPLETE FIX** — Interim settings reduce risk but do NOT prevent exploitation
2. **Check EVERY site** — Shared hosting requires per-domain verification
3. **Backports matter** — Distros backport fixes without version change
4. **Preserve logs** — If compromise suspected, capture logs before cleanup
5. **Test after patch** — Verify fixed version after applying patch
6. **Monitor post-patch** — Review memory_limit and post_max_size settings

---

*Source: CybaVerse — https://www.cybaverse.co.uk/threats/php2shell-checker*  
*Markdown compiled: 2026-10-23*  
*Last advisory update: 21 October 2026, 17:25 BST*
