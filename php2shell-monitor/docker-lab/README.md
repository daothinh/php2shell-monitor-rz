# PHP2SHELL MONITOR - DOCKER LAB

**Purpose**: Isolated testing environment for PHP2Shell detection validation

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Host: php2shell-monitor development                 │
│  ├─ /opt/php2shell/         (monitor scripts)       │
│  └─ docker-lab/                                      │
│     ├─ vulnerable/          (target containers)      │
│     │  ├─ Dockerfile.php82  (pre-patch vulnerable)  │
│     │  ├─ Dockerfile.php83  (pre-patch vulnerable)  │
│     │  └─ nginx.conf        (test config)           │
│     └─ detector/            (monitor container)      │
│        ├─ Dockerfile        (detector runtime)       │
│        └─ test_payloads/    (attack samples)        │
└─────────────────────────────────────────────────────┘
```

## Test Targets

1. **Vulnerable PHP 8.2** (pre-8.2.35)
2. **Vulnerable PHP 8.3** (pre-8.3.36)
3. **Patched PHP 8.2.35+** (baseline validation)

## Monitor Setup

- Read-only log access from host → container volumes
- JSON alert output to shared volume
- No container modification during runtime

## Usage

```bash
# Build vulnerable targets
cd docker-lab/vulnerable
docker-compose up -d

# Run exploit from attacker toolkit
cd /home/gaban/Downloads/php2shell
./p2shell -target http://localhost:8082 -chain A

# Verify detection
cd /home/gaban/Downloads/php2shell-monitor
./opt/php2shell/php2shell_scan.sh
cat /var/lib/php2shell/alerts/latest.jsonl
```

---

*Status: SETUP PHASE*
*Created: 2026-10-23*
