# dockerlog.awk - docker json-file log -> stream TSV, một lượt awk, không fork.
#
# Vì sao có file này: bản bash cũ bung từng dòng bằng `sed` rồi lọc bằng
# `grep -qP`. Mỗi dòng tốn 2 fork ≈ 2.4 ms. Đo trên máy thật: 1.216.130 dòng
# (hai container 76 MB) mất 49 phút, trong khi PLUGIN_TIMEOUT là 120 s — plugin
# bị kill mỗi batch và không bao giờ chạy xong. awk làm cùng việc trong một
# process, nhanh hơn hai bậc.
#
# Input: file *-json.log của docker (mỗi dòng một object JSON) HOẶC output của
# `docker logs --timestamps` (đã tách ts ở caller, chỉ còn nội dung thô).
#
# Usage: awk -f dockerlog.awk \
#          -v realfile=/path [-v startline=N] [-v name=CONTAINER] \
#          [-v accessre=...] [-v markerre=...] file
#
# Emits 12 fields, đúng contract của lib/stream.sh:
#   ts source file line ip method uri status ua pid msg rule

BEGIN {
  OFS = "\t"
  split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", MN, " ")
  consumed = 0; prog_n = 0
}

# --- epoch <-> ISO, cùng thuật toán với lib/accesslog.awk -------------------
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

# "23/Oct/2026:20:03:05 +0000" -> ISO UTC. Docker log nginx hay dùng dạng này
# mà KHÔNG bọc trong [ ] và KHÔNG có referer/ua — khác combined format.
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

# docker json-file escape: \\ -> \ , \" -> " , \n \r \t -> space.
# Thứ tự quan trọng: \\ đi trước qua placeholder, nếu không cặp \\\\n
# (backslash thật + chữ n) sẽ bị hiểu thành newline.
function json_unescape(s,   t) {
  if (index(s, "\\") == 0) return s
  t = s
  gsub(/\\\\/, "\001", t)
  gsub(/\\"/, "\"", t)
  gsub(/\\n/, " ", t)
  gsub(/\\r/, "", t)
  gsub(/\\t/, " ", t)
  gsub(/\001/, "\\", t)
  return t
}

# Lấy giá trị "key":"..." từ object JSON trên một dòng, không cần parse toàn bộ.
function json_str(line, key,   pat, s, e) {
  pat = "\"" key "\":\""
  s = index(line, pat)
  if (s == 0) return ""
  s += length(pat)
  # tìm dấu " đóng, bỏ qua \" đã escape
  e = s
  while (e <= length(line)) {
    if (substr(line, e, 1) == "\\") { e += 2; continue }
    if (substr(line, e, 1) == "\"") break
    e++
  }
  return substr(line, s, e - s)
}

