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
  # source=health: sự kiện của CHÍNH monitor (nguồn log bị mù, plugin bị
  # PLUGIN_TIMEOUT cắt). Không phải tấn công, nên không được là CRITICAL, nhưng
  # cũng KHÔNG được chìm vào INFO: alert INFO bị bỏ qua đúng lúc kênh cảnh báo
  # đang hỏng — đó là lý do sự cố container_accesslog tồn tại bao lâu mà không ai
  # thấy. Đếm riêng để nâng mức tối thiểu ở END.
  if ($2 == "health") health_hits++

  # one raw line can satisfy several rules (comma list): count each separately
  n = split(rule, rl, ",")
  for (i = 1; i <= n; i++) if (rl[i] != "") rule_count[rl[i]]++
  sev_count[sev]++

  r = rank(sev)
  if (r > top_rank) { top_rank = r; top_sev = sev }

  print rec($1, rule, sev, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
}

END {
  # Alert severity là phát biểu về SERVER. Ưu tiên MỨC ĐỘ trước, SỐ LƯỢNG sau:
  #
  #   1. impact=rce   -> CRITICAL, bất kể số event (kể cả 1). Đây là bằng chứng
  #                      server đã bị chiếm: shell trên đĩa, lệnh đã chạy, LFI đã
  #                      đọc được file thật. Mức độ không được thua số lượng.
  #   2. còn lại      -> theo SỐ LƯỢNG: >= crit_threshold là MODERATE (leo thang
  #                      ồ ạt), dưới ngưỡng là INFO (dò quét / nhiễu nền).
  #
  # Rule nào đáng là "bằng chứng" thì phải tự khai `impact":"rce"` trong pack.
  # P2S-057 làm đúng việc đó: 2xx + tham số nhận đường dẫn tuyệt đối = LFI đã
  # thực sự đọc được file, khác hẳn 404 = chỉ đang thử.
  if (rce_hits > 0)                  final_sev = "CRITICAL"
  else if (total >= crit_threshold)  final_sev = "MODERATE"
  else                               final_sev = "INFO"
  # Sàn HIGH cho sự kiện sức khoẻ: "monitor đang mù" phải đọc được ngay trên
  # Telegram, không phải một dòng INFO lẫn trong batch nhiễu.
  if (health_hits > 0 && final_sev != "CRITICAL") final_sev = "HIGH"

  printf "%d\t%s\t%d\n", total, final_sev, rce_hits > (outcounts)
  for (k in rule_count) printf "R\t%s\t%d\n", k, rule_count[k] > (outcounts)
  for (k in sev_count)  printf "S\t%s\t%d\n", k, sev_count[k]  > (outcounts)
}
