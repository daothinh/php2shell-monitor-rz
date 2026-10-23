# 📋 PHP2SHELL RULES — LOCAL REPOSITORY INDEX

**Purpose**: Catalog and map all available detection rules locally.

---

## 🏗️ RULE ARCHITECTURE

```
Rule Layer:
├─ HTTP Payload Markers (T1 — Access/ModSec Log)
├─ Host-Side Signals (T2 — FPM/Kernel Log)
├─ Post-Exploit Patterns (T3 — auditd/WebShell)
└─ Webshell & Command Patterns (T3+ — Aftermath)
```

---

## 📍 RULE SOURCES BY LOCATION

### Repository: `repos/php2shell-detection/`
**Type**: Suricata Rules (Lexsah)
**SID Range**: 9109618xx

#### Available Files
```
php2shell-detection/
├── README.md
├── php2shell.rules
└── (other metadata)
```

#### Key Rules
- **SID 910961801**: User-Agent detection (`php2shell`)
- **SID 910961802**: `PHP_SESSION_UPLOAD_PROGRESS` without `filename=`
- **SID 910961803**: Repeated upload-progress fields (≥2 in 1 request)

#### How to Use
```bash
# Copy rules to Suricata
cp repos/php2shell-detection/*.rules /etc/suricata/rules/

# Enable in suricata.yaml
echo "  - php2shell.rules" >> /etc/suricata/suricata.yaml
```

---

### Repository: `repos/php-uploadprogress-waf/` ⭐ PRIMARY
**Type**: Multi-platform ruleset
**Signals**: R1–R8 (unified logic across platforms)

#### Directory Structure
```
php-uploadprogress-waf/
├── docs/
│   ├── README.md
│   ├── detection-platforms.md        [⭐ Platform limits & FP analysis]
│   └── signals.md
├── suricata/
│   ├── php-uploadprogress.rules      [Suricata SIDs]
│   └── README.md
├── modsecurity/
│   ├── php-uploadprogress.conf       [ModSec chain rules 1009618-1009620]
│   └── README.md
├── nginx-njs/
│   ├── php2shell-detect.js           [JavaScript field name capture]
│   └── README.md
├── aws-waf/
│   ├── php2shell-waf.json            [AWS WAF rules - JSON]
│   └── README.md
├── python/
│   ├── php2shell_classifier.py       [Python ML classifier]
│   └── README.md
└── signals.md                        [Signal definitions R1-R8]
```

#### Signal Map (R1–R8)
- **R1**: POST method detection + multipart form-data
- **R2**: `PHP_SESSION_UPLOAD_PROGRESS` field presence
- **R3**: Missing or invalid `filename=` attribute
- **R4**: Nested field names (depth ≥3–20)
- **R5**: Large request body (≥5MB)
- **R6**: Chunked encoding OR missing Content-Length
- **R7**: Multiple `PHP_SESSION_UPLOAD_PROGRESS` fields
- **R8**: NULL bytes in field names (urlencoded variant)

#### Platform-Specific Notes (from `detection-platforms.md`)
- **Suricata**: `request-body-limit` setting affects R2/R3 detection
- **ModSec**: Chain rules best; lookahead for `filename=` required
- **nginx njs**: Real-time field name inspection; no body buffering
- **AWS WAF**: JSON rule size limitations; prefer AND-conditions
- **FP**: `Content-Disposition` with legitimate `filename=""` variants

#### How to Use

**Suricata**:
```bash
cp repos/php-uploadprogress-waf/suricata/*.rules /etc/suricata/rules/
```

**ModSecurity**:
```bash
cp repos/php-uploadprogress-waf/modsecurity/*.conf /etc/modsecurity.d/
```

**nginx njs**:
```bash
cp repos/php-uploadprogress-waf/nginx-njs/*.js /etc/nginx/js/
# Include in nginx.conf:
# js_import php2shell_detect from "/etc/nginx/js/php2shell-detect.js";
```

**AWS WAF**:
```json
// See repos/php-uploadprogress-waf/aws-waf/php2shell-waf.json
// Import via AWS Console or API
```

---

### Repository: `repos/Reversing-Vulnerabilities/CVE-2026-109618-109619/`
**Type**: ModSecurity Rules + Writeup
**Author**: jaiswalakshansh
**Format**: `.conf` chain rules

#### Key ModSec Rules
```
Rule 1009618: Upload-progress field marker
Rule 1009619: Nested field detection (≥20 depth)
Rule 1009620: Content-Length validation
```

#### Rule Logic
```
SecRule REQUEST_METHOD "POST" \
  "id:1009618,chain,msg:PHP2Shell detection chain"
SecRule ARGS "@rx PHP_SESSION_UPLOAD_PROGRESS" \
  "chain"
SecRule REQUEST_FILENAME "@rx \.php$"
```

#### How to Use
```bash
cp repos/Reversing-Vulnerabilities/CVE-2026-109618-109619/*.conf /etc/modsecurity.d/
```

---

