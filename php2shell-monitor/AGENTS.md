# 🤖 AGENTS.md — DELEGATION & COORDINATION

**Purpose**: Define task delegation to subagents for multi-phase development.

---

## 📋 PHASES & DELEGATION

### PHASE 1: Research & Analysis ✅ (Complete)
**Status**: DONE (local session)

**Tasks Completed**:
- ✅ Threat intelligence compilation
- ✅ Reference sources aggregation (100+ links)
- ✅ Local repository cloning (13 repos)
- ✅ Rule catalog & mapping
- ✅ Study materials created

**Outputs**:
- `REFERENCE_SOURCES.md` — Comprehensive threat intel
- `STUDY_CHECKLIST.md` — 7-week learning plan
- `QUICK_REFERENCE.md` — Cheat sheet
- `docs/LINKS.md` — Consolidated URLs
- `docs/RULES_INDEX.md` — Local rule repository map
- `repos/` — 13 cloned GitHub repositories


---

## 🎯 ATTACKER SIMULATION RESOURCES

**Purpose**: Supporting materials for understanding exploitation mechanics and testing detection capabilities.

**Location**: `/home/gaban/Downloads/php2shell`

### Contents

| Directory | Description | Purpose |
|-----------|-------------|---------|
| `p2shell/` | Golang exploitation toolkit (binaries + source) | Red team simulation tool for CVE-2026-109618/109619 |
| `php2shell-poc/` | Original PoC collection | Multiple exploitation chains |
| `php2shell-lab/` | Docker lab environment | Isolated test environment |
| `research/` | Exploitation research & chain calibration | Understanding vulnerability mechanics |
| `admarket/` | Real-world attack patterns | Production attack analysis |

### Key Files

- `BACKDOOR_RESEARCH.md` — Post-exploitation backdoor techniques (27 KB)
- `p2shell/AGENTS.md` — Exploitation toolkit architecture & agents
- `p2shell/RESEARCH.md` — Chain analysis & reliability notes (14 KB)
- `p2shell/README.md` — Toolkit usage guide (28 KB)
- `research/CHAIN_D_CALIBRATION.md` — Chain D exploitation tuning
- `research/chain_d_calibrated.py` — Python exploit script

### Usage for Monitoring Development

1. **Attack Pattern Study**: Review exploitation mechanics to understand detection signals
2. **Test Payload Generation**: Use toolkit to generate known-bad traffic for testing
3. **Docker Lab Integration**: Deploy vulnerable targets for controlled testing
4. **Validation**: Verify detection rules capture actual exploitation attempts

### ⚠️ Security Notice

- **Restricted access**: Tools contain working exploits for critical vulnerabilities
- **Isolated testing only**: Always use Docker lab environment
- **No production use**: Never run against non-test targets
- **Documentation only**: Reference for understanding attack TTPs, not for offensive operations

### Integration with Monitor Development

**Phase 3 (Core Engine)**: 
- Extract attack pattern signatures from `p2shell/` toolkit
- Map exploitation phases to T1/T2/T3 detection layers

**Phase 6 (Testing)**:
- Use controlled exploits to validate detection accuracy
- Generate sample traffic for alert tuning
- Test false positive scenarios with legitimate upload patterns

---

### PHASE 2: Design & Specification (READY)
**Owner**: `scout` agent + local engineering

**Objective**: Design architecture before implementation

**Tasks**:
- [ ] **Scout**: Analyze `repos/php-uploadprogress-waf/` deeply
  - Extract R1-R8 signal definitions
  - Map multi-platform logic (Suricata/ModSec/AWS WAF/njs)
  - Document platform-specific FP modes
  
- [ ] **Scout**: Study `repos/Reversing-Vulnerabilities/` ModSec chains
  - Understand rule composition logic
  - Extract condition syntax patterns
  
- [ ] **Local**: Design JSON rule engine specification
  - Signal schema (ID, logic, source, confidence)
  - Platform adapter pattern
  - Correlation data structure
  
- [ ] **Local**: Design bash plugin architecture
  - Input interface (log paths)
  - Output interface (JSON events)
  - Error handling & graceful degradation

