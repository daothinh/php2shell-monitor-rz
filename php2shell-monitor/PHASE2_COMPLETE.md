# PHASE 2 - DESIGN & SPECIFICATION ✅ COMPLETE

**Date**: 2026-10-23
**Status**: READY FOR IMPLEMENTATION

---

## DELIVERABLES

✅ **ARCHITECTURE.md** (13 KB)
- Full system design: 3 detection layers (T1/T2/T3)
- Signal mapping: R1-R8 → P2S-001 to P2S-011
- Plugin architecture & interfaces
- Correlator state machine
- Batch (5m) + Realtime (≤60s) execution modes

✅ **Scout Agent Analysis** (3 agents, 102 KB combined output)
- AnalyzeBreakTheBuild: 38 KB - R1-R8 signals extraction, platform adapters
- AnalyzeReversingVulnerabilities: 32 KB - ModSec chain logic, JSON abstraction
- AnalyzeLexsahRules: 32 KB - Suricata rule patterns, confidence levels

✅ **Docker Lab Environment**
- Vulnerable PHP 8.2.34 + 8.3.35 targets
- Patched PHP 8.2.35 baseline
- Detector container for testing
- Log volume mounts (read-only)

✅ **Attacker Simulation Integration**
- `/home/gaban/Downloads/php2shell` documented in AGENTS.md
- Red team tools available for controlled testing
- Exploit patterns mapped to T1/T2/T3 layers

---

## KEY DESIGN DECISIONS

### 1. Read-Only Principle
- **ZERO host system changes**: No config modifications, no package installs
- Log reading via sudo rules or volume mounts
- State stored in `/var/lib/php2shell/` (monitor-owned)

### 2. Graceful Degradation
- Works with minimal sources (access log only)
- Enhanced coverage when FPM/auditd/ModSec logs available
- Each plugin checks existence → skip if missing (no error)

### 3. Rule Engine Abstraction
- JSON rule schema: platform-independent
- Condition evaluator: AND/OR/NOT boolean algebra
- Data sources: access_log, fpm_log, kernel_log, auditd_log, session_files

### 4. Correlation Strategy
- IP-based windowing (±3 seconds for T1+T2, ±5 minutes for full chain)
- Scoring accumulation: T1=100, T2=250, T3=300+
- State persistence: `/var/lib/php2shell/state/correlator.db`

### 5. Signal Confidence Levels

| Signal | Confidence | T-Layer | False Positive Rate |
|--------|-----------|---------|-------------------|
| P2S-002 (nested ≥3) | 0.95 | T1 | Very Low |
| P2S-007 (repeated field) | 0.90 | T1 | Very Low |
| P2S-010 (FPM memory) | 0.95 | T2 | Low |
| P2S-011 (segfault) | 0.98 | T3 | Very Low |
| P2S-001 (upload-progress) | 0.85 | T1 | Medium |
| P2S-004 (body ≥5MB) | 0.30 | T1 | High |

---

## IMPLEMENTATION PRIORITIES (Phase 3)

### Sprint 1 (Days 1-2): Rule Engine Core
1. JSON rule parser (`engine/rule_parser.sh`)
2. Condition evaluator (`engine/condition_evaluator.sh`)
3. Correlator skeleton (`engine/correlator.sh`)

### Sprint 2 (Days 3-4): High-Confidence Plugins
1. FPM monitor (`plugins/fpm_monitor.sh`) - T2 CRITICAL signals
2. Kernel monitor (`plugins/kernel_monitor.sh`) - T3 segfault/OOM
3. Access log parser (`plugins/accesslog_parser.sh`) - T1 basics

### Sprint 3 (Days 5-6): Advanced Detection
1. Session scanner (`plugins/session_scanner.sh`)
2. Webroot manifest (`plugins/webroot_manifest.sh`)
3. auditd parser (`plugins/auditd_parser.sh`)

### Sprint 4 (Day 7): Integration & Testing
1. Main orchestrator (`php2shell_scan.sh` cron entry)
2. Realtime watcher (`php2shell_watch.sh` systemd service)
3. Docker lab validation

---

## DOCKER LAB STATUS

**Ready for testing**:
```bash
cd /home/gaban/Downloads/php2shell-monitor/docker-lab/vulnerable
docker-compose up -d

# Test endpoints:
# - http://localhost:8082 (PHP 8.2.34 vulnerable)
# - http://localhost:8083 (PHP 8.3.35 vulnerable)
# - http://localhost:8084 (PHP 8.2.35 patched)

# Logs mounted at:
# - docker-lab/vulnerable/logs/php82/
# - docker-lab/vulnerable/logs/nginx82/
```

**Attack simulation**:
```bash
cd /home/gaban/Downloads/php2shell
./p2shell -target http://localhost:8082 -chain A

# Monitor should detect:
# - T1: Multipart POST with upload-progress field
# - T2: FPM memory exhaustion log entry
# - T3: Segfault in kernel logs
```

---

## BASELINE ANALYSIS COMPLETE

Scout agents analyzed:
- **13 GitHub repositories**: Detection rules, exploit analysis, advisory docs
- **6 rule platforms**: Suricata, ModSec, AWS WAF, nginx njs, Sigma, Python
- **11 CVE advisories**: NCSC UK, Red Hat, Ubuntu, Google Cloud, NIST NVD
- **8 detection signals**: R1-R8 mapped to P2S-001 through P2S-011

---

## PHASE 3 ENTRY CRITERIA ✅

- [x] Architecture documented with component boundaries
- [x] Signal confidence levels established
- [x] Plugin interfaces specified (input/output/error handling)
- [x] Rule JSON schema defined
- [x] Correlator state machine designed
- [x] Docker lab environment ready
- [x] Read-only principle validated against plan
- [x] Attacker simulation resources integrated

---

## RECOMMENDED NEXT STEP

**Begin Phase 3 - Core Engine Development**

Start with `engine/rule_parser.sh` + sample rules.json (P2S-001, P2S-010, P2S-011) to validate the abstraction layer before building all plugins.

**Critical path**: FPM monitor (T2) → Correlator → Alert output → Verification in lab

---

*Phase 2 completion verified: 2026-10-23*
*Ready for engineering handoff to Phase 3*
