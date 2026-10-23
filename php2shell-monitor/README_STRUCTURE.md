# 📂 PHP2SHELL MONITOR — DIRECTORY STRUCTURE

**Purpose**: Overview of project organization after initial resource gathering.

---

## 🏗️ Current Structure

```
/home/gaban/Downloads/php2shell-monitor/
├── 📄 README_STRUCTURE.md                (this file)
├── 📄 php2shell-monitor-plan.md          (original plan)
├── 📄 AGENTS.md                          (delegation & phases)
│
├── 📚 REFERENCE MATERIALS (Study)
├── 📄 REFERENCE_SOURCES.md               (comprehensive threat intel)
├── 📄 STUDY_CHECKLIST.md                 (7-week learning plan)
├── 📄 QUICK_REFERENCE.md                 (cheat sheet)
│
├── 📁 docs/                              (organized documentation)
│   ├── LINKS.md                          (consolidated URLs)
│   └── RULES_INDEX.md                    (local repo rule catalog)
│
├── 📁 repos/                             (13 cloned repositories)
│   ├── CVE-2026-109618-CVSS-9.2-Critical/
│   ├── Mitigating-Web-Shells/
│   ├── Reversing-Vulnerabilities/
│   ├── WebShell-Analyzer/
│   ├── detection-rules/
│   ├── emerging-exploit.rules
│   ├── emerging-hunting.rules
│   ├── emerging-user_agents.rules
│   ├── php-uploadprogress-waf/            [⭐ PRIMARY]
│   ├── php2shell-detection/
│   ├── php_webshell_rules.yara
│   ├── sigma/
│   └── web-log-anomaly-detector/
│
└── 📁 READY FOR PHASE 2 (Design)
```

---

## 📌 FILE PURPOSES

### Study Materials

| File | Purpose | Audience | Format |
|------|---------|----------|--------|
| `REFERENCE_SOURCES.md` | Full threat intel + advisory compilation | Engineers + SOC | Markdown (~28 KB) |
| `STUDY_CHECKLIST.md` | 7-week learning roadmap with gates | Engineers | Checklist form |
| `QUICK_REFERENCE.md` | Lookup: rule IDs, signals, grep patterns | Ops + developers | Cheat sheet |

### Documentation

| File | Purpose | For |
|------|---------|-----|
| `docs/LINKS.md` | Curated URL list (organized + verified) | Reference library |
| `docs/RULES_INDEX.md` | Local repo catalog + how-to-use | Implementation guide |
| `AGENTS.md` | Delegation plan for development phases | Project management |

### Source Repositories

| Repo | Stars | Purpose | Key File |
|------|-------|---------|----------|
| **php-uploadprogress-waf** ⭐ | Multi-platform | **R1-R8 signals** (primary source) | `signals.md`, `docs/detection-platforms.md` |
| php2shell-detection | Lexsah | Suricata SID 9109618xx | `php2shell.rules` |
| Reversing-Vulnerabilities | jaiswalakshansh | ModSec chain rules (1009618-1009620) | `CVE-*/WAF-RULES.md` |
| detection-rules | Elastic | Web command injection + webshell | `rules/web/` |
| Mitigating-Web-Shells | NSA | Anomaly detection (LogCheck.py) | `LogCheck.py` |
| sigma | SigmaHQ | Sigma YAML webserver rules | `rules/web/webserver_generic/` |
| emerging-*.rules | ET | Community Suricata rules (3.6 MB total) | `*.rules` |
| CVE-2026-109618-CVSS-9.2-Critical | WoYinDao | Technical analysis + limitations | `README.md` |
| WebShell-Analyzer | ekky19 | Access log parser comparison | `webshell_analyzer.py` |
| web-log-anomaly-detector | Datadog variant | 90+ regex patterns | `anomaly_detector.py` |
| sigma (sparse) | SigmaHQ | Webserver generic rules only | `rules/web/webserver_generic/` |
| php_webshell_rules.yara | cPanel | 6912-line YARA webshell signatures | `.yara` (6.9 KB) |