# Trích field từ dòng access-log. Chấp nhận CẢ hai dạng:
#   combined : IP - - [ts] "GET /x HTTP/1.1" 200 12 "-" "ua"
#   nginx ngắn: IP -  ts  "GET /x" 200        <- dạng container lab đang ghi
# Trả 1 nếu nhận ra, và set các biến toàn cục A_ip A_method A_uri A_status A_ua A_ts.
function parse_access(line,   s, ip, req, after, q1, q2, rest, m, st) {
  A_ip = ""; A_method = ""; A_uri = ""; A_status = ""; A_ua = ""; A_ts = ""

  # IP đứng đầu
  if (match(line, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) A_ip = substr(line, 1, RLENGTH)
  else if (match(line, /^[0-9a-fA-F:]+/) && index(substr(line, 1, RLENGTH), ":")) A_ip = substr(line, 1, RLENGTH)
  else return 0

  # chuỗi request trong cặp "..." đầu tiên
  q1 = index(line, "\"")
  if (q1 == 0) return 0
  q2 = index(substr(line, q1 + 1), "\"")
  if (q2 == 0) return 0
  req = substr(line, q1 + 1, q2 - 1)
  q2 += q1                       # vị trí dấu " đóng

  split(req, m, " ")
  A_method = m[1]; A_uri = m[2]
  if (A_method == "-") A_method = ""
  if (A_uri == "-") A_uri = ""
  # bỏ " HTTP/1.1" nếu có (split đã tách, nhưng URI có thể dính khi thiếu space)
  sub(/ HTTP\/[0-9.]+$/, "", A_uri)
  if (A_method == "" || A_uri == "") return 0

  # status: số 3 chữ số đầu tiên sau dấu " đóng
  after = substr(line, q2 + 1)
  if (match(after, /[ ]([1-5][0-9][0-9])([ ]|$)/)) A_status = substr(after, RSTART + 1, 3)
  else return 0

  # timestamp: [dd/Mon/yyyy:hh:mm:ss +zzzz] hoặc không ngoặc
  if (match(line, /[0-9][0-9]\/[A-Za-z][A-Za-z][A-Za-z]\/[0-9][0-9][0-9][0-9]:[0-9][0-9]:[0-9][0-9]:[0-9][0-9] [+-][0-9][0-9][0-9][0-9]/))
    A_ts = clf_ts_to_iso(substr(line, RSTART, RLENGTH))

  # ua: chuỗi trong ngoặc kép CUỐI CÙNG, chỉ khi có >= 2 cặp quote sau request
  rest = substr(line, q2 + 1)
  if (match(rest, /"[^"]*"[ ]*$/)) {
    st = RSTART; A_ua = substr(rest, st + 1, RLENGTH - 2)
    sub(/[ ]*$/, "", A_ua)
    if (A_ua == "-") A_ua = ""
  }
  return 1
}

{
  raw = $0
  if (raw == "") next

  # --- tiến độ: ghi mốc byte đã đọc để trap EXIT còn cứu được khi bị kill.
  # Không có bước này, plugin bị PLUGIN_TIMEOUT cắt giữa chừng sẽ mất toàn bộ
  # tiến độ và batch sau đọc lại từ byte 0. Ghi mỗi progress_every dòng, kèm
  # basepos (byte offset của chunk trong file gốc) do caller truyền vào.
  if (progressfile != "") {
    consumed += length(raw) + 1        # LC_ALL=C ở caller => length() đếm byte
    if (++prog_n % (progress_every + 0) == 0) {
      printf "%d\t%d\n", basepos + consumed, startline + FNR > progressfile
      fflush(progressfile)
    }
  }

  msg = ""; ts = ""

  # --- dạng 0: nhánh CLI đã ghép sẵn "<rfc3339> <nội dung>" ở caller
  if (cli_ts == 1) {
    ts = substr(raw, 1, index(raw, " ") - 1)
    if (ts !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z$/) { ts = ""; msg = raw }
    else msg = substr(raw, index(raw, " ") + 1)
  }

  # --- dạng 1: object JSON của docker (file *-json.log)
  if (msg == "" && substr(raw, 1, 1) == "{") {
    msg = json_str(raw, "log")
    if (msg != "") {
      ts = json_str(raw, "time")
      msg = json_unescape(msg)
    }
  }
  # --- dạng 2: nội dung thô (dòng không phải JSON)
  if (msg == "") msg = raw

  # caller có thể áp ts riêng
  if (forced_ts != "") ts = forced_ts

  # bỏ newline cuối còn sót
  sub(/[\r\n]+$/, "", msg)

  fname = (realfile != "" ? realfile : FILENAME)
  lno = (startline != "" ? startline + FNR : FNR)
  label = (name != "" ? name : "docker")

  # --- access-log: phát dưới nguồn access_log để rule tấn công áp dụng được
  if (accessre != "" && parse_access(msg)) {
    ets = (ts != "" ? ts : (A_ts != "" ? A_ts : strftime("%Y-%m-%dT%H:%M:%SZ", systime())))
    line2 = msg; gsub(/[\t\r\n]/, " ", line2)
    print ets, "access_log", fname, lno, A_ip, A_method, A_uri, A_status, A_ua, "-", line2, "-"
    next
  }

  # --- dòng thường: chỉ giữ khi khớp marker crash/OOM hoặc marker tấn công
  if (markerre == "" || msg !~ markerre) next

  ets = (ts != "" ? ts : strftime("%Y-%m-%dT%H:%M:%SZ", systime()))
  body = "[" label "] " msg
  gsub(/[\t\r\n]/, " ", body)
  print ets, "docker", fname, lno, "", "", "", "", "", "", body, "-"
}
