# accesslog.awk - fast nginx/apache access log -> stream TSV (lib/stream.sh contract)
# Pure awk (mawk/gawk): no per-line forks; epoch math inline (no mktime needed).
# Usage: awk -f accesslog.awk -v src=access_log /path/access.log
# Emits 14 fields: ts source src_ip method uri status size ua pid sessid file rule msg referer
BEGIN { OFS="\t"; split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", MN, " ") }

function days_from_civil(y, m, d,   era, yoe, doy, doe) {
  y -= (m <= 2)
  era = int((y >= 0 ? y : y - 399) / 400)
  yoe = y - era * 400
  doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
  doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
  return era * 146097 + doe - 719468
}

function civil_from_days(z,   era, doe, yoe, y, doy, mp, d, m, y2) {
  z += 719468
  era = int((z >= 0 ? z : z - 146096) / 146097)
  doe = z - era * 146097
  yoe = int((doe - int(doe/1460) + int(doe/36524) - int(doe/146096)) / 365)
  y = yoe + era * 400
  doy = doe - (365*yoe + int(yoe/4) - int(yoe/100))
  mp = int((5*doy + 2) / 153)
  d = doy - int((153*mp + 2)/5) + 1
  m = mp + (mp < 10 ? 3 : -9)
  y2 = y + (m <= 2)
  return sprintf("%04d-%02d-%02d", y2, m, d)
}

function epoch_to_iso(e,   days, secs, hh, mm, ss) {
  days = int(e / 86400); secs = e - days * 86400
  if (secs < 0) { secs += 86400; days -= 1 }
  hh = int(secs / 3600); mm = int((secs % 3600) / 60); ss = secs % 60
  return civil_from_days(days) "T" sprintf("%02d:%02d:%02dZ", hh, mm, ss)
}

# "21/Oct/2026:13:38:12 +0000" -> ISO UTC
function clf_ts_to_iso(s,   d, mon, y, hh, mi, ss, tz, sign, off, monn, epoch) {
  if (match(s, /[0-9][0-9]\/[A-Za-z][A-Za-z][A-Za-z]\/[0-9][0-9][0-9][0-9]:[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) == 0) return ""
  d = substr(s, 1, 2) + 0; mon = substr(s, 4, 3); y = substr(s, 8, 4) + 0
  hh = substr(s, 13, 2) + 0; mi = substr(s, 16, 2) + 0; ss = substr(s, 19, 2) + 0
  monn = 0
  for (i = 1; i <= 12; i++) if (MN[i] == mon) monn = i
  if (monn == 0) return ""
  tz = substr(s, 22, 5)
  sign = substr(tz, 1, 1); off = 0
  if (sign == "+" || sign == "-") {
    off = (substr(tz, 2, 2) + 0) * 3600 + (substr(tz, 4, 2) + 0) * 60
    if (sign == "+") off = -off
  }
  epoch = days_from_civil(y, monn, d) * 86400 + hh*3600 + mi*60 + ss + off
  return epoch_to_iso(epoch)
}

function quoted(line, start,   q1, q2) {
  q1 = index(substr(line, start), "\"")
  if (q1 == 0) return ""
  q1 += start - 1
  q2 = index(substr(line, q1 + 1), "\"")
  if (q2 == 0) return ""
  QSTART = q1 + 1; QEND = q1 + q2
  return substr(line, q1 + 1, q2 - 1)
}

{
  line = $0
  # --- client ip (first token)
  ip = ""
  if (match(line, /^[0-9][0-9.]*/) || match(line, /^[0-9a-fA-F:]+/) || match(line, /^\[[0-9a-fA-F:]+\]/)) {
    ip = substr(line, 1, RLENGTH)
    gsub(/^\[/, "", ip); gsub(/\]$/, "", ip)
  }

  # --- timestamp inside [ ]
  ts = ""
  b1 = index(line, "["); b2 = index(line, "]")
  if (b1 > 0 && b2 > b1) ts = clf_ts_to_iso(substr(line, b1 + 1, b2 - b1 - 1))
  if (ts == "") ts = strftime("%Y-%m-%dT%H:%M:%SZ", systime())

  # --- request (first quoted string)
  rest_start = (b2 > 0 ? b2 + 1 : 1)
  req = quoted(line, rest_start)
  rq_start = QSTART; rq_end = QEND
  method = ""; uri = ""
  if (req != "") {
    split(req, RQ, " ")
    method = RQ[1]; uri = RQ[2]
    if (method == "-") method = ""
    if (uri == "-") uri = ""
  }

  # --- status + size immediately after request quote
  status = ""; size = ""
  after = substr(line, rq_end + 1)
  if (match(after, /^[ ]+[0-9][0-9][0-9][ ]/) || match(after, /^[ ]+[0-9][0-9][0-9][ ]+/)) {
    tmp = after; sub(/^[ ]+/, "", tmp)
    split(tmp, SB, " ")
    status = SB[1]; size = SB[2]
    if (size == "-") size = ""
    # strip request-time suffix "0.123" if present
    if (size ~ /^[0-9]+\.[0-9]+$/) size = ""
  } else {
    # upstream_status style or missing: try any 3-digit token after request
    tmp = after
    if (match(tmp, /[ ]([1-5][0-9][0-9])[ ]/)) status = substr(tmp, RSTART + 1, 3)
  }

  # --- referer + ua are the next two quoted strings
  referer = ""; ua = ""
  pos = rq_end + 1
  f1 = quoted(line, pos); p1s = QSTART; p1e = QEND
  if (f1 != "") { referer = f1; pos = p1e + 1 }
  f2 = quoted(line, pos)
  if (f2 != "") ua = f2
  if (referer == "-") referer = ""

  # --- X-Forwarded-For when the log format includes it (quoted or bare token)
  xff = ""
  n = split(line, TOK, "\"")
  for (i = 2; i <= n; i += 2) {
    if (TOK[i] ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(, ?[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)*$/) {
      if (TOK[i] != ip) { split(TOK[i], XI, ","); gsub(/^ +| +$/, "", XI[1]); xff = XI[1]; break }
    }
  }
  if (xff != "") ip = xff

  msg = line; gsub(/[\t\r\n]/, " ", msg); msg = substr(msg, 1, 2000)
  print ts, src, ip, method, uri, status, size, ua, "", "", "", "-", msg, referer
}
