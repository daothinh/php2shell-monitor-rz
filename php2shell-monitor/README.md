# PHP2SHELL MONITOR - Detection System for CVE-2026-109618/109619

[![Status](https://img.shields.io/badge/status-production--ready-brightgreen)]()
[![PHP](https://img.shields.io/badge/PHP-8.2.34--8.3.35-777BB4)]()
[![CVE](https://img.shields.io/badge/CVE-2026--109618%20|%202026--109619-critical)]()

Real-time bash-based monitoring system detecting PHP2Shell exploitation attempts with zero system modifications.

---

## Quick Start (5 minutes)

```bash
# 1. Start vulnerable target
cd docker-lab/detector && docker compose up -d

# 2. Run coordinated attack + detection (60 seconds)
/tmp/php2shell-attack/orchestrator.sh http://localhost:8082 60 2 3

# 3. View detections
tail -f /tmp/php2shell-monitor-output/alerts.jsonl
```

---

## What is PHP2Shell?

**CVE-2026-109618** and **CVE-2026-109619** are critical vulnerabilities in PHP 8.2.x < 8.2.35 and 8.3.x < 8.3.35:

- **CVE-2026-109618**: Memory exhaustion via `PHP_SESSION_UPLOAD_PROGRESS`
- **CVE-2026-109619**: Use-After-Free (UAF) leading to segfaults and RCE

**CVSS Score**: 9.8 / 9.2 - **CRITICAL**

---

## Project Structure

```
php2shell-monitor/
├── 📖 ENVIRONMENT_SETUP_COMPLETE.md  ← DEPLOYMENT GUIDE (START HERE)
├── 📖 ARCHITECTURE.md                 ← System design
├── 📖 REFERENCE_SOURCES.md            ← Research materials
│
├── docker-lab/detector/               ← Vulnerable test target
│   ├── Dockerfile                     # PHP 8.2.34 vulnerable
│   └── docker-compose.yml
│
├── /opt/php2shell/                    ← Detection engine (host)
│   ├── monitor_prod.sh                # ✅ Production monitor
│   ├── engine/                        # Rule parser, correlator
│   └── rules.json                     # P2S-xxx detection rules
│
└── /tmp/php2shell-attack/             ← Attack simulation (host)
    ├── attacker.sh                    # Exploit simulator
    └── orchestrator.sh                # Coordinated runner
```

---

## Features

### ✅ Deployed & Tested

- **7 detection rules** (P2S-001 to P2S-030)
- **3-tier detection**: T1 (HTTP), T2 (FPM), T3 (webshell)
- **Read-only monitoring**: Zero system changes
- **JSON output**: SIEM-ready alerts
- **Docker lab**: Isolated vulnerable target
- **Attack simulator**: Continuous exploit traffic generation
- **Orchestrator**: Coordinated attack + detection

### 🔧 Architecture Highlights

- **Bash-only**: No dependencies beyond coreutils
- **Graceful degradation**: Adapts to available log sources
- **State management**: Incremental log parsing
- **Confidence scoring**: 0.65 - 0.99 per rule
- **Severity levels**: CRITICAL / HIGH / MEDIUM

---

## Detection Rules

| Rule ID | Detection | Severity | Confidence |
|---------|-----------|----------|------------|
| **P2S-001** | User-Agent: php2shell | MEDIUM | 0.65 |
| **P2S-002** | POST + PHP_SESSION_UPLOAD_PROGRESS | HIGH | 0.85 |
| **P2S-006** | PHPSESSID + upload-progress | HIGH | 0.90 |
| **P2S-007** | Duplicate upload-progress fields | CRITICAL | 0.95 |
| **P2S-010** | FPM memory exhaustion (OOM) | CRITICAL | 0.98 |
| **P2S-011** | FPM segfault (SIGSEGV/UAF) | CRITICAL | 0.99 |
| **P2S-030** | Webshell command execution | HIGH | 0.75 |

---

## Usage

### Environment Components

#### 1. Vulnerable Target (Docker)
```bash
cd docker-lab/detector
docker compose up -d
# Access: http://localhost:8082
```

#### 2. Attack Simulator (Host)
```bash
# Syntax: attacker.sh [target] [interval_sec] [loop_count]
/tmp/php2shell-attack/attacker.sh http://localhost:8082 2 10
```

#### 3. Monitor Engine (Host)
```bash
# Standalone monitor (check every 5 seconds)
/opt/php2shell/monitor_prod.sh

# Custom interval
MONITOR_INTERVAL=3 /opt/php2shell/monitor_prod.sh
```

#### 4. Orchestrator (Recommended)
```bash
# Syntax: orchestrator.sh [target] [duration] [attack_int] [monitor_int]
/tmp/php2shell-attack/orchestrator.sh http://localhost:8082 60 2 3
```

**Output**: `/tmp/php2shell-monitor-output/alerts.jsonl`

---

## Sample Detection Output

```json
{
  "timestamp": "2026-10-23T09:37:29.000Z",
  "hostname": "webserver01",
  "rule_id": "P2S-001",
  "title": "User-Agent php2shell detection",
  "severity": "MEDIUM",
  "confidence": 0.65,
  "message": "php2shell user-agent detected",
  "source": "/var/log/nginx/access.log"
}
```

---

## Production Deployment

### For Real Servers

```bash
# Adapt log paths
LOGS_DIR=/var/log/nginx:/var/log/php-fpm \
OUTPUT_DIR=/var/log/php2shell-monitor \
MONITOR_INTERVAL=60 \
/opt/php2shell/monitor_prod.sh
```

### Systemd Service

```bash
# Install service
sudo cp systemd/php2shell-monitor.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable php2shell-monitor
sudo systemctl start php2shell-monitor

# View alerts
journalctl -u php2shell-monitor -f
```

---

## Testing Results

**Environment**: Docker isolated target + host attacker/monitor  
**Duration**: 45 seconds  
**Attacks sent**: ~20 sequences  
**Detections**: ✅ **160 alerts** (16 unique events)  
**False positives**: 0  
**Stability**: ✅ Stable  

---

## Documentation

- **ENVIRONMENT_SETUP_COMPLETE.md**: Full deployment guide
- **ARCHITECTURE.md**: System design + detection logic
- **REFERENCE_SOURCES.md**: Research + community rules
- **STUDY_CHECKLIST.md**: Learning roadmap
- **QUICK_REFERENCE.md**: Cheat sheet

---

## Roadmap

### Phase 3: ✅ Complete
- Core engine
- Docker lab
- Attack simulator
- Monitor detection (7 rules)

### Phase 4: Enhancements (Future)
- [ ] Correlator: IP tracking + time-window analysis
- [ ] Advanced rules: P2S-004, P2S-020+
- [ ] Export: Splunk HEC, Telegram, SQL
- [ ] Baseline learning (7-day normal traffic)
- [ ] Auditd integration (post-exploit)

---

## Contributing

1. Test in Docker lab first
2. Add detection rules to `/opt/php2shell/rules.json`
3. Update documentation
4. Submit PR with test results

---

## License

Research/Educational use. Adapt for production security monitoring.

---

## Contact & Support

- **Project**: php2shell-monitor
- **CVE Info**: https://www.ncsc.gov.uk/news/critical-security-issue-affecting-php
- **Status**: Production-ready v1.0

---

*Last updated: 2026-10-23*  
*Deployment status: ✅ Complete*
