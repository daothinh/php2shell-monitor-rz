# ARCHITECTURE.md — PHP2SHELL MONITOR

**Scope**: phát hiện khai thác CVE-2026-109618 / CVE-2026-109619 trên một host.
**Model**: một batch 5 phút → tối đa một alert → kèm toàn bộ dòng log gốc.

---

## 1. Nguyên tắc

1. **Read-only trên host**: chỉ đọc log; mọi ghi nằm dưới `/opt/php2shell-monitor`
   (`$WORKDIR`), là thư mục duy nhất tool tạo ra trên hệ thống.
2. **Một alert mỗi batch**, severity = mức cao nhất trong batch. Không dedup,
   không correlation, không scoring — người đọc nhận đúng một thông báo và
   toàn bộ bằng chứng trong đó.
3. **Bằng chứng không bị mất**: mỗi hit giữ `file` + `line` + `raw`; bản đầy đủ
   luôn nằm trong `evidence/<batch>.jsonl`.
4. **Không có nguồn nào là bắt buộc**: plugin thiếu nguồn thì im lặng, rule thiếu
   capability thì tắt (ghi lý do vào status).

## 2. Luồng một batch

```
                 plugins (13)                    rule pack (JSONL)
 log files ──► offset đọc theo inode/byte/line ──► khớp trên TỪNG field
                                                        │
                                                        ▼
                                        hits: ts source file line ip method
                                              uri status ua pid msg rule sev
                                                        │
                                                        ▼
                                     report.sh: gom thành MỘT alert
                                       severity = max(hit.severity)
                                       rules    = đếm theo rule
                                       evidence = mọi hit (file:line + raw)
                                                        │
                        ┌───────────────────────────────┴────────────────┐
                        ▼                                                ▼
            alerts/queue.jsonl                        evidence/<batch>.jsonl
            (1 dòng / batch có hit)                   (đầy đủ, không cắt)
                        │
                        ▼
            run/batches.log (mọi batch, kể cả no-hits)
```

## 3. Stream contract

`lib/stream.sh`, 12 field TAB, một dòng một record:

| # | field | ghi chú |
|---|---|---|
| 1 | `ts` | ISO8601 UTC, chuẩn hoá ngay tại parser |
| 2 | `source` | `access_log fpm_error apache_error nginx_error kernel auditd sessions webroot modsec docker proc appcms` |
| 3 | `file` | đường dẫn log/artifact nguồn |
| 4 | `line` | số dòng trong file đó (0 khi không phải file dòng) |
| 5 | `ip` | chỉ khi nguồn thật sự có |
| 6 | `method` | |
| 7 | `uri` | |
| 8 | `status` | |
| 9 | `ua` | |
| 10 | `pid` | |
| 11 | `msg` | **dòng log gốc, nguyên văn** |
| 12 | `rule_hint` | rule parser chắc chắn, ngược lại `-` |

## 4. Rule engine

`engine/rule_match.sh`. Với mỗi rule:

1. lọc record theo `source[]`;
2. `grep -P` PCRE trên **giá trị** của `match.field` (không phải cả dòng TSV);
3. giao với từng điều kiện `match.and[]` (hỗ trợ `neg`);
4. nếu số hit < `match.min` → loại rule khỏi batch (ghi `suppressed` vào batches.log);
5. còn lại: emit mỗi (record, rule) một dòng, field 12 = rule id, field 13 = severity.

`min` thay cho cơ chế aggregate cũ: ngưỡng đơn giản, dễ giải thích, không state.

## 5. Lưu trữ

```
/opt/php2shell-monitor/projects/<project>/devices/<device>/
├── alerts/queue.jsonl
├── evidence/<batch>.jsonl
├── state/{offsets.tsv,capabilities.txt,last_batch}
└── run/{batches.log,scan.log,plugin_status.tsv,plugins.err,engine.err}
```

- `offsets.tsv`: `path 	 inode 	 byte 	 line`. Đổi inode ⇒ đọc lại từ 0.
  Dòng cuối chưa có `
` được để lại cho batch sau.
- Mỗi plugin tự lưu offset của file mình đọc (flock + merge) vì plugin chạy
  trong process con.