**Expected Output**:
- `ARCHITECTURE.md` — System design document
- `RULES_SCHEMA.json` — Rule JSON specification
- `PLUGIN_INTERFACE.md` — Plugin API

---

### PHASE 3: Core Engine Development
**Owner**: Local (bash engineer)

**Objective**: Build JSON rule engine + base plugins

**Tasks**:
1. **Rule Engine** (`/opt/php2shell/engine/`)
   - [ ] JSON rule parser
   - [ ] Condition evaluator (AND/OR/NOT)
   - [ ] Signal correlator
   - [ ] Scoring calculator
   
2. **Plugins** (`/opt/php2shell/plugins/`)
   - [ ] `accesslog_parser.sh` — Parse nginx/apache logs
   - [ ] `fpm_monitor.sh` — Tail FPM error log for T2 signals
   - [ ] `kernel_monitor.sh` — journalctl + rsyslog segfault/OOM
   - [ ] `session_scanner.sh` — Detect `upload_progress_` markers
   - [ ] `webroot_manifest.sh` — Baseline + diff detection
   - [ ] `auditd_parser.sh` — Extract execve/write events (if available)

3. **Correlator** (`/opt/php2shell/correlator/`)
   - [ ] State persistence (IP, timestamp, sources)
   - [ ] IP-time windowing (±3 seconds)
   - [ ] Scoring aggregation (T1/T2/T3)
   - [ ] Alert queue JSONL writer

4. **Main Script** (`/opt/php2shell/php2shell_scan.sh`)
   - [ ] 5-minute cron wrapper
   - [ ] Plugin orchestration
   - [ ] Correlator invocation
   - [ ] Alert filtering + dedup

**Expected Output**:
- `/opt/php2shell/` directory structure + scripts
- `php2shell_scan.sh` (cron entry point)
- `rules.json` (P2S-001 to P2S-011 implemented)
- Smoke tests passing

---

### PHASE 4: Realtime Watcher
**Owner**: Local (bash engineer)

**Objective**: Build systemd service for ≤60s detection

**Tasks**:
1. **Watcher Script** (`php2shell_watch.sh`)
   - [ ] `tail -F` FPM error log
   - [ ] `journalctl -kf` for segfault/OOM
   - [ ] `tail -F /var/log/audit/audit.log` (if exists)
   - [ ] Per-line event generator
   - [ ] Direct correlator invocation

2. **Systemd Unit** (`php2shell-watch.service`)
   - [ ] Restart policy
   - [ ] Log capture
   - [ ] Dependency on scanner

**Expected Output**:
- `php2shell_watch.sh`
- `systemd/php2shell-watch.service`
- Integration test

---

### PHASE 5: Export & Integration
**Owner**: Local (deferred: telebot/Splunk/YARA)

**Objective**: Output standardization

**Tasks**:
1. **JSON Export** (`export_json.sh`)
   - [ ] Read alert queue
   - [ ] SIEM schema formatting
   - [ ] Output to stdout/file

2. **SQL Export** (deferred)
   - [ ] Alert → SQL INSERT
   - [ ] Schema design
   - [ ] Connection pooling

3. **Deferred Integrations** (Phase 6+)
   - [ ] Telebot notifications
   - [ ] Splunk HEC forwarding
   - [ ] YARA webshell scanning

**Expected Output**:
- `export_json.sh`
- SIEM-ready JSON samples
- SQL schema (spec only)

---

### PHASE 6: Testing & Documentation
**Owner**: Local (QA + docs)

**Objective**: Verification + runbooks

**Tasks**:
1. **Unit Tests**
   - [ ] Rule engine: condition evaluation
   - [ ] Plugins: log parsing
   - [ ] Correlator: state transitions

2. **Integration Tests**
   - [ ] Simulate multipart POST (T1)
   - [ ] Simulate FPM memory exhausted (T2)
   - [ ] Verify alert generation + scoring

3. **Documentation**
   - [ ] Installation guide
   - [ ] Troubleshooting runbook
   - [ ] Rule tuning guide
   - [ ] Log path discovery procedure

