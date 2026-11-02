# preview.awk - gom evidence JSONL thành tối đa N nhóm event cho alert line.
#
# Vì sao: alert phải mang sẵn vài dòng raw để central server render tin Telegram
# ngay, không phải chờ file evidence (evidence upload SAU alert, xem central.sh).
# Nhưng một batch 300k hit không nhét nguyên được — chỉ lấy N nhóm đại diện.
#
# Gộp trùng: hai dòng chỉ khác mốc thời gian `[26/Oct/2026:02:28:18 +0000]` và id
# phiên `sess_p2s52dd...` là CÙNG một dạng request → một nhóm. Nhóm giữ NGUYÊN VĂN
# dòng đầu tiên (không sửa raw), kèm số lần khớp và số dòng log khác nhau.
#
# Thứ tự: impact="rce" lên đầu (lệnh đã chạy / shell đã lên đĩa), rồi theo số
# lần giảm dần. Nhóm ít hit nhưng là bằng chứng RCE phải hiện trước đám scan.
#
# Giá trị lấy từ JSON nguồn được COPY NGUYÊN VĂN (đã escape sẵn) — không escape
# lại, nếu không dấu \ sẽ bị nhân đôi và raw không còn khớp log gốc.
#
# Input : evidence JSONL do evidence.awk sinh ra; `raw` là field CUỐI của object.
#         Chấp nhận cả JSON có khoảng trắng sau dấu hai chấm (bản monitor cũ).
# Output: mỗi nhóm một dòng JSON trên stdout; dòng meta "TOTAL<TAB>UNIQUE" vào
#         file `outmeta` để report.sh biết còn bao nhiêu nhóm chưa hiện.
BEGIN { n = 0; total = 0 }

# valpos(h, key) - vị trí ký tự NGAY SAU dấu " mở đầu giá trị của "key".
# 0 = không có. Bỏ qua khoảng trắng quanh dấu hai chấm.
function valpos(h, key,   pat, p, rest, i, c) {
  pat = "\"" key "\""
  p = index(h, pat)
  if (p == 0) return 0
  rest = substr(h, p + length(pat))
  for (i = 1; i <= length(rest); i++) {
    c = substr(rest, i, 1)
    if (c == ":") continue
    if (c == " " || c == "\t") continue
    if (c == "\"") return p + length(pat) + i
    return 0                      # không phải chuỗi (số/bool/null)
  }
  return 0
}

# sfield(h, key) - nội dung chuỗi (đã escape sẵn), "" nếu không có
function sfield(h, key,   p, rest, q) {
  p = valpos(h, key)
  if (p == 0) return ""
  rest = substr(h, p)
  q = 1
  while (q <= length(rest)) {
    if (substr(rest, q, 1) == "\\") { q += 2; continue }
    if (substr(rest, q, 1) == "\"") return substr(rest, 1, q - 1)
    q++
  }
  return ""
}

# nfield(h, key) - giá trị số của "key":123
function nfield(h, key,   pat, p, rest, i, c, out) {
  pat = "\"" key "\""
  p = index(h, pat)
  if (p == 0) return 0
  rest = substr(h, p + length(pat))
  out = ""
  for (i = 1; i <= length(rest); i++) {
    c = substr(rest, i, 1)
    if (c ~ /[0-9-]/) out = out c
    else if (c == ":" || c == " " || c == "\t") continue
    else break
  }
  return out + 0
}

# rawfield(line) - nội dung raw (đã escape sẵn) của cả dòng JSON.
# raw là field cuối nên lấy từ sau dấu " mở đến "} cuối cùng.
function rawfield(line,   p, rest) {
  p = valpos(line, "raw")
  if (p == 0) return ""
  rest = substr(line, p)
  sub(/"}[ \t\r]*$/, "", rest)
  return rest
}

{
  line = $0
  if (index(line, "\"raw\"") == 0) next
  rule = sfield(line, "rule_id")
  if (rule == "") next
  raw = rawfield(line)
  if (raw == "") next
  total++

  # khoá gộp: bỏ mốc thời gian + id phiên, giữ phần còn lại
  key = raw
  gsub(/\[[^]]*\]/, "[ts]", key)
  gsub(/sess_[A-Za-z0-9]+/, "sess_<id>", key)

  if (!(key in seen)) {
    seen[key] = ++n
    order[n] = n
    g_raw[n] = raw
    g_rule[n] = rule
    g_sev[n] = sfield(line, "severity")
    g_imp[n] = sfield(line, "impact")
    g_src[n] = sfield(line, "source")
    g_file[n] = sfield(line, "file")
    g_line[n] = nfield(line, "line")
    g_cnt[n] = 0
    g_ln[n] = 0
  }
  i = seen[key]
  g_cnt[i]++
  if (nfield(line, "line") > 0) g_ln[i]++
}

END {
  if (max == "") max = 8

  # top `max`: quét nhiều lượt (O(max*n)); n nhỏ vì đã gộp trùng
  picked = 0
  while (picked < max && picked < n) {
    best = 0
    for (i = 1; i <= n; i++) {
      if (used[i]) continue
      if (best == 0) { best = i; continue }
      ir = (g_imp[i] == "rce") ? 1 : 0
      br = (g_imp[best] == "rce") ? 1 : 0
      if (ir > br) { best = i; continue }
      if (ir < br) continue
      if (g_cnt[i] > g_cnt[best]) { best = i; continue }
      if (g_cnt[i] == g_cnt[best] && order[i] < order[best]) best = i
    }
    if (best == 0) break
    used[best] = 1
    picked++

    printf "{\"rule_id\":\"%s\",\"hits\":%d,\"severity\":\"%s\",\"impact\":\"%s\"", \
      g_rule[best], g_cnt[best], g_sev[best], g_imp[best]
    printf ",\"source\":\"%s\",\"file\":\"%s\",\"line\":%d,\"lines\":%d,\"raw\":\"%s\"}\n", \
      g_src[best], g_file[best], g_line[best], g_ln[best], g_raw[best]
  }

  if (outmeta != "") printf "%d\t%d\n", total, n > (outmeta)
}