---

## 🔄 PHASE PROGRESSION

### Phase 1: ✅ COMPLETE (Current)

**Deliverables**:
- [x] All 100+ URLs mapped + verified
- [x] 13 repositories cloned locally
- [x] 5 study documents created
- [x] Rule repository indexed
- [x] Reference library organized

**State**: Ready for Phase 2

---

### Phase 2: ⏳ NEXT (Design)

**Inputs**: Everything in `/docs/` + `/repos/`

**Tasks**:
1. Analyze `repos/php-uploadprogress-waf/signals.md`
   - Extract R1-R8 logic
   - Design JSON schema

2. Study ModSec chains (`repos/Reversing-Vulnerabilities/`)
   - Understand rule composition
   - Design condition evaluator

3. Create design docs:
   - `ARCHITECTURE.md` — System design
   - `RULES_SCHEMA.json` — Rule format spec
   - `PLUGIN_INTERFACE.md` — Plugin API

**Owner**: `scout` agent (analysis) + local engineer (design docs)

---

### Phase 3–6: Development

**Location**: `/opt/php2shell/` (new — not created yet)

**Structure**:
```
/opt/php2shell/
├── engine/                       [Rule engine + correlator]
├── plugins/                      [Log parsers + detectors]
├── rules/                        [rules.json + platform adapters]
├── state/                        [Persistence dir]
├── alerts/                       [Alert queue JSONL]
├── php2shell_scan.sh             [5m cron entry point]
├── php2shell_watch.sh            [Realtime watcher]
└── systemd/php2shell-watch.service
```

---

## 📖 HOW TO USE THIS STRUCTURE

### For Learning (Weeks 1–4)

1. Start with: `QUICK_REFERENCE.md` → `REFERENCE_SOURCES.md`
2. Track with: `STUDY_CHECKLIST.md` (7 weeks)
3. Deep dive: Specific links in `docs/LINKS.md`
4. Reference repos: `docs/RULES_INDEX.md` → `repos/`

### For Implementation (Weeks 5+)

1. Read Phase 2 design docs (when created)
2. Refer to: `docs/RULES_INDEX.md` for rule syntax
3. Code against: Design specs + local repos
4. Test with: Sample rules in `repos/php-uploadprogress-waf/`

### For Operations (Phase 6+)

1. Follow: Installation guide (to be written)
2. Troubleshoot: Runbook (to be written)
3. Tune: FP guide (to be written)

---

## 📊 RESOURCE SUMMARY

| Category | Count | Size |
|----------|-------|------|
| Documentation files | 5 | ~60 KB |
| Link URLs (verified) | 100+ | — |
| GitHub repositories | 13 | ~500 MB |
| Local rule files | 4 | 2.6 MB (Suricata+YARA) |
| Study materials | 3 | ~50 KB |
| Reference guides | 2 | ~30 KB |

---

## ✅ CHECKLIST FOR PHASE 2 READINESS

- [x] All reference links consolidated in one place (`docs/LINKS.md`)
- [x] All repositories cloned + organized (`repos/`)
- [x] Rule catalog created (`docs/RULES_INDEX.md`)
- [x] Study materials prepared (3 docs)
- [x] Original plan preserved (`php2shell-monitor-plan.md`)
- [x] Delegation plan documented (`AGENTS.md`)

**Status**: ✅ READY FOR PHASE 2

---

## 🚀 NEXT IMMEDIATE ACTIONS

1. **For Product Owner**: Review `AGENTS.md` phases
2. **For Engineers**: Start with `STUDY_CHECKLIST.md` Week 1
3. **For Technical Lead**: Prioritize Phase 2 design sprint

---

*Last updated: 2026-10-23*
*Project Status: PRE-IMPLEMENTATION*