- `EVIDENCE_KEEP` giới hạn số file evidence (mặc định 2016 batch ≈ 7 ngày).

## 6. Alert schema

```json
{
  "ts_utc": "2026-10-24T00:05:00Z",
  "batch_id": "20261024T000500Z",
  "project": "khach-hang-a",
  "device": "web01",
  "host": "web01",
  "window_start": "2026-10-24T00:00:00Z",
  "window_end": "2026-10-24T00:05:00Z",
  "severity": "CRITICAL",
  "hits": 8,
  "rules": [{"rule_id": "P2S-010", "hits": 5}],
  "severities": [{"severity": "HIGH", "hits": 7}],
  "evidence_file": ".../evidence/20261024T000500Z.jsonl",
  "evidence_truncated": false,
  "evidence": [
    {"ts_utc": "...", "rule_id": "P2S-010", "severity": "HIGH",
     "source": "fpm_error", "file": "/var/log/php8.2-fpm.log", "line": 11,
     "ip": "", "method": "", "uri": "", "status": "", "ua": "", "pid": "42",
     "raw": "WARNING: [pool www] child 42 said: Allowed memory size ..."}
  ]
}
```

`evidence[]` bị cắt ở `MAX_EVIDENCE_INLINE`; `evidence_file` luôn đầy đủ.

## 7. Plugin

Mỗi plugin: `source` → record. Không plugin nào được làm hỏng batch
(exit != 0 bị ghi vào `plugin_status.tsv` và bỏ qua). Prefilter thô trong plugin
(`grep`/`case`) để giảm dữ liệu; quyết định rule nằm ở rule pack.

## 8. CLI

`once | run | status | stop | discover | retro | export | clean`
(xem `docs/OPERATIONS.md`).

## 8b. Cài đặt & vị trí

- `build.sh` tạo archive với `makeself --needroot --target /opt/php2shell-monitor`:
  kiểm tra root **trước khi** giải nén, và giải nén thẳng vào đích (không staging
  trong `/tmp`, không copy lần hai).
- `bootstrap.sh` chạy tại `$WORKDIR` (suy ra từ đường dẫn của chính nó, nên bản
  `tar.gz` giải nén ở đâu cũng đúng): tạo `conf/ projects/ reports/ run/ tmp/`,
  seed `conf/` từ `conf.default/` nếu chưa có, xoá code cũ không còn trong
  `MANIFEST`, `chown -R root:root`, `chmod 0700` dir / `0600` file, rồi
  `exec bash main.sh "$@"`.
- Không cron, không systemd, không user, không `/etc`, không `/var`,
  không `/usr/local/bin`. Gỡ bằng `-- clean` (`rm -rf` chính `$WORKDIR`).

## 9. Tích hợp central

Monitor chỉ ghi file. Agent (`central-alert-server/client/p2s-agent.sh`) tail
`alerts/queue.jsonl`, POST `/api/v1/ingest-log`. Server lưu SQLite theo
project/device và mirror evidence ra `data/evidence/<project>/<device>/<YYYYMMDD>/`.

---

## Phụ lục: thiết kế gốc (lịch sử)

## 2. ABSTRACTION LAYERS

Monitor detects via **3 stacked layers**, each with distinct signal sources:

```
LAYER 3 (T3): Post-Exploitation Evidence
├─ Kernel: segfault, OOM-kill events
├─ auditd: execve/write syscalls
├─ Webroot: new .php files
└─ App logs: fatal errors during exploitation window

LAYER 2 (T2): Exploitation-in-Progress
├─ FPM: "Allowed memory size exhausted" / "exited on signal 11"
├─ nginx error: 502/timeout loops
├─ Session files: upload_progress_* keys anomalously large/frequent
└─ Kernel logs: worker restart churn

LAYER 1 (T1): Exploitation Attempt Detection
├─ Access logs: POST multipart ≥5 MiB + upload-progress field
├─ Multipart markers: nested field names ≥3 deep
├─ Request metadata: repeated upload-progress fields
├─ User-Agent: "php2shell" string (low confidence alone)
└─ Baseline deviation: POST to URI never seen before + multipart + large body
```

