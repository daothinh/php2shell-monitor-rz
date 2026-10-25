# evidence.awk - stream TSV hits -> evidence JSONL + counts, one process.
# Pure awk: the bash path forked json_obj per hit, which took minutes for a
# 80k-hit batch. Field layout in: ts source file line ip method uri status
# ua pid msg rule severity (13 fields, TAB separated).
# FS must be TAB: the stream is TAB separated and a raw log line contains
# spaces, so the default whitespace splitting would shift every field.
BEGIN {
  FS = "\t"; OFS = "\t"
  top_rank = 0; top_sev = "INFO"; total = 0; rce_hits = 0; impact = ""
  # 5000 events in one 5-minute batch is the point where a php2shell attack
  # stops looking like scanning and starts looking like a sustained run.
  if (crit_threshold == "") crit_threshold = 5000
}

function esc(s) {
  gsub(/\\/, "\\\\", s)
  gsub(/"/, "\\\"", s)
  gsub(/\t/, "\\t", s)
  gsub(/\r/, "\\r", s)
  gsub(/\n/, "\\n", s)
  return s
}

function rank(s) {
  if (s == "CRITICAL") return 5
  if (s == "HIGH") return 4
  if (s == "MEDIUM") return 3
  if (s == "LOW") return 2
  if (s == "INFO") return 1
  return 0
}

function rec(ts, rule, sev, source, file, line, ip, method, uri, status, ua, pid, msg) {
  return "{\"ts_utc\":\"" esc(ts) "\",\"rule_id\":\"" esc(rule) \
    "\",\"severity\":\"" esc(sev) "\",\"impact\":\"" esc(impact) \
    "\",\"source\":\"" esc(source) \
    "\",\"file\":\"" esc(file) "\",\"line\":" (line + 0) \
    ",\"ip\":\"" esc(ip) "\",\"method\":\"" esc(method) \
    "\",\"uri\":\"" esc(uri) "\",\"status\":\"" esc(status) \
    "\",\"ua\":\"" esc(ua) "\",\"pid\":\"" esc(pid) \
    "\",\"raw\":\"" esc(msg) "\"}"
}

{
  rule = $12
  sev = toupper($13)
  impact = $14
  # a stream record that never went through the matcher has 12 fields; guard
  if (rule == "" || NF < 12) next
  if (sev == "") sev = "INFO"
  total++
  if (impact == "rce") rce_hits++

  # one raw line can satisfy several rules (comma list): count each separately
  n = split(rule, rl, ",")
  for (i = 1; i <= n; i++) if (rl[i] != "") rule_count[rl[i]]++
  sev_count[sev]++

  r = rank(sev)
  if (r > top_rank) { top_rank = r; top_sev = sev }

  print rec($1, rule, sev, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
}

END {
  # Alert severity is a statement about the SERVER, not about the loudest rule.
  #   rce_hits > 0                 -> CRITICAL (a shell exists / a command ran)
  #   else total >= CRIT_THRESHOLD -> MODERATE (heavy php2shell exploitation)
  #   else                         -> INFO     (probe / background noise)
  # A noisy probe batch must never be able to claim CRITICAL: only `impact=rce`
  # from the rule pack can, and the rule pack only sets it on proof.
  if (rce_hits > 0)      final_sev = "CRITICAL"
  else if (total >= crit_threshold) final_sev = "MODERATE"
  else                   final_sev = "INFO"

  printf "%d\t%s\t%d\n", total, final_sev, rce_hits > (outcounts)
  for (k in rule_count) printf "R\t%s\t%d\n", k, rule_count[k] > (outcounts)
  for (k in sev_count)  printf "S\t%s\t%d\n", k, sev_count[k]  > (outcounts)
}