### Suricata Rule Files: `repos/emerging-*.rules`
**Type**: Emerging Threats community rules
**Formats**: `.rules` (Suricata/Snort)

#### Files
- `emerging-exploit.rules` (1.5M)
  - Contains exploit pattern signatures
  - Useful for variant attacks
  
- `emerging-hunting.rules` (941K)
  - Threat hunting patterns
  - Anomaly-based rules
  
- `emerging-user_agents.rules` (165K)
  - UA scanning patterns
  - Bot/scanner detection

#### Relevant SIDs (sample)
```bash
grep -i "upload\|progress\|php\|memory" repos/emerging-exploit.rules | head -10
```

#### How to Use
```bash
cp repos/emerging-*.rules /etc/suricata/rules/
```

---

### YARA Rules: `repos/php_webshell_rules.yara`
**Type**: YARA file signatures
**Source**: cPanel tech-CSI
**Lines**: 6912
**Purpose**: Post-exploit webshell detection

#### Sample Patterns
```yara
rule PHP_webshell_shell1 {
    strings:
        $php = "<?php" nocase
        $cmd = /@eval|@system|passthru|exec|shell_exec/ nocase
    condition:
        $php and any of ($cmd*)
}
```

#### How to Use
```bash
# Scan webroot
yara -r repos/php_webshell_rules.yara /var/www/

# Integration (Phase 2)
# → monitor cron job scanning webroot
```

---

### Repository: `repos/sigma/rules/web/webserver_generic/`
**Type**: Sigma YAML rules
**Source**: SigmaHQ
**Format**: YAML (tools convert to Splunk, QRadar, ArcSight, etc.)

#### Key File
- `web_win_webshells_in_access_logs.yml`

#### Example Sigma Rule Structure
```yaml
title: Web Shell Access via WebShell
logsource:
    category: webserver
    product: nginx
detection:
    webshell:
        uri|contains:
            - 'shell.php'
            - 'cmd='
    condition: webshell
```

#### How to Use
```bash
# Install sigma-cli
pip install sigma-cli

# Convert to Splunk
sigma -t splunk repos/sigma/rules/web/webserver_generic/*.yml

# Convert to ELK
sigma -t elasticsearch-qs repos/sigma/rules/web/webserver_generic/*.yml
```

---

### Repository: `repos/detection-rules/rules/`
**Type**: Elastic detection rules
**Source**: Elastic Security
**Format**: Python + YAML + JSON

#### Structure
```
detection-rules/rules/
├── web/
│   ├── detect_web_command_injection.yml
│   └── detect_web_shells.yml
├── endpoint/
└── cloud/
```

#### Relevant Rules
```bash
grep -r "bash -c\|wget\|php" repos/detection-rules/rules/web/ | head -10
```

#### How to Use
```bash
# Import to Elastic Security
cd repos/detection-rules/
python -m detection_rules import-rules --directory rules/web/
```

---

### Repository: `repos/Mitigating-Web-Shells/`
**Type**: NSA guidance + Python tools
**Key Tool**: `LogCheck.py`
**Purpose**: Heuristic web shell detection

#### Files
```
Mitigating-Web-Shells/
├── NSA_Web_Shell_Mitigations.pdf
├── LogCheck.py                   [Main anomaly detector]
├── log_samples/
└── README.md
```

#### LogCheck.py Logic
- Baseline URIs from 7 days
- Detect rare URIs with success (200/201)
- Anomaly scoring for command patterns

#### How to Use
```bash
python repos/Mitigating-Web-Shells/LogCheck.py \
  --baseline 7 \
  --accesslog /var/log/nginx/access.log \
  --output anomalies.json
```

---

### Repository: `repos/web-log-anomaly-detector/`
**Type**: Regex-based anomaly detector
**Patterns**: 90+ OWASP/webshell signatures
**Language**: Python

#### Key Components
```
web-log-anomaly-detector/
├── anomaly_detector.py           [Main detector]
├── patterns/
│   ├── owasp_patterns.txt
│   ├── webshell_patterns.txt
│   └── command_patterns.txt
└── logs/
```

#### Patterns Included
- Command execution: `exec=`, `cmd=`, `command=`
- Base64 decoding: `base64_decode`
- Path traversal: `../`, `..\\`
- SQL injection: `' OR '1'='1`

#### How to Use
```bash
python repos/web-log-anomaly-detector/anomaly_detector.py \
  --logfile /var/log/nginx/access.log \
  --patterns patterns/webshell_patterns.txt \
  --threshold 0.7 \
  --output detections.json
```

---

### Repository: `repos/WebShell-Analyzer/`
**Type**: Log parser + analyzer
**Purpose**: Compare webshell patterns across web servers
**Language**: Python/Bash

#### Features
- Parse access logs (Nginx, Apache, IIS)
- Pattern matching (cmd=, exec=, system=)
- Webshell signature database
- False positive tuning