---

## 3. SIGNAL MAPPING (R1-R8 → P2S-001 to P2S-011)

| R-Signal | Rule ID | Detection | Source | Confidence | T-Layer | Latency |
|----------|---------|-----------|--------|-----------|---------|---------|
| R1 | P2S-006 | POST + PHPSESSID + PHP_SESSION_UPLOAD_PROGRESS (both present) | Parsed multipart / ModSec ARGS | MED | T1 | Batch |
| R2 | P2S-002 | Field names nested ≥3 deep (a[b][c]) | Raw body parsing / PCRE | HIGH | T1 | Batch |
| R3 | P2S-007 | Repeated ≥2 upload-progress fields in 1 request | Field enumeration | HIGH | T1 | Batch |
| R4 | P2S-004 | Body ≥5 MiB + multipart + upload-progress | Content-Length check | LOW | T1 | Batch |
| R5 | — | Process post-exploit: shell spawned by php-fpm | auditd/Sigma | CRITICAL | T3 | 60s |
| R6 | — | auditd execve by web UID (33/48/82) | auditd logs | CRITICAL | T3 | 5m |
| R7 | P2S-001 | Multipart field name lacking `filename=` | Raw body PCRE | HIGH | T1 | Batch |
| R8 | P2S-005 | urlencoded POST field ≥3.5 MB / null bytes | Content-Length + body scan | MED | T1 | Batch |

---

## 4. RULE ENGINE ARCHITECTURE

### 4.1 Core Components

```
/opt/php2shell/
├── engine/
│   ├── rule_parser.sh          # Load rules.json, validate schema
│   ├── condition_evaluator.sh  # Boolean algebra: AND/OR/NOT, data source lookups
│   ├── correlator.sh           # IP+timestamp windowing, scoring, state persistence
│   └── alert_queue.sh          # JSONL writer, dedup, rate limiting
├── plugins/
│   ├── accesslog_parser.sh     # Parse nginx/apache access logs
│   ├── fpm_monitor.sh          # Tail FPM error/pool logs (T2 signals)
│   ├── kernel_monitor.sh       # journalctl + rsyslog for segfault/OOM
│   ├── session_scanner.sh      # Scan /var/lib/php/sessions for anomalies
│   ├── webroot_manifest.sh     # Baseline + diff detection
│   └── auditd_parser.sh        # Extract execve/write events (if enabled)
├── state/
│   ├── baseline.json           # 7-day access log baseline (URI + multipart pattern)
│   ├── correlator_state.db     # IP + last T1/T2/T3 event time + score
│   └── session_manifest.json   # Checksum of webroot + session dirs
├── php2shell_scan.sh           # 5-minute cron entry point
└── php2shell_watch.sh          # Realtime watcher (systemd service)
```

### 4.2 Rule Schema (rules.json)

```json
{
  "version": "1.0",
  "rules": [
    {
      "id": "P2S-001",
      "title": "Multipart upload-progress field without filename parameter",
      "description": "Detects PHP_SESSION_UPLOAD_PROGRESS form field not paired with file upload",
      "cve": ["CVE-2026-109618", "CVE-2026-109619"],
      "confidence": 0.85,
      "t_layer": "T1",
      "severity": "HIGH",
      "sources": ["access_log", "modsec_audit_log"],
      "condition": {
        "operator": "AND",
        "operands": [
          { "source": "http.method", "operator": "==", "value": "POST" },
          { "source": "http.content_type", "operator": "contains", "value": "multipart/form-data" },
          { "source": "multipart.field_names", "operator": "contains", "value": "PHP_SESSION_UPLOAD_PROGRESS" },
          { "source": "multipart.field_has_filename", "operator": "==", "value": false }
        ]
      },
      "action": "alert",
      "score": 100
    },
    {
      "id": "P2S-002",
      "title": "Deeply nested field names in multipart request",
      "description": "Field names with ≥3 levels of nesting (a[b][c][...]) in POST body",
      "cve": ["CVE-2026-109618"],
      "confidence": 0.95,
      "t_layer": "T1",
      "severity": "CRITICAL",
      "sources": ["modsec_audit_log", "raw_multipart"],
      "condition": {
        "operator": "AND",
        "operands": [
          { "source": "http.method", "operator": "==", "value": "POST" },
          { "source": "multipart.nesting_depth", "operator": ">=", "value": 3 }
        ]
      },
      "action": "alert",
      "score": 200
    },
    {
      "id": "P2S-010",
      "title": "FPM fatal memory exhaustion",
      "description": "PHP-FPM worker log: 'Allowed memory size ... exhausted'",
      "cve": ["CVE-2026-109618"],
      "confidence": 0.95,
      "t_layer": "T2",
      "severity": "CRITICAL",
      "sources": ["fpm_error_log", "fpm_pool_log"],
      "condition": {
        "operator": "AND",
        "operands": [
          { "source": "fpm_log.message", "operator": "matches", "value": "Allowed memory size.*exhausted" },
          { "source": "log.timestamp", "operator": "within", "value": "±5m" }
        ]
      },
      "action": "alert",
      "score": 250,
      "correlate_with": ["P2S-001", "P2S-002", "P2S-004"]
    }
  ]
}
```