**Expected Output**:
- Test suite + fixtures
- Installation guide
- Troubleshooting docs

---

## 📊 DELEGATION MATRIX

| Phase | Owner | Duration | Dependencies | Blocker? |
|-------|-------|----------|--------------|----------|
| 1 (Research) | Local | ✅ Complete | — | — |
| 2 (Design) | scout + local | 2–3 days | Phase 1 | No |
| 3 (Core) | Local | 5–7 days | Phase 2 | **Monitor Phase 1 completeness** |
| 4 (Watcher) | Local | 2–3 days | Phase 3 | No |
| 5 (Export) | Local | 2 days | Phase 3 | No |
| 6 (Test) | Local | 3–5 days | Phase 3/4/5 | No |

---

## 🔗 INTER-PHASE COMMUNICATION

- **Phase 2→3**: Design outputs read by `ARCHITECTURE.md`, `RULES_SCHEMA.json`
- **Phase 3→4**: Correlator state format finalized before watcher integration
- **Phase 4→5**: Alert queue format locked before export script
- **Parallel**: Documentation can start during Phase 3 (low blocker)

---

## ⚠️ BLOCKERS & RISKS

| Risk | Impact | Mitigation |
|------|--------|-----------|
| Rule source inconsistency (Suricata vs ModSec syntax) | Phase 3 delay | Design adapter pattern early (Phase 2) |
| Host environment variations (CentOS/Ubuntu/cPanel) | Plugin robustness | Test discovery script on multiple distros |
| Log rotation edge cases | Data loss during rotation | Explicit log*.gz + boundary handling |
| FP tuning (legitimate uploads) | Alert fatigue | Baseline 7 days + manual tuning guide |
| Realtime latency >60s | Miss T2 evidence | Optimize plugin tail logic, batch size |

---

## 📞 AGENT HANDOFF PROTOCOL

### When Requesting `scout` (Phase 2)

**Input**:
```
Task: Analyze php-uploadprogress-waf signals R1-R8
Directory: repos/php-uploadprogress-waf/
Focus: Extract logic, map to JSON schema, note platform differences
Output: Structured analysis document
```

**Expected Return**:
- Signal definitions table
- Platform adapter notes
- JSON schema draft
- Recommended primary source (break-the-build or AWS)

### When Working Locally (Phases 3–6)

**State File**: `CURRENT_PHASE.md`
- Current phase + task
- Blockers + decisions made
- Git commits reference

**Dependencies**: All Phase 1–2 outputs in `/docs/` + `/repos/`

---

## 🎯 SUCCESS CRITERIA

- ✅ **Phase 1**: All reference links verified, repos cloned, studies created
- ✅ **Phase 2**: Architecture finalized, no ambiguity in signal definitions
- ✅ **Phase 3**: Engine tested on sample rules, plugins emit JSON events
- ✅ **Phase 4**: Watcher detects T2 signals realtime (≤60s latency verified)
- ✅ **Phase 5**: Export format SIEM-compatible, sample alerts produced
- ✅ **Phase 6**: All tests passing, runbooks usable, zero host-system changes

---

## 📝 CURRENT STATUS

```
Phase 1 (Research):     [████████████████████] ✅ COMPLETE
Phase 2 (Design):       [████████████████████] ✅ COMPLETE (cook.md PLAN v4)
Phase 3 (Core Engine):  [████████████████████] ✅ COMPLETE (src/, JSONL rule pack)
Phase 4 (Watcher):      [████████████████████] ✅ COMPLETE (realtime, 3s verified)
Phase 5 (Export):       [████████████████████] ✅ COMPLETE (JSON+SQL; telebot/Splunk/YARA deferred)
Phase 6 (Test/Docs):    [████████████████████] ✅ COMPLETE (17/17 tests, docs/OPERATIONS.md)
```

**Next Action**: Deploy `dist/php2shell-monitor.sh` to target host: `-- discover` → `-- retro` → `-- run` (docs/OPERATIONS.md).

---

*Last updated: 2026-10-23 (PLAN v4 implemented — see docs/OPERATIONS.md)*
*Version: 2.0*