#### How to Use
```bash
python repos/WebShell-Analyzer/webshell_analyzer.py \
  --server nginx \
  --logfile /var/log/nginx/access.log \
  --pattern-db repos/WebShell-Analyzer/webshell_db.json
```

---

## 📊 RULE CONVERSION MATRIX

| Rule Type | Source Repo | Target Format | Conversion Tool |
|-----------|------------|-----------------|-----------------|
| Suricata | Lexsah | ModSec | Manual (rule IDs differ) |
| ModSec | jaiswalakshansh | Suricata | Manual (chain → single rule) |
| ModSec | break-the-build | nginx njs | Manual (context rewrite) |
| Suricata | Emerging Threats | AWS WAF | Manual (JSON shape) |
| YARA | cPanel | — | Native (no conversion) |
| Sigma | SigmaHQ | Splunk/ELK | sigma-cli |
| Elastic | detection-rules | Splunk | — |

---

## 🎯 RULE ID MAPPING FOR IMPLEMENTATION

| P2S ID | Description | Primary Source | Alternative | Status |
|--------|-------------|-----------------|-------------|--------|
| P2S-001 | Upload-progress NO filename= | Lexsah R2 / detqt 9000051 | jaiswalakshansh 1009619 | ✅ Ready |
| P2S-002 | Nested field ≥3–20 levels | break-the-build R5 / detqt 9000002 | ModSec 1009619 | ✅ Ready |
| P2S-003 | No Content-Length / chunked | detqt 9000061 | ModSec 1009620 | ✅ Ready |
| P2S-004 | POST .php + ≥5MB body | break-the-build R3 | AWS SizeConstraint | ✅ Ready |
| P2S-005 | Huge field name OR null bytes | detqt Datadog variant | — | ⚠️ Variant |
| P2S-006 | POST + PHPSESSID + UP-PROGRESS (AND) | AWS WAF | jaiswalakshansh 1009618 | ✅ Ready |
| P2S-007 | ≥2 upload-progress in 1 req | Lexsah R3 / SID 910961803 | — | ✅ Ready |
| P2S-010 | FPM: memory exhausted | fixitect | — | ⚠️ Host-side |
| P2S-011 | FPM: signal 11 / segfault | fixitect | — | ⚠️ Host-side |
| P2S-030 | Webshell URI pattern | Sigma / NSA LogCheck | Elastic / ET | ✅ Ready |

---

## 📈 RULE COVERAGE BY PLATFORM

### Full Coverage (All 8 HTTP signals)
- ✅ **break-the-build** (R1-R8 unified)
- ✅ **AWS WAF** (custom rules explicit)

### High Coverage (Most signals)
- ✅ **Suricata** (Lexsah + Emerging Threats)
- ✅ **ModSecurity** (jaiswalakshansh + break-the-build)

### Partial Coverage (Specific niches)
- ⚠️ **nginx njs** (field name inspection only)
- ⚠️ **YARA** (post-exploit file signatures only)
- ⚠️ **Sigma** (webshell patterns only)

### Host-Side (Complementary)
- ⚠️ **FPM logs** (memory/signal markers)
- ⚠️ **auditd** (execution proof)
- ⚠️ **Kernel logs** (segfault/OOM)

---

## 🔄 RECOMMENDED INTEGRATION ORDER

1. **Phase 1**: JSON rule engine (P2S-001 to P2S-007)
   - Source: break-the-build + AWS WAF
   - Target: Local `/opt/php2shell/rules.json`

2. **Phase 2**: Host-side plugins
   - FPM log parsing (P2S-010/011)
   - Session file scanner (P2S-002 marker)

3. **Phase 3**: Post-exploit detection
   - Webshell patterns (P2S-030+)
   - auditd integration

4. **Phase 4**: Enhancement rules
   - Sigma rules (if Splunk available)
   - YARA scanning (if enabled)

---

## 📝 LOCAL REFERENCE QUICK COMMANDS

```bash
# Count rules per source
wc -l repos/emerging-*.rules repos/**/php2shell.rules

# Extract Suricata SIDs
grep "^alert" repos/emerging-*.rules repos/php2shell-detection/*.rules | grep -o "sid:[0-9]*" | sort -u

# Find upload-progress patterns
grep -r "PHP_SESSION_UPLOAD_PROGRESS" repos/ --include="*.rules" --include="*.conf" --include="*.js" --include="*.json"

# Extract ModSec rule IDs
grep -h "^SecRule\|id:" repos/Reversing-Vulnerabilities/**/*.conf | head -20

# Test Sigma rules
sigma list-rules repos/sigma/rules/web/

# Count webshell YARA rules
grep "^rule\|^import" repos/php_webshell_rules.yara | wc -l
```

---

## 📌 NEXT STEPS

- [ ] Decide primary platform: Suricata / ModSec / AWS WAF / native
- [ ] Extract signals R1-R8 from break-the-build
- [ ] Convert to JSON rule engine
- [ ] Test on sample traffic
- [ ] Integrate host-side detectors

---

*Last updated: 2026-10-23*
*All repos synced and verified*