---

## 5. PLUGIN INTERFACE

Each plugin MUST:
1. **Check for source existence** before reading (graceful skip if missing)
2. **Emit JSON events** to stdout (one event per line = JSONL)
3. **Handle log rotation** (read .1, .gz files from same day)
4. **Return exit code 0** even if source missing (not an error)

### Event Schema

```json
{
  "timestamp": "2026-10-23T15:42:33.123Z",
  "source": "accesslog",
  "event_type": "signal",
  "rule_id": "P2S-001",
  "severity": "HIGH",
  "confidence": 0.85,
  "ip": "203.0.113.42",
  "method": "POST",
  "uri": "/upload.php",
  "user_agent": "php2shell/1.0",
  "request_size": 5242880,
  "signal_data": {
    "multipart_fields": ["PHP_SESSION_UPLOAD_PROGRESS", "file"],
    "nesting_depth": 0,
    "body_size_mb": 5.0
  }
}
```

### Plugin: accesslog_parser.sh

**Input**: `/var/log/nginx/access.log` (or apache equivalents)
**Logic**:
- Parse combined log format
- Extract: method, URI, request_length, user_agent, status
- If method=POST && multipart content-type marker:
  - Check if request_length ≥ 5 MiB → P2S-004
  - Check if URI contains "upload" or ".php" → P2S-004 context
- If user_agent contains "php2shell" → P2S-001 (weak, gating only)
- Emit JSON per request matching ANY rule

**Output**: One JSON event per matching POST

---

### Plugin: fpm_monitor.sh

**Input**: `/var/log/php*-fpm*.log` or journalctl
**Logic**:
- Tail for patterns:
  - "Allowed memory size of X bytes exhausted" → P2S-010 (CRITICAL)
  - "child N exited on signal 11 (SIGSEGV)" → P2S-011 (CRITICAL)
  - "script ... execution timed out after X seconds" → T2 indicator
- Extract timestamp, worker PID, request info (if available)
- Correlate with access log ±3 seconds to identify attacker IP

**Output**: JSON with correlator pointer (IP TBD from access log join)

---

### Plugin: kernel_monitor.sh

**Input**: `journalctl -k` or `/var/log/kern.log`
**Logic**:
- Grep for:
  - "segfault at" + "php-fpm"
  - "Out of memory: Killed process" + "php-fpm" or "php-cgi"
- Extract timestamp, PID, signal number
- Cross-reference with process startup time to detect worker restart loop

**Output**: JSON with T3 severity marker

---

## 6. CORRELATOR STATE MACHINE

### State Transitions

```
IDLE
  ↓ (T1 event from access log)
T1_DETECTED
  ├─ (no T2 within 5 minutes) → timeout, alert LOW
  └─ (T2 event from FPM log, ±3s window)
      ↓
    T1+T2_DETECTED
      ├─ (no T3 within 5 minutes) → alert MEDIUM
      └─ (T3 event: segfault, auditd execve, webshell drop)
          ↓
        T1+T2+T3_DETECTED → alert CRITICAL
```

