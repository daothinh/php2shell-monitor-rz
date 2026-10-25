# jsonl.awk - đọc rule pack JSONL thành TSV chuẩn hoá, KHÔNG cần jq.
#
# Vì sao có file này: rule pack là JSONL. Bản cũ đọc nó bằng jq, nên host không
# có jq thì mọi rule bị bỏ qua và monitor báo "no-hits" — im lặng mà không phát
# hiện gì. Cài jq là cách tốt khi làm được, nhưng không phải host nào cũng cài
# được (offline, image bất biến, không có package manager). Bộ đọc này là lưới
# an toàn: cùng một định dạng ra, cùng kết quả, chỉ dùng awk có sẵn ở mọi distro.
#
# Output 1 (rules): id US sev US impact US enabled US needs US source US type US
#                   field US pcre US min
# Output 2 (ands):  id US field US pcre US neg
#
# US = 0x1f (unit separator). Không dùng TAB vì TAB là IFS-whitespace: `read`
# của bash sẽ nuốt field rỗng, mà impact/needs/source thường rỗng.
#
# Bộ đọc JSON ở đây chỉ cần đúng schema rule (object, array chuỗi, array object,
# string/number/bool). Chuỗi giữ nguyên backslash để PCRE không bị biến dạng.

BEGIN {
  US = "\037"
  for (i = 1; i < ARGC; i++) {
    if (ARGV[i] ~ /^rules=/) { RULES = substr(ARGV[i], 7); ARGV[i] = ""; continue }
    if (ARGV[i] ~ /^ands=/)  { ANDS  = substr(ARGV[i], 6); ARGV[i] = ""; continue }
  }
}

{
  S = $0
  sub(/^[ \t\r]+/, "", S)
  sub(/[ \t\r]+$/, "", S)
  if (S == "" || substr(S, 1, 1) == "#") next

  split("", V)
  LEN = length(S)
  POS = 1
  jv("")

  id = V["id"]
  if (id == "") next

  sev = V["severity"];      if (sev == "")     sev = "MEDIUM"
  impact = V["impact"]
  enabled = V["enabled"];   if (enabled == "") enabled = "true"
  mtype = V["match.type"];  if (mtype == "")   mtype = "regex"
  field = V["match.field"]; if (field == "")   field = "msg"
  pcre = V["match.pcre"]
  min = V["match.min"];     if (min == "")     min = "1"

  needs = ""
  for (i = 0; ("needs." i) in V; i++)
    needs = (needs == "") ? V["needs." i] : needs "," V["needs." i]

  src = ""
  for (i = 0; ("source." i) in V; i++)
    src = (src == "") ? V["source." i] : src "," V["source." i]

  printf "%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n",
    id, sev, impact, enabled, needs, src, mtype, field, pcre, min > RULES

  nand = 0
  while (("match.and." nand ".field") in V) {
    afield = V["match.and." nand ".field"]
    apcre  = V["match.and." nand ".pcre"]
    aneg   = V["match.and." nand ".neg"]
    if (aneg == "true") aneg = 1; else if (aneg == "") aneg = 0; else aneg = 0
    printf "%s\037%s\037%s\037%s\n", id, afield, apcre, aneg > ANDS
    nand++
  }
}

# ---------------------------------------------------------------- JSON reader
# V[path] = scalar. Đường dẫn dạng "match.and.0.field".
function jv(path,   c) {
  skipws()
  c = substr(S, POS, 1)
  if (c == "{") { jobj(path); return }
  if (c == "[") { jarr(path); return }
  if (c == "\"") { V[path] = jstr(); return }
  jscalar(path)
}

function jobj(path,   c, k, np) {
  POS++                                  # qua {
  skipws()
  if (substr(S, POS, 1) == "}") { POS++; return }
  while (POS <= LEN) {
    skipws()
    if (substr(S, POS, 1) != "\"") { POS++; continue }
    k = jstr()
    skipws()
    if (substr(S, POS, 1) == ":") POS++
    np = (path == "") ? k : path "." k
    jv(np)
    skipws()
    c = substr(S, POS, 1)
    if (c == ",") { POS++; continue }
    if (c == "}") { POS++; return }
    if (c == "") return
    POS++
  }
}

function jarr(path,   c, i, np) {
  POS++                                  # qua [
  skipws()
  if (substr(S, POS, 1) == "]") { POS++; return }
  i = 0
  while (POS <= LEN) {
    np = (path == "") ? (i "") : path "." i
    jv(np)
    i++
    skipws()
    c = substr(S, POS, 1)
    if (c == ",") { POS++; continue }
    if (c == "]") { POS++; return }
    if (c == "") return
    POS++
  }
}

function jstr(   out, c, hex) {
  POS++                                  # qua "
  out = ""
  while (POS <= LEN) {
    c = substr(S, POS, 1)
    if (c == "\\") {
      POS++
      c = substr(S, POS, 1)
      if (c == "n") out = out "\n"
      else if (c == "t") out = out "\t"
      else if (c == "r") out = out "\r"
      else if (c == "b") out = out "\b"
      else if (c == "f") out = out "\f"
      else if (c == "u") {
        # \uXXXX: chỉ giải mã ASCII, còn lại bỏ qua an toàn
        hex = substr(S, POS + 1, 4)
        POS += 4
        if (hex ~ /^00[0-7][0-9a-fA-F]$/) {
          n = 0
          for (j = 1; j <= 4; j++) {
            d = index("0123456789abcdef", tolower(substr(hex, j, 1))) - 1
            if (d < 0) d = 0
            n = n * 16 + d
          }
          if (n > 0) out = out sprintf("%c", n)
        }
      }
      else out = out c             # \" -> ", \\ -> \, \/ -> / : PCRE không đổi
      POS++
      continue
    }
    if (c == "\"") { POS++; return out }
    out = out c
    POS++
  }
  return out
}

function jscalar(path,   start, c, v) {
  start = POS
  while (POS <= LEN) {
    c = substr(S, POS, 1)
    if (c == "," || c == "}" || c == "]" || c == " " || c == "\t" || c == "\r" || c == "\n") break
    POS++
  }
  v = substr(S, start, POS - start)
  V[path] = v
}

function skipws(   c) {
  while (POS <= LEN) {
    c = substr(S, POS, 1)
    if (c == " " || c == "\t" || c == "\r" || c == "\n") POS++
    else return
  }
}
