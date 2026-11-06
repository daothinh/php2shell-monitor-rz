#!/usr/bin/env bash
# p2s-backfill-history.sh — vá LỊCH SỬ trên central server cho các dự án còn ở
# monitor <= 1.4.2: alert đã lưu nhưng alert_hits không có raw (row rác NULL),
# nên /alerts/{id} và /search mù.
#
# Chạy TRÊN MÁY CENTRAL SERVER (cùng máy với alerts.db + evidence mirror).
#
#   ./p2s-backfill-history.sh --db /data/alerts.db --evidence /data/evidence
#   ./p2s-backfill-history.sh --db ... --evidence ... --limit 5000 --dry-run
#   ./p2s-backfill-history.sh --db ... --evidence ... --project domain.cnht.vn
#
# Idempotent: alert đã có raw thì bỏ qua, chạy lại bao nhiêu lần cũng được.
set -u

DB=''; EVID=''; LIMIT=500; CAP=2000; DRY=0; PROJ=''
while [[ $# -gt 0 ]]; do
  case $1 in
    --db) DB=${2:?}; shift 2 ;;
    --evidence) EVID=${2:?}; shift 2 ;;
    --limit) LIMIT=${2:?}; shift 2 ;;
    --cap) CAP=${2:?}; shift 2 ;;
    --project) PROJ=${2:?}; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) printf 'tham số không hợp lệ: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[[ -r $DB ]] || { printf 'thiếu/không đọc được --db (alerts.db)\n' >&2; exit 2; }
[[ -d $EVID ]] || { printf 'thiếu/không thấy --evidence (evidence root)\n' >&2; exit 2; }

python3 - "$DB" "$EVID" "$LIMIT" "$CAP" "$DRY" "$PROJ" <<'PY'
import sys, os, json, sqlite3, glob
db_path, evid_root, limit, cap, dry, proj = sys.argv[1:7]
limit, cap, dry = int(limit), int(cap), dry == '1'

def slug(s):
    out = ''.join(c if (c.isalnum() or c in '._-') else '_' for c in str(s or ''))
    return out.strip('._-')[:64] or 'unknown'

con = sqlite3.connect(db_path); con.row_factory = sqlite3.Row
q = ("SELECT a.id, a.batch_id, a.hit_count, a.project_id, p.project_name, d.device_name"
     "  FROM alerts a JOIN projects p ON p.id = a.project_id"
     "  JOIN devices d ON d.id = a.device_id"
     " WHERE NOT EXISTS (SELECT 1 FROM alert_hits h WHERE h.alert_id = a.id"
     "                    AND h.raw IS NOT NULL AND h.raw <> '')")
args = []
if proj:
    q += " AND p.project_name = ?"; args.append(proj)
q += " ORDER BY a.id DESC LIMIT ?"; args.append(limit)
todo = con.execute(q, args).fetchall()
print(f"alert cần vá: {len(todo)} (giới hạn {limit})")

fixed = rows_added = missing = 0
for r in todo:
    base = os.path.join(evid_root, slug(r['project_name']))
    cand = sorted(glob.glob(os.path.join(base, '*', slug(r['batch_id']) + '.jsonl')))
    if r['device_name']:
        want = slug(r['device_name'])
        cand = [c for c in cand if want in os.path.basename(os.path.dirname(c))] or cand
    if not cand:
        missing += 1
        continue
    path = cand[0]
    rows = []
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.strip()
            if not line or '"raw"' not in line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if not isinstance(rec, dict) or not rec.get('raw'):
                continue
            rows.append((int(r['id']), rec.get('rule_id'), rec.get('severity'),
                         rec.get('source'), rec.get('file'), int(rec.get('line') or 0),
                         rec.get('ip'), rec.get('method'), rec.get('uri'),
                         rec.get('status'), rec.get('ua'), rec.get('pid'),
                         rec.get('raw'), rec.get('ts_utc')))
            if len(rows) >= cap:
                break
    if not rows:
        missing += 1
        continue
    if dry:
        print(f"  [dry] alert {r['id']} {r['batch_id']}: +{len(rows)} row từ {path}")
    else:
        con.execute("DELETE FROM alert_hits WHERE alert_id = ? AND raw IS NULL", (r['id'],))
        con.executemany(
            "INSERT INTO alert_hits (alert_id, rule_id, severity, source, file, line,"
            " ip, method, uri, status, ua, pid, raw, ts_utc)"
            " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)", rows)
        con.execute("UPDATE alerts SET evidence_truncated = 1 WHERE id = ? AND hit_count > ?",
                    (r['id'], len(rows)))
    fixed += 1; rows_added += len(rows)
if not dry:
    con.commit()
print(f"đã vá: {fixed} alert / {rows_added} row | không tìm thấy evidence: {missing}")
if missing:
    print("  (evidence đã bị retention xoá hoặc chưa từng upload — dữ liệu đó không còn)")
PY