### State Storage

```json
{
  "correlation_state.db": {
    "203.0.113.42": {
      "t1_events": [
        { "rule_id": "P2S-001", "timestamp": "2026-10-23T15:42:33Z", "score": 100 }
      ],
      "t2_events": [
        { "rule_id": "P2S-010", "timestamp": "2026-10-23T15:42:36Z", "score": 250 }
      ],
      "t3_events": [],
      "accumulated_score": 350,
      "alert_status": "MEDIUM",
      "last_event": "2026-10-23T15:42:36Z",
      "context": "accessing /upload.php with multipart POST"
    }
  }
}
```

---

## 7. EXECUTION MODES

### Mode 1: Batch (5-minute cron)

```bash
# /etc/cron.d/php2shell-monitor
*/5 * * * * root /opt/php2shell/php2shell_scan.sh
```

**Behavior**:
- Run all plugins in sequence
- Parse logs since last run
- Correlate events (IP + 5-minute window)
- Write alerts to `/opt/php2shell-monitor/alerts/YYYYMMDD-HHMM.jsonl`
- Update state files

**Latency**: 5 minutes (acceptable for baseline/batch signals)

---

### Mode 2: Realtime (systemd service)

```ini
[Unit]
Description=PHP2Shell Realtime Watcher
After=network.target

[Service]
Type=simple
ExecStart=/opt/php2shell/php2shell_watch.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

**Behavior**:
- Tail FPM error log + kernel journal + auditd log (if present)
- Emit events within ≤60 seconds
- Direct correlator invocation (faster state updates)

**Latency**: ≤60 seconds for T2/T3 signals

---

## 8. DEPLOYMENT LAYOUT

### Installation

```bash
# Phase 3 deliverable: full installation script
sudo mkdir -p /opt/php2shell/{engine,plugins,state}
sudo mkdir -p /opt/php2shell-monitor/{alerts,state}
sudo cp -r engine/* /opt/php2shell/engine/
sudo cp -r plugins/* /opt/php2shell/plugins/
sudo chmod 755 /opt/php2shell/*
sudo systemctl daemon-reload
sudo systemctl enable --now php2shell-scan.timer
sudo systemctl enable --now php2shell-watch.service
```

### Log Access

```bash
# Assumes non-root monitoring user: php2shell
# Grant via sudo rules (minimal):
php2shell ALL=(root) NOPASSWD: /bin/journalctl, /usr/bin/tail, /bin/grep, /usr/bin/find

# OR: run via logrotate postrotate hook (if log modification permitted)
```

---

## 9. KNOWN LIMITATIONS & MITIGATION

| Limitation | Impact | Mitigation |
|-----------|--------|-----------|
| POST body not in access log | T1 false negatives | Correlate with FPM/ModSec logs; baseline-based heuristics |
| Multipart body parsing (bash only) | Edge cases in nested fields | Reference break-the-build PCRE patterns; test on samples |
| No network-based inspection | Miss encrypted/tunneled requests | Orthogonal to WAF/IDS layer (separate deployment) |
| journald volatile mode | Loss of logs on reboot | Monitor rsyslog files (.log) as fallback; document requirement |
| FP tuning (legitimate uploads) | Alert fatigue | 7-day baseline + URI whitelist (Phase 3) |
| auditd optional | No process evidence if disabled | Still detects via kernel logs + webroot diff |

---

## 10. SUCCESS CRITERIA

✅ All signals R1-R8 abstracted to JSON rule schema
✅ Plugin interface defined (JSONL event output, graceful skip)
✅ Correlator state machine documented (T1→T2→T3 transitions)
✅ Two execution modes (batch 5m + realtime ≤60s)
✅ Read-only principle preserved throughout
✅ No external Python/Ruby dependencies (bash + POSIX utils only)

---

**Next Phase**: Phase 3 - Core Engine Implementation

*Document prepared by: Scout agents (AnalyzeBreakTheBuild, AnalyzeReversingVulnerabilities, AnalyzeLexsahRules)*
*Reviewed and compiled: 2026-10-23*
