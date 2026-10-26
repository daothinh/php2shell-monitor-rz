#!/usr/bin/env bash
# run_tests.sh - dependency-light test runner (bats used by build.sh when present).
#
# Covers the two behaviours the monitor promises:
#   1. matching is done per FIELD, so anchored patterns work
#   2. one batch produces at most one alert, carrying every raw hit with file:line
set -u
SRC=${SRC:-/opt/php2shell-monitor}
FIX="$(cd "$(dirname "${BASH_SOURCE[0]}")/fixtures" && pwd)"
PASS=0; FAIL=0

pass() { echo "pass: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
T() { if [[ $3 == *"$2"* ]]; then pass "$1"; else fail "$1 (missing: $2)"; fi; }
N() { if [[ $3 != *"$2"* ]]; then pass "$1"; else fail "$1 (unexpected: $2)"; fi; }

# Fresh isolated workdir with one project/device.
newlab() {
  local w
  w=$(mktemp -d)
  mkdir -p "$w"/{rules/pack,conf/rules.d,conf,lib,engine,plugins,tmp,run,projects}
  cp -a "$SRC/lib/." "$w/lib/"
  cp -a "$SRC/engine/." "$w/engine/"
  cp -a "$SRC/plugins/." "$w/plugins/"
  cp -a "$SRC/rules/pack/." "$w/rules/pack/"
  printf 'PROJECT="test-project"\nDEVICE="test-device"\n' >"$w/conf/device.conf"
  printf 'BATCH_INTERVAL=300\nMAX_EVIDENCE_INLINE=0\nEVIDENCE_KEEP=50\nPLUGINS_DISABLED=""\n' \
    >"$w/conf/default.conf"
  : >"$w/conf/whitelist.conf"
  printf '%s' "$w"
}

# rule_match <lab> <stream>
rule_match() {
  WORKDIR=$1 P2S_SRC_DIR=$1 bash "$1/engine/rule_match.sh" "$2" 2>/dev/null
}

# report <lab> <hits> <batch>
report() {
  WORKDIR=$1 P2S_SRC_DIR=$1 bash "$1/engine/report.sh" "$2" "$3" 0 "$(date -u +%s)" 2>/dev/null
}

# ---------------------------------------------------------------- accesslog.awk
out=$(awk -f "$SRC/lib/accesslog.awk" -v src=access_log "$FIX/mal_access_upload_progress.log")
T "parser: ip"            "198.51.100.7" "$(printf '%s' "$out" | cut -f5)"
T "parser: method"        "POST"         "$(printf '%s' "$out" | cut -f6)"
T "parser: uri marker"    "PHP_SESSION_UPLOAD_PROGRESS" "$(printf '%s' "$out" | cut -f7)"
T "parser: file recorded" "mal_access_upload_progress.log" "$(printf '%s' "$out" | cut -f3)"
T "parser: line recorded" "1"            "$(printf '%s' "$out" | cut -f4)"
T "parser: raw line kept" 'POST /upload.php' "$(printf '%s' "$out" | cut -f11)"

out=$(awk -f "$SRC/lib/accesslog.awk" -v src=access_log "$FIX/mal_access_php2shell_ua.log")
T "parser: ua" "php2shell-109619" "$(printf '%s' "$out" | cut -f9)"

out=$(awk -f "$SRC/lib/accesslog.awk" -v src=access_log "$FIX/benign_access.log")
N "parser: benign UA has no php2shell" "php2shell" "$(printf '%s' "$out" | cut -f9)"

# ---------------------------------------------------------------- rule matching
w=$(newlab)

stream="$w/stream1.tsv"
awk -f "$SRC/lib/accesslog.awk" -v src=access_log "$FIX/mal_access_php2shell_ua.log" >"$stream"
T "rules: P2S-008 UA hit" "P2S-008" "$(rule_match "$w" "$stream" | cut -f12)"

stream="$w/stream2.tsv"
awk -f "$SRC/lib/accesslog.awk" -v src=access_log "$FIX/mal_access_upload_progress.log" >"$stream"
T "rules: P2S-017 marker hit" "P2S-017" "$(rule_match "$w" "$stream" | cut -f12)"

# anchored field: ^500$ must match only the status field, never the raw line.
# P2S-016 has min=5, so five 500s are required for it to fire at all.
stream="$w/stream3.tsv"
for i in 1 2 3 4 5; do
  printf '%s\n' \
    "2026-10-24T00:00:0${i}Z"$'\taccess_log\t/tmp/a.log\t'"$i"$'\t1.2.3.4\tPOST\t/up.php\t500\tcurl\t\t"POST /up.php" 500\t-' \
    >>"$stream"
done
T "rules: anchored status ^500$ matches" "P2S-016" "$(rule_match "$w" "$stream" | cut -f12)"

# a line that merely contains "500" elsewhere must not fire the anchored rule
stream="$w/stream4.tsv"
printf '%s\n' \
  $'2026-10-24T00:00:01Z\taccess_log\t/tmp/a.log\t1\t1.2.3.4\tGET\t/500.html\t200\tcurl\t\t"GET /500.html" 200\t-' \
  >>"$stream"
N "rules: 500 in URI does not fire ^500$" "P2S-016" "$(rule_match "$w" "$stream" | cut -f12)"

# min threshold: 4 OOM lines stay silent, the 5th fires
stream="$w/stream5.tsv"
for i in 1 2 3 4; do
  printf '2026-10-24T00:00:0%dZ\tfpm_error\t/tmp/f.log\t%d\t\t\t\t\t\t42\tAllowed memory size of 1 bytes exhausted\t-\n' \
    "$i" "$i" >>"$stream"
done
N "rules: P2S-010 silent under min=5" "P2S-010" "$(rule_match "$w" "$stream" | cut -f12)"
printf '2026-10-24T00:00:05Z\tfpm_error\t/tmp/f.log\t5\t\t\t\t\t\t42\tAllowed memory size of 1 bytes exhausted\t-\n' \
  >>"$stream"
T "rules: P2S-010 fires at min=5" "P2S-010" "$(rule_match "$w" "$stream" | cut -f12)"

# source gating: an FPM-style line coming from access_log must not match P2S-010
stream="$w/stream6.tsv"
for i in 1 2 3 4 5; do
  printf '2026-10-24T00:00:0%dZ\taccess_log\t/tmp/a.log\t%d\t\t\t\t\t\t\tAllowed memory size exhausted\t-\n' \
    "$i" "$i" >>"$stream"
done
N "rules: source gating blocks cross-source hits" "P2S-010" "$(rule_match "$w" "$stream" | cut -f12)"

# and: ^500$ + uri \.php — a 500 on a non-PHP path must not fire P2S-016
stream="$w/stream7.tsv"
for i in 1 2 3 4 5; do
  printf '%s\n' \
    "2026-10-24T00:00:0${i}Z"$'\taccess_log\t/tmp/a.log\t'"$i"$'\t1.2.3.4\tPOST\t/plain.txt\t500\tcurl\t\t"POST /plain.txt" 500\t-' \
    >>"$stream"
done
N "rules: and-condition requires .php uri" "P2S-016" "$(rule_match "$w" "$stream" | cut -f12)"

stream="$w/stream8.tsv"
printf '2026-10-24T00:00:00Z\taccess_log\t/tmp/a.log\t1\t1.2.3.4\tGET\t/\t200\tMozilla\t\t"GET /" 200\t-\n' \
  >>"$stream"
N "rules: benign line silent" "P2S-" "$(rule_match "$w" "$stream")"

# ---------------------------------------------------------------- one alert
hits="$w/hits1.tsv"
# 14 columns: ts source file line ip method uri status ua pid msg rule severity impact
# impact=rce is the ONLY thing that may raise a batch to CRITICAL: it means the
# rule's own evidence proves a shell landed or a command already ran.
printf '%s\n' \
  $'2026-10-24T00:00:01Z\tfpm_error\t/var/log/fpm.log\t11\t\t\t\t\t\t42\tAllowed memory size exhausted\tP2S-010\tHIGH\t' \
  $'2026-10-24T00:00:02Z\taccess_log\t/var/log/access.log\t7\t1.2.3.4\tGET\t/sh.php\t200\tcurl\t\tGET /sh.php?cmd=id\tP2S-030\tHIGH\t' \
  $'2026-10-24T00:00:03Z\twebroot\t/var/www/shell.php\t0\t\t\t\t\t\t\twebroot file NEW\tP2S-020\tCRITICAL\trce' \
  >"$hits"
report "$w" "$hits" "20261024T000000Z"
alert="$w/projects/test-project/devices/test-device/alerts/queue.jsonl"
T "alert: exactly one line per batch" "1" "$(wc -l <"$alert" | tr -d ' ')"
T "alert: RCE evidence -> CRITICAL" "CRITICAL" "$(jq -r '.severity' "$alert")"
T "alert: rce counter carried"      "1"        "$(jq -r '.rce' "$alert")"
T "alert: host is device label"     "test-device" "$(jq -r '.host' "$alert")"
T "alert: hostname is machine name" "" "$(jq -r '.hostname' "$alert")"
T "alert: hit count preserved"         "3"        "$(jq -r '.hits' "$alert")"
T "alert: all rules counted"           "P2S-020"  "$(jq -r '[.rules[].rule_id]|join(",")' "$alert")"
# Evidence không nằm trong alert nữa: kiểm tra file JSONL trên đĩa, đó mới là
# bản đầy đủ được upload nguyên văn.
EVF=$w/projects/test-project/devices/test-device/evidence/20261024T000000Z.jsonl
T "evidence file: keeps file path"     "/var/www/shell.php" "$(jq -r '.file' "$EVF" | tail -1)"
T "evidence file: keeps line number"   "11"       "$(jq -r '.line' "$EVF" | head -1)"
T "evidence file: keeps raw line"      "cmd=id"   "$(jq -r '.raw' "$EVF" | sed -n 2p)"
T "alert: project carried"             "test-project" "$(jq -r '.project' "$alert")"
T "alert: device carried"              "test-device"  "$(jq -r '.device' "$alert")"
T "alert: evidence file written"       "20261024T000000Z.jsonl" "$(jq -r '.evidence_file' "$alert")"
T "evidence: one record per hit"       "3" "$(wc -l <"$w/projects/test-project/devices/test-device/evidence/20261024T000000Z.jsonl" | tr -d ' ')"

# containers[]: hit từ docker:/container: nói rõ container nào gây alert —
# operator phân biệt alert host và alert container ngay trên tin nhắn.
hits2="$w/hits2.tsv"
printf '%s\n' \
  $'2026-10-24T00:00:01Z\taccess_log\tdocker:php-web\t7\t1.2.3.4\tGET\t/up.php?PHP_SESSION_UPLOAD_PROGRESS=x\t200\tphp2shell-109618\t\tGET /up.php\tP2S-008\tHIGH\t' \
  $'2026-10-24T00:00:02Z\taccess_log\tdocker:php-web\t8\t1.2.3.4\tGET\t/s.php?p=../../../etc/passwd\t200\tcurl\t\tGET /s.php\tP2S-052\tHIGH\t' \
  $'2026-10-24T00:00:03Z\taccess_log\tcontainer:db-1:/var/log/nginx/access.log\t2\t1.2.3.4\tGET\t/x\t200\tcurl\t\tGET /x\tP2S-030\tHIGH\t' \
  >"$hits2"
report "$w" "$hits2" "20261024T010000Z"
alert2=$(tail -1 "$alert")
T "containers: gom docker: + container: (dedup)" "php-web,db-1" \
  "$(jq -r '[.containers[]]|join(",")' <<<"$alert2")"
# batch trước không có container nào -> mảng rỗng
T "containers: alert host thi rong" "[]" "$(head -1 "$alert" | jq -c '.containers')"

# ------------------------------------------- severity tiers (impact-driven)
# CRITICAL chỉ khi có bằng chứng RCE; nếu không thì chia theo số event.
_tier() { # <số event> <có rce?>
  local n=$1 rce=$2 f="$w/tier.tsv"
  awk -v n="$n" -v rce="$rce" 'BEGIN{
    for(i=1;i<=n;i++)
      printf "2026-10-24T00:00:01Z\taccess_log\t/a\t%d\t1.2.3.4\tGET\t/x\t200\tua\t\traw\tP2S-050\tCRITICAL\t%s\n", i, (i==1?rce:"")
  }' >"$f"
  rm -f "$w/projects/test-project/devices/test-device/alerts/queue.jsonl"
  report "$w" "$f" "20261024T0010$RANDOM"
  jq -r '.severity' "$w/projects/test-project/devices/test-device/alerts/queue.jsonl"
}
T "severity: RCE -> CRITICAL"          "CRITICAL" "$(_tier 10 rce)"
T "severity: 6000 event -> MODERATE"   "MODERATE" "$(_tier 6000 '')"
T "severity: 5000 event -> MODERATE"   "MODERATE" "$(_tier 5000 '')"
T "severity: 4999 event -> INFO"       "INFO"     "$(_tier 4999 '')"
T "severity: 1 event -> INFO"          "INFO"     "$(_tier 1 '')"
T "severity: nhiễu không thành CRITICAL" "INFO"   "$(_tier 300 '')"

# empty batch -> no alert, but a batch record
report "$w" /dev/null "20261024T000500Z"
T "alert: empty batch adds no alert" "1" "$(wc -l <"$alert" | tr -d ' ')"
T "batch log: empty batch recorded" "no-hits" "$(tail -1 "$w/projects/test-project/devices/test-device/run/batches.log")"

# second batch with hits -> second alert line, never merged
report "$w" "$hits" "20261024T001000Z"
T "alert: second batch appends" "2" "$(wc -l <"$alert" | tr -d ' ')"

# Mặc định KHÔNG nhét evidence vào alert: 300k event = dòng JSON 148MB, agent
# không gửi nổi. Evidence đi kênh riêng, alert chỉ mang metadata.
report "$w" "$hits" "20261024T001200Z"
T "alert: mặc định không inline evidence" "0" \
  "$(jq -r '.evidence | length' "$alert" | tail -1)"
T "alert: có evidence_count" "3" "$(jq -r '.evidence_count' "$alert" | tail -1)"
T "alert: không bị coi là truncated" "false" "$(jq -r '.evidence_truncated' "$alert" | tail -1)"
T "alert: evidence_file trỏ file đầy đủ" "20261024T001200Z.jsonl" \
  "$(jq -r '.evidence_file | split("/") | last' "$alert" | tail -1)"
T "alert: full evidence on disk" "3" \
  "$(wc -l <"$w/projects/test-project/devices/test-device/evidence/20261024T001200Z.jsonl" | tr -d ' ')"

# MAX_EVIDENCE_INLINE>0 = preview thủ công, không phải đường truyền chính
sed -i 's/^MAX_EVIDENCE_INLINE=.*/MAX_EVIDENCE_INLINE=2/' "$w/conf/default.conf"
report "$w" "$hits" "20261024T001500Z"
T "alert: preview giới hạn khi bật tay" "2" \
  "$(jq -r '.evidence | length' "$alert" | tail -1)"
T "alert: preview báo truncated" "true" "$(jq -r '.evidence_truncated' "$alert" | tail -1)"
T "alert: full evidence still on disk" "3" \
  "$(wc -l <"$w/projects/test-project/devices/test-device/evidence/20261024T001500Z.jsonl" | tr -d ' ')"

# ---------------------------------------------------------------- pair (chat-id)
# Fake central server: một stub `curl` đếm lượt poll và trả lời theo kịch bản,
# giữ test không phụ thuộc server thật hay mạng.
w2=$(newlab)

# ------------------------------------------------- endpoint obfuscation
# Địa chỉ server không được xuất hiện dạng plaintext trong mã nguồn: grep một
# cổng hay một dải IP không được tìm ra nó.
ep_out=$(bash -c 'source "$1/lib/endpoint.sh"; p2s_endpoint' _ "$SRC")
T "endpoint: giải mã ra URL http"      "http" "$ep_out"
bash -c 'source "$1/lib/endpoint.sh"; p2s_endpoint_valid' _ "$SRC" \
  && pass "endpoint: hợp lệ" || fail "endpoint: hợp lệ"

# roundtrip: encode rồi decode phải quay lại đúng chuỗi ban đầu
for u in "http://a.example:8000" "http://10.1.2.3:9999"; do
  rt=$(bash -c 'source "$1/lib/endpoint.sh"
    b=$(p2s_endpoint_encode "$2"); P2S_ENDPOINT_B64=$b p2s_endpoint' _ "$SRC" "$u")
  T "endpoint: roundtrip $u" "$u" "$rt"
done

# không có IP:port nào viết thẳng trong mã nguồn
plain=$(grep -rEn 'https?://[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]+' "$SRC/lib" "$SRC/engine" \
          "$SRC/main.sh" 2>/dev/null | grep -v '^.*#' || true)
T "endpoint: không lộ IP:port trong mã" "" "$plain"

# ------------------------------------------------- main.sh: không wizard
# Chạy trần KHÔNG được hỏi gì: phải báo thiếu tham số rồi thoát ngay.
out=$(WORKDIR="$w2" P2S_DATA_DIR='' bash "$SRC/main.sh" </dev/null 2>&1)
T "main: chạy trần báo thiếu tham số" "thiếu tham số bắt buộc" "$out"
T "main: chạy trần nêu tham số cần"   "--project --chatid" "$out"
N "main: chạy trần không prompt"       "Nhập" "$out"

out=$(WORKDIR="$w2" P2S_DATA_DIR='' bash "$SRC/main.sh" </dev/null 2>&1)
T "main: thiếu project+chatid báo rõ" "--project --chatid" "$out"

# --server không còn là tham số của người dùng: truyền vào thì bỏ qua,
# không truyền thì vẫn chạy (endpoint nằm trong mã nguồn).
out=$(WORKDIR="$w2" P2S_DATA_DIR='' bash "$SRC/main.sh" --server http://x.test </dev/null 2>&1)
N "main: --server không còn bắt buộc" "thiếu tham số bắt buộc: --server" "$out"
T "main: vẫn đòi project/chatid"      "--project --chatid" "$out"

# ------------------------------------------------- chốt chặn chạy lại
# Thiết bị đã pair đầy đủ -> chạy lại lệnh triển khai phải báo "đã thiết lập"
# và KHÔNG được đụng vào conf (không đổi dự án, không đổi chat, không cấp key mới).
w3=$(newlab)
stub3=$w3/curlstub
mkdir -p "$stub3"
cat >"$stub3/curl" <<'STUB'
#!/usr/bin/env bash
self=$(dirname "$0")
args=("$@")
url='' body=''
for ((i = 0; i < $#; i++)); do
  case ${args[$i]} in
    -d|--data) body=${args[$((i + 1))]} ;;
    http*) url=${args[$i]} ;;
  esac
done
case $url in
  *register-chatid)
    printf '%s' "$body" >"$self/register_body"
    n=$(cat "$self/reg_count" 2>/dev/null || echo 0); n=$((n + 1))
    printf '%s' "$n" >"$self/reg_count"
    printf '{"pair_ref":"SEC-R%s","bot":"@test_bot","warning":null}' "$n"
    ;;
  *pairing-status*)
    printf '{"status":"linked","api_key":"p2sk-key-%s"}' "$(cat "$self/reg_count")"
    ;;
  *) printf '{}' ;;
esac
STUB
chmod +x "$stub3/curl"
SETUP_ENV=(PATH="$stub3:$PATH" WORKDIR="$w3" P2S_PAIR_POLL=1 P2S_PAIR_TIMEOUT=10)

# lần đầu: phải chạy thật
out=$(env "${SETUP_ENV[@]}" bash "$SRC/main.sh" \
      --server http://fake-central.test --project proj-A --chatid 812345678 2>&1)
T "setup: lần đầu ghép nối"        "GHÉP NỐI THÀNH CÔNG" "$out"
T "setup: lần đầu ghi project"     'PROJECT="proj-A"' "$(cat "$w3/conf/device.conf")"

# banner VCCSEC ở đầu, và output KHÔNG được lộ server/chat
first=$(printf '%s\n' "$out" | head -1)
T "setup: banner ở dòng đầu"       "__     __"           "$first"
T "setup: banner đủ 5 dòng"        " \____||____/ |_____| \____|" "$out"
N "setup: không in dòng Server"    "Server     :"        "$out"
N "setup: không in dòng Chat nhận" "Chat nhận  :"        "$out"
T "setup: nêu thiết bị + IP"       "Đang đăng ký thiết bị" "$out"
T "setup: nêu dự án khi đăng ký"   'cho dự án "proj-A"'   "$out"
T "setup: gợi ý kiểm tra"          "Kiểm tra trạng thái:" "$out"

key1=$(sed -n 's/^API_KEY=//p' "$w3/conf/central.conf")
: >"$stub3/reg_count"; : >"$stub3/register_body"

# lần hai, y hệt -> chặn
out=$(env "${SETUP_ENV[@]}" bash "$SRC/main.sh" \
      --server http://fake-central.test --project proj-A --chatid 812345678 2>&1)
T "setup: chạy lại báo đã thiết lập" "ĐÃ ĐƯỢC THIẾT LẬP MONITOR" "$out"
N "setup: chạy lại KHÔNG gọi register" "SEC-R" "$(cat "$stub3/register_body")"
T "setup: chạy lại giữ nguyên key"  "$key1" "$(sed -n 's/^API_KEY=//p' "$w3/conf/central.conf")"

# lần ba, cố đổi dự án + chat -> vẫn chặn, conf không đổi
out=$(env "${SETUP_ENV[@]}" bash "$SRC/main.sh" \
      --server http://fake-central.test --project proj-B --chatid 999888777 2>&1)
T "setup: đổi dự án vẫn bị chặn"    "ĐÃ ĐƯỢC THIẾT LẬP MONITOR" "$out"
T "setup: conf project không đổi"   'PROJECT="proj-A"' "$(cat "$w3/conf/device.conf")"
T "setup: conf chat không đổi"      "CHAT_ID=812345678" "$(cat "$w3/conf/central.conf")"
N "setup: không cấp key mới"        "p2sk-key-2" "$(cat "$w3/conf/central.conf")"

# --force -> được phép đổi
out=$(env "${SETUP_ENV[@]}" bash "$SRC/main.sh" --force \
      --server http://fake-central.test --project proj-B --chatid 999888777 2>&1)
T "setup: --force cho đổi cấu hình" "GHÉP NỐI THÀNH CÔNG" "$out"
T "setup: --force ghi project mới"  'PROJECT="proj-B"' "$(cat "$w3/conf/device.conf")"
T "setup: --force ghi chat mới"     "CHAT_ID=999888777" "$(cat "$w3/conf/central.conf")"

# pair dở (có project thật nhưng mất API key) -> KHÔNG chặn
w4=$(newlab)
printf 'PROJECT="proj-C"\nDEVICE="test-device"\n' >"$w4/conf/device.conf"
printf 'SERVER_URL=http://fake-central.test\nAPI_KEY=\nPROJECT_NAME=proj-C\nCHAT_ID=812345678\n' \
  >"$w4/conf/central.conf"
out=$(env PATH="$stub3:$PATH" WORKDIR="$w4" P2S_PAIR_POLL=1 P2S_PAIR_TIMEOUT=10 \
      bash "$SRC/main.sh" --server http://fake-central.test --project proj-C --chatid 812345678 2>&1)
T "setup: pair dở vẫn chạy tiếp"    "GHÉP NỐI THÀNH CÔNG" "$out"

rm -rf -- "$w3" "$w4"

# ------------------------------------------- supervisor: lịch & timeout
# Vòng lặp cũ dùng `sleep $interval` SAU mỗi scan, nên thời gian scan cộng dồn
# vào chu kỳ: đo thật được 319s / 308s / 307s thay vì 300s.
w5=$(newlab)
printf 'PROJECT="p"\nDEVICE="d"\n' >"$w5/conf/device.conf"
printf 'BATCH_INTERVAL=300\n' >>"$w5/conf/default.conf"
mkdir -p "$w5/projects/p/devices/d/run"

# bám lưới: now bất kỳ -> tick kế tiếp luôn là bội số của interval
grid=$(bash -c '
interval=300
for now in 1792943583 1792943585 1792943800; do
  next=$(( (now / interval + 1) * interval ))
  printf "%s " $(( next - now ))
done')
T "supervisor: bám lưới 300s" "117 115 200 " "$grid"

# scan treo phải bị timeout kill, không treo vòng lặp
t0=$(date +%s)
timeout -k 2 2 bash -c 'sleep 60' >/dev/null 2>&1; rc=$?
t1=$(date +%s)
T "supervisor: timeout kill scan treo" "124" "$rc"
N "supervisor: không chờ hết 60s"      "60" "$((t1 - t0))"

# scan.lock cũ bị coi là treo và xoá; lock mới thì giữ
touch -d '2 hours ago' "$w5/projects/p/devices/d/run/scan.lock"
st=$(find "$w5/projects/p/devices/d/run/scan.lock" -newermt "-330 seconds" 2>/dev/null)
T "supervisor: nhận ra lock cũ" "" "$st"
touch "$w5/projects/p/devices/d/run/scan.lock"
st=$(find "$w5/projects/p/devices/d/run/scan.lock" -newermt "-330 seconds" 2>/dev/null)
T "supervisor: giữ lock mới" "$w5/projects/p/devices/d/run/scan.lock" "$st"

# rotate: file quá lớn phải được đổi tên, không cắt cụt khi đang ghi
printf 'x%.0s' $(seq 1 5000) >"$w5/projects/p/devices/d/run/scan.log"
sz=$(stat -c %s "$w5/projects/p/devices/d/run/scan.log")
(( sz > 1024 )) && mv -f "$w5/projects/p/devices/d/run/scan.log" "$w5/projects/p/devices/d/run/scan.log.1"
T "supervisor: rotate scan.log" "5000" "$(stat -c %s "$w5/projects/p/devices/d/run/scan.log.1" 2>/dev/null || echo 0)"

rm -rf -- "$w5"

# Agent chết giữa 2 tick phải được phát hiện sớm, không đợi hết interval.
# Trước đây _ensure_agent chỉ chạy sau mỗi scan nên alert kẹt tới 5 phút.
T "supervisor: có watchdog agent" "AGENT_CHECK" "$(cat "$SRC/engine/supervisor.sh")"
T "supervisor: respawn trong vòng lặp chờ" "_ensure_agent" \
  "$(sed -n '/remaining > 0/,/done/p' "$SRC/engine/supervisor.sh")"
T "supervisor: mặc định 20s" "AGENT_CHECK:-20" "$(cat "$SRC/engine/supervisor.sh")"

# chia nhỏ thời gian chờ: không ngủ liền 300s
nap=$(bash -c 'remaining=300; check=20; n=0; while (( remaining > 0 )); do
  nap=$(( remaining < check ? remaining : check )); remaining=$(( remaining - nap )); n=$((n+1)); done; echo $n')
T "supervisor: ngủ chia nhỏ 15 lần" "15" "$nap"

stub=$w2/curlstub
mkdir -p "$stub"
cat >"$stub/curl" <<'STUB'
#!/usr/bin/env bash
# fake Central Alert Server — mô phỏng các endpoint central.sh gọi, đủ cả
# ngữ nghĩa HTTP thật: -o ghi body ra file, -w in http_code. File $self/unlinked
# tồn tại = dự án đã bị /unlink trên bot -> whoami/ingest-log trả 401
# project_disabled như server thật.
self=$(dirname "$0")
args=("$@")
url='' body='' out='' wfmt=''
for ((i = 0; i < $#; i++)); do
  case ${args[$i]} in
    -d|--data) body=${args[$((i + 1))]} ;;
    --data-binary)
      body=${args[$((i + 1))]}
      [[ $body == @* ]] && body=$(cat "${body#@}")   # payload gửi qua file
      ;;
    -o) out=${args[$((i + 1))]} ;;
    -w) wfmt=${args[$((i + 1))]} ;;
    http*) url=${args[$i]} ;;
  esac
done
code=200
case $url in
  *whoami)
    if [[ -e $self/unlinked ]]; then
      code=401
      resp='{"detail":{"code":"project_disabled","message":"Dự án đã bị ngắt (/unlink trên bot) — chạy lại lệnh deploy trên máy để ghép nối lại"}}'
    else
      resp='{"status":"linked","project_name":"test-project","chat_id":"998877665"}'
    fi
    ;;
  *register-chatid)
    printf '%s' "$body" >"$self/register_body"
    resp='{"pair_ref":"SEC-TEST-REF","chat_id":"812345678","bot":"@test_bot","expires_in":900,"warning":null}'
    ;;
  *pairing-status*)
    n=$(cat "$self/poll_count" 2>/dev/null || echo 0)
    n=$((n + 1)); printf '%s' "$n" >"$self/poll_count"
    if ((n < 3)); then
      resp='{"status":"pending"}'
    else
      resp='{"status":"linked","api_key":"p2sk-test-key-42"}'
    fi
    ;;
  *ingest-log)
    if [[ -e $self/unlinked ]]; then
      code=401
      resp='{"detail":{"code":"project_disabled","message":"Dự án đã bị ngắt (/unlink trên bot) — chạy lại lệnh deploy trên máy để ghép nối lại"}}'
    else
      for ((i = 0; i < $#; i++)); do
        [[ ${args[$i]} == X-API-Key:* ]] && printf '%s' "${args[$i]}" >"$self/ingest_key"
      done
      printf '%s' "$body" >"$self/ingest_body"
      resp='{"received":1,"delivered":1}'
    fi
    ;;
  *) printf '{"error":"unknown endpoint %s"}' "$url" >&2; exit 1 ;;
esac
if [[ -n $out ]]; then printf '%s' "$resp" >"$out"; else printf '%s' "$resp"; fi
[[ -n $wfmt && $wfmt == *http_code* ]] && printf '%s' "$code"
exit 0
STUB
chmod +x "$stub/curl"
FAKE_EP=$(bash -c 'source "$1/lib/endpoint.sh"; p2s_endpoint_encode "http://fake-central.test"' _ "$SRC")
PAIR_ENV=(PATH="$stub:$PATH" WORKDIR="$w2" P2S_PAIR_POLL=1 P2S_PAIR_TIMEOUT=30
          P2S_ENDPOINT_B64="$FAKE_EP")

# Chat ID sai định dạng -> từ chối ngay, KHÔNG gọi server (không còn prompt
# tương tác: lệnh triển khai nhận đủ tham số, sai thì báo lỗi và dừng).
out=$(printf 'abc\n812345678\n' | env "${PAIR_ENV[@]}" \
      bash "$w2/engine/central.sh" pair --chatid abc 2>&1)
T "pair: chatid sai bị từ chối"  "không hợp lệ" "$out"
N "pair: chatid sai không gửi lên server" '"chat_id"' "$(cat "$stub/register_body" 2>/dev/null)"

# thiếu tham số -> báo đúng tham số còn thiếu
out=$(env "${PAIR_ENV[@]}" bash "$w2/engine/central.sh" pair 2>&1)
T "pair: thiếu chatid báo rõ" "thiếu tham số bắt buộc: --chatid" "$out"

# luồng đầy đủ --chatid: register -> poll -> lưu conf
rm -f "$stub/poll_count"
out=$(env "${PAIR_ENV[@]}" \
      bash "$w2/engine/central.sh" pair --chatid 998877665 2>&1)
T "pair: nêu thiết bị + IP khi đăng ký" "Đang đăng ký thiết bị test-device |" "$out"
T "pair: đăng ký đúng project"       '"project_name":"test-project"' "$(cat "$stub/register_body")"
T "pair: conf ghi xong là thành công" "API_KEY=" "$(cat "$w2/conf/central.conf")"
T "pair: conf lưu server + key"      "SERVER_URL=http://fake-central.test" \
  "$(cat "$w2/conf/central.conf")"
T "pair: conf lưu chat id"           "CHAT_ID=998877665" \
  "$(cat "$w2/conf/central.conf")"
T "pair: conf 0600"                  "600" "$(stat -c %a "$w2/conf/central.conf")"
N "pair: không tự bật agent khi chưa có supervisor" "agent" \
  "$(ls "$w2/projects/test-project/devices/test-device/run/agent" 2>/dev/null)"

# idempotent: chạy lại cùng tham số không gọi server lần nữa, không cấp key mới
: >"$stub/register_body"
out=$(env "${PAIR_ENV[@]}" \
      bash "$w2/engine/central.sh" pair --chatid 998877665 2>&1)
T "pair: chạy lại báo đã ghép nối" "Đã ghép nối trước đó" "$out"
T "pair: chạy lại KHÔNG gọi register" "" "$(cat "$stub/register_body")"
T "pair: giữ nguyên API key" "p2sk-test-key-42" "$(cat "$w2/conf/central.conf")"

# /unlink trên bot rồi chạy lại pair: whoami trả 401 -> PHẢI đăng ký lại
# (guard cũ chỉ tin conf local nên chặn re-pair — đây chính là bug đã sửa)
touch "$stub/unlinked"
: >"$stub/register_body"
out=$(env "${PAIR_ENV[@]}" \
      bash "$w2/engine/central.sh" pair --chatid 998877665 2>&1)
T "re-pair: key bị từ chối -> gọi register lại" '"project_name":"test-project"' \
  "$(cat "$stub/register_body")"
T "re-pair: conf được ghi lại với key mới" "API_KEY=" "$(cat "$w2/conf/central.conf")"
rm -f "$stub/unlinked"

# test mode: gửi 1 alert INFO qua đúng API key đã lưu
out=$(env "${PAIR_ENV[@]}" bash "$w2/engine/central.sh" test 2>&1)
T "test: delivered >= 1 trong phản hồi" "delivered" "$out"
T "test: dùng API key từ conf"          "X-API-Key: p2sk-test-key-42" "$(cat "$stub/ingest_key")"
T "test: message alert thử nêu device"  "test-device" "$(cat "$stub/ingest_body")"
T "test: payload là alert thử INFO"     '"severity":"INFO"' "$(cat "$stub/ingest_body")"

# agent đẩy alert khi dự án vừa bị /unlink: 401 KHÔNG được coi là gửi xong —
# alert phải vào spool kèm cảnh báo đúng nguyên nhân (trước đây curl coi 401
# là thành công, offset tiến và alert mất im lặng).
spoolf=$w2/projects/test-project/devices/test-device/run/agent/spool/pending.jsonl
alertq=$w2/projects/test-project/devices/test-device/alerts/queue.jsonl
mkdir -p "$(dirname "$alertq")"
printf '%s\n' '{"ts_utc":"2026-10-24T00:00:05Z","batch_id":"T-401","rule_id":"P2S-056","severity":"CRITICAL","message":"probe"}' >"$alertq"
touch "$stub/unlinked"
: >"$stub/ingest_body"
env "${PAIR_ENV[@]}" P2S_AGENT_POLL=1 timeout -s TERM 4 \
  bash "$w2/engine/central.sh" agent >/dev/null 2>"$w2/agent401.log"
T "agent 401: cảnh báo đúng nguyên nhân (/unlink)" "đã bị ngắt" "$(cat "$w2/agent401.log")"
T "agent 401: alert kẹt trong spool, không mất" '"batch_id":"T-401"' "$(cat "$spoolf" 2>/dev/null)"
N "agent 401: server KHÔNG nhận được alert"   '"batch_id":"T-401"' "$(cat "$stub/ingest_body")"

# ghép nối lại xong: agent drain spool — đúng batch, spool rỗng
rm -f "$stub/unlinked"
env "${PAIR_ENV[@]}" P2S_AGENT_POLL=1 timeout -s TERM 4 \
  bash "$w2/engine/central.sh" agent >/dev/null 2>&1
N "agent drain: spool rỗng sau khi gửi được" "T-401" "$(cat "$spoolf" 2>/dev/null)"
T "agent drain: server nhận đúng batch" '"batch_id":"T-401"' "$(cat "$stub/ingest_body")"

# --------------------------------------- docker_logs: container log qua file json
# Script chạy sudo nên đọc thẳng /var/lib/docker/containers (offset-tracked);
# dòng access trong stdout container -> nguồn access_log để trọn rule pack
# tấn công áp dụng; crash/marker -> nguồn docker.
w4=$(newlab)
mkdir -p "$w4/dkr/containers/abc123def456"
cid=abc123def456
printf '{"ID":"x","Name":"/web-php","Image":"php:8.2-apache"}' \
  >"$w4/dkr/containers/$cid/config.v2.json"
{
  printf '{"log":"10.0.0.9 - - [26/Oct/2026:03:00:02 +0000] \\"POST /up.php?PHP_SESSION_UPLOAD_PROGRESS=x HTTP/1.1\\" 200 5 \\"-\\" \\"php2shell-109619\\"","stream":"stdout","time":"2026-10-26T03:00:02Z"}\n'
  printf '{"log":"child exited on signal 11 (SIGSEGV)","stream":"stderr","time":"2026-10-26T03:00:03Z"}\n'
  printf '{"log":"[app] internal php2shell probe","stream":"stderr","time":"2026-10-26T03:00:04Z"}\n'
  printf '{"log":"normal app line","stream":"stdout","time":"2026-10-26T03:00:05Z"}\n'
} >"$w4/dkr/containers/$cid/$cid-json.log"
docker_env=(WORKDIR="$w4" DOCKER_LOG_DIR="$w4/dkr/containers")
out=$(env "${docker_env[@]}" bash "$w4/plugins/docker_logs.sh")
T "docker: access stdout -> access_log + UA php2shell" '"php2shell-109619"' "$out"
T "docker: access line bung field uri" "PHP_SESSION_UPLOAD_PROGRESS" \
  "$(printf '%s' "$out" | awk -F'\t' '$2=="access_log"{print $7}')"
T "docker: access line bung field method/status" $'POST\t' \
  "$(printf '%s' "$out" | awk -F'\t' '$2=="access_log"{print $6"\t"$8}')"
T "docker: tên container lấy từ config.v2.json" "docker:web-php" "$out"
T "docker: crash SIGSEGV giữ nguồn docker" "SIGSEGV" \
  "$(printf '%s' "$out" | awk -F'\t' '$2=="docker"{print $11}')"
N "docker: dòng app lành tính bị lọc bỏ" "normal app line" "$out"

# offset-tracked: chạy lại không quét lại dòng cũ (khác `docker logs --since`)
out2=$(env "${docker_env[@]}" bash "$w4/plugins/docker_logs.sh")
N "docker: chạy lại không trùng lặp (offset)" "php2shell" "$out2"

# rule pack phủ stream từ docker: tấn công + crash + marker stderr
printf '%s\n' "$out" >"$w4/dstream.tsv"
rout=$(WORKDIR="$w4" P2S_SRC_DIR="$w4" bash "$w4/engine/rule_match.sh" "$w4/dstream.tsv" 2>/dev/null)
T "docker rule: UA php2shell khớp P2S-008" "P2S-008" "$rout"
T "docker rule: upload_progress khớp P2S-017" "P2S-017" "$rout"
T "docker rule: crash khớp P2S-011" "P2S-011" "$rout"
T "docker rule: marker stderr khớp P2S-041" "P2S-041" "$rout"

# CLI fallback: DOCKER_LOG_DIR không đọc được -> quét qua `docker logs`
dstub=$w4/dockerstub
mkdir -p "$dstub"
cat >"$dstub/docker" <<'DSTUB'
#!/usr/bin/env bash
case "$1" in
  ps) printf 'web-cli\n' ;;
  logs) printf '1.2.3.4 - - [x] "GET /t HTTP/1.1" 200 1 "-" "php2shell-cli"\n' ;;
esac
DSTUB
chmod +x "$dstub/docker"
out3=$(env PATH="$dstub:$PATH" WORKDIR="$w4" DOCKER_LOG_DIR="$w4/no-dkr" \
         bash "$w4/plugins/docker_logs.sh")
T "docker CLI fallback: quét qua docker logs" '"php2shell-cli"' "$out3"

# HỒI QUY: cursor chưa có KHÔNG được rơi vào --since 0 (epoch 0 = đọc toàn bộ
# lịch sử). Bug thật: _cursor_get trả "\t0", tab đầu bị `read` IFS nuốt thành
# cur_ts="0" -> lần chạy đầu nuốt lại mọi log cũ của container.
dstub2=$w4/dockerstub2
mkdir -p "$dstub2"
cat >"$dstub2/docker" <<'DSTUB2'
#!/usr/bin/env bash
self=$(dirname "$0")
if [[ $1 == ps ]]; then printf 'old-box\n'; exit 0; fi
printf '%s\n' "$*" >"$self/logs_args"
# mô phỏng --since của docker: chỉ khi bị gọi --since 0 (epoch 0) mới trả
# dòng log cổ đại; --since 10m thì không có dòng nào trong cửa sổ.
case " $* " in
  *" --since 0 "*)
    printf '%s\n' '2024-01-01T00:00:00.000000001Z 1.2.3.4 - - [x] "GET /ancient HTTP/1.1" 200 1 "-" "php2shell-ancient"' ;;
esac
DSTUB2
chmod +x "$dstub2/docker"
rm -f "$w4/projects/test-project/devices/test-device/state/docker_cursors.tsv"
: >"$dstub2/logs_args"
out4=$(env PATH="$dstub2:$PATH" WORKDIR="$w4" DOCKER_LOG_DIR="$w4/no-dkr" \
         bash "$w4/plugins/docker_logs.sh")
T "docker: lần đầu dùng --since mặc định, không phải 0" "since 10m" "$(cat "$dstub2/logs_args")"
N "docker: không đọc lại dòng log cổ đại (epoch-0)" "php2shell-ancient" "$out4"

# "min" phải nằm TRONG match: đặt lệch ra ngoài (P2S-052/055 cũ) thì jsonl.awk
# đọc match.min rỗng -> min=1, ngưỡng kìm lặng lẽ biến mất — rule ồn ào vô điều kiện.
awk -f "$SRC/lib/jsonl.awk" rules="$w4/rules_parsed.tsv" ands="$w4/ands_parsed.tsv" \
    "$SRC"/rules/pack/*.jsonl 2>/dev/null
T "rules: P2S-052 min=3 (nằm trong match)" "3" \
  "$(awk -F'\037' '$1=="P2S-052"{print $10}' "$w4/rules_parsed.tsv")"
T "rules: P2S-055 min=3 (nằm trong match)" "3" \
  "$(awk -F'\037' '$1=="P2S-055"{print $10}' "$w4/rules_parsed.tsv")"

# ------------------------------------------- rule pack không cần jq
# Rule pack đọc bằng lib/jsonl.awk. Đây là điều kiện sống còn: nếu jq là bắt
# buộc thì host không cài được jq sẽ chạy monitor mà không phát hiện gì.
w6=$(newlab)

# awk parser phải cho ra đúng từng field như jq (nếu máy build có jq).
if command -v jq >/dev/null 2>&1; then
  awk -f "$SRC/lib/jsonl.awk" rules="$w6/awk.tsv" ands="$w6/awk.and.tsv" \
    "$SRC"/rules/pack/*.jsonl 2>/dev/null
  jq -r '[.id,.severity,(.impact//""),(.enabled//true|tostring),(.needs//[]|join(",")),(.source//[]|join(",")),(.match.type//"regex"),(.match.field//"msg"),.match.pcre,(.match.min//1|tostring)]|join("\u001f")' \
    "$SRC"/rules/pack/*.jsonl 2>/dev/null | sort >"$w6/jq.tsv"
  LC_ALL=C sort "$w6/awk.tsv" -o "$w6/awk.tsv"
  LC_ALL=C sort "$w6/jq.tsv" -o "$w6/jq.tsv"
  T "rules: awk parser khớp jq từng field" "" "$(diff "$w6/awk.tsv" "$w6/jq.tsv")"
  T "rules: awk parser đọc đủ rule"       "$(wc -l <"$w6/jq.tsv" | tr -d ' ')" \
    "$(wc -l <"$w6/awk.tsv" | tr -d ' ')"
else
  pass "rules: awk parser khớp jq từng field (bỏ qua: máy build không có jq)"
  pass "rules: awk parser đọc đủ rule (bỏ qua: máy build không có jq)"
fi

# and-condition (P2S-016: status ^500$ AND uri \.php) phải parse được
T "rules: and-condition parse ra" "uri" "$(awk -F'\037' '$1=="P2S-016"{print $2}' "$w6/awk.and.tsv")"
T "rules: and-condition pcre giữ backslash" '\.php' "$(awk -F'\037' '$1=="P2S-016"{print $3}' "$w6/awk.and.tsv")"

# P2S-025 có \| trong PCRE: backslash phải còn nguyên, không bị JSON unescape
T "rules: pcre giữ \\| nguyên vẹn" "base64 -d \\|" \
  "$(awk -F'\037' '$1=="P2S-025"{print $9}' "$w6/awk.tsv")"

# Phát hiện phải chạy được khi KHÔNG có jq trong PATH.
mkdir -p "$w6/bin"
for c in bash awk sed grep tr wc cut sort comm seq mktemp rm mv cat head tail \
         stat date mkdir dirname basename find flock printf env nice timeout \
         hostname id uname; do
  p=$(command -v "$c" 2>/dev/null) && ln -sf "$p" "$w6/bin/$c"
done
stream="$w6/nojq.tsv"
awk -f "$SRC/lib/accesslog.awk" -v src=access_log "$FIX/mal_access_php2shell_ua.log" >"$stream"
out=$(PATH="$w6/bin" WORKDIR="$w6" P2S_SRC_DIR="$w6" P2S_JQ= \
      "$w6/bin/bash" "$w6/engine/rule_match.sh" "$stream" 2>/dev/null)
T "rules: phát hiện được khi KHÔNG có jq" "P2S-008" "$(printf '%s' "$out" | cut -f12)"
T "rules: không cần jq vẫn ra đúng 1 hit" "1" "$(printf '%s\n' "$out" | grep -c .)"

# auto-install jq không được làm hỏng lượt chạy khi không phải root / không có pm
out=$(bash -c 'source "$1/lib/deps.sh"; P2S_JQ=""; p2s_ensure_jq --quiet; echo "rc=$?"' _ "$SRC" 2>&1)
T "deps: ensure_jq không exit khác 0" "rc=0" "$(printf '%s' "$out" | grep -o 'rc=[01]')"

# ------------------------------------------- locale không được xoá code
# Lỗi thật đã xảy ra: bootstrap sort .present bằng LC_ALL=C nhưng gọi comm
# KHÔNG có LC_ALL=C. Dưới en_US.UTF-8, "lib/json.sh" và "lib/jsonl.awk" đổi chỗ,
# comm coi input "not in sorted order" rồi trả về danh sách rác -> bootstrap xoá
# gần hết code vừa giải nén -> main.sh chết "No such file or directory".
# GNU comm mới báo lỗi; uutils comm thì im lặng trả kết quả sai, nên test phải
# kiểm chính HÀNH VI (file còn hay mất), không chỉ kiểm thông báo lỗi.

# 1) proof of the hazard: hai locale sắp khác nhau trên đúng cặp tên này
c_order=$(printf 'lib/json.sh\nlib/jsonl.awk\n' | LC_ALL=C sort | tr '\n' ' ')
u_order=$(printf 'lib/json.sh\nlib/jsonl.awk\n' | LC_ALL=en_US.UTF-8 sort 2>/dev/null | tr '\n' ' ')
if [[ -n $u_order && $c_order != "$u_order" ]]; then
  pass "locale: C và UTF-8 sắp khác nhau (đúng ca lỗi)"
else
  pass "locale: máy không có en_US.UTF-8 — bỏ qua so sánh collation"
fi

# 2) khối prune phải chạy trọn trong LC_ALL=C: mô phỏng bằng cách so sánh
#    kết quả comm khi cả hai bước cùng C với khi comm chạy locale ngoài.
present=$(mktemp); manifest=$(mktemp)
printf 'lib/json.sh\nlib/jsonl.awk\nlib/log.sh\n' >"$present"
printf 'lib/json.sh\nlib/jsonl.awk\nlib/log.sh\n' >"$manifest"
if command -v gnucomm >/dev/null 2>&1; then
  # comm chỉ kiểm thứ tự khi nó thực sự đọc đủ xa, nên list 3 dòng không đủ
  # kích hoạt. Dùng danh sách cỡ thật (như MANIFEST của payload).
  { for i in $(seq 1 40); do printf 'lib/f%02d.sh\n' "$i"; done
    printf 'lib/json.sh\nlib/jsonl.awk\nlib/log.sh\n'; } >"$present"
  # manifest phải KHÁC present (superset, như bản nâng cấp thật): comm chỉ đọc
  # đủ sâu để phát hiện sai thứ tự khi hai file không giống nhau.
  { for i in $(seq 1 45); do printf 'lib/f%02d.sh\n' "$i"; done
    printf 'lib/json.sh\nlib/jsonl.awk\nlib/log.sh\n'; } >"$manifest"
  LC_ALL=C sort "$present" -o "$present"; LC_ALL=C sort "$manifest" -o "$manifest"
  out=$(LC_ALL=C gnucomm -23 "$present" "$manifest" 2>&1)
  T "locale: comm trong C không báo lỗi thứ tự" "" "$out"
  out=$(LC_ALL=en_US.UTF-8 gnucomm -23 "$present" "$manifest" 2>&1)
  T "locale: comm ngoài C thì lỗi (đúng ca gốc)" "not in sorted order" "$out"
else
  pass "locale: comm trong C không báo lỗi thứ tự (không có gnucomm)"
  pass "locale: comm ngoài C thì lỗi (không có gnucomm)"
fi
rm -f -- "$present" "$manifest"

# 3) bootstrap thật: cài vào thư mục tạm rồi chạy lại (đường upgrade) dưới
#    locale UTF-8. Code phải còn đủ sau khi prune.
if [[ -f $SRC/bootstrap.sh && -d $SRC/rules/pack ]]; then
  bt=$(mktemp -d)
  cp -a "$SRC"/lib "$SRC"/engine "$SRC"/plugins "$SRC"/rules "$SRC"/discovery \
        "$SRC"/export "$SRC"/main.sh "$SRC"/bootstrap.sh "$bt"/ 2>/dev/null
  cp -a "$SRC/conf" "$bt/conf.default" 2>/dev/null
  ( cd "$bt" && find . -type f -printf '%P\n' | LC_ALL=C sort >MANIFEST )
  n_before=$(find "$bt/lib" -type f | wc -l | tr -d ' ')
  # chạy phần prune đúng như bootstrap (LC_ALL=C cho cả sort và comm)
  ( cd "$bt" && LC_ALL=C bash -c '
      find lib engine plugins rules discovery conf.default -type f 2>/dev/null | LC_ALL=C sort >.present
      LC_ALL=C sort MANIFEST >.manifest
      LC_ALL=C comm -23 .present .manifest >.stale
      while IFS= read -r rel; do [[ -n $rel ]] && rm -f -- "$rel"; done <.stale
      rm -f .present .manifest .stale' ) 2>/dev/null
  n_after=$(find "$bt/lib" -type f | wc -l | tr -d ' ')
  T "locale: prune dưới C giữ nguyên code" "$n_before" "$n_after"
  rm -rf -- "$bt"
else
  pass "locale: prune dưới C giữ nguyên code (thiếu src, bỏ qua)"
fi

# ------------------------------------- webshell phải báo LẠI mỗi batch
# Lỗi thật: webroot_manifest.sh dedup trên path+size+mtime và ghi vĩnh viễn vào
# webroot.seen.tsv. Webshell đã drop thì không ai sửa nữa -> file đứng yên ->
# chỉ báo đúng MỘT lần rồi câm mãi. Batch sau mất impact=rce nên alert tụt
# CRITICAL -> MODERATE, Telegram chỉ còn "Server đang bị khai thác php2shell"
# trong khi server đã bị chiếm quyền. Đây là test cho HÀNH VI ĐÓ.
if [[ -f $SRC/plugins/webroot_manifest.sh ]]; then
  ws=$(mktemp -d)
  mkdir -p "$ws/html" "$ws/state" "$ws/tmp"
  printf '<?php echo "P2S_WEBSHELL"; system($_REQUEST[0]); ?>\n' >"$ws/html/s.php"
  # batch 1: baseline được chấp nhận, chưa báo gì
  out1=$(WORKDIR=$ws P2S_STATE_DIR=$ws/state P2S_TMP_DIR=$ws/tmp \
    WEBROOTS=$ws/html bash "$SRC/plugins/webroot_manifest.sh" 2>/dev/null)
  # batch 2: file KHÔNG đổi (đúng thực tế: shell đã drop thì đứng yên)
  out2=$(WORKDIR=$ws P2S_STATE_DIR=$ws/state P2S_TMP_DIR=$ws/tmp \
    WEBROOTS=$ws/html bash "$SRC/plugins/webroot_manifest.sh" 2>/dev/null)
  # batch 3: vẫn không đổi
  out3=$(WORKDIR=$ws P2S_STATE_DIR=$ws/state P2S_TMP_DIR=$ws/tmp \
    WEBROOTS=$ws/html bash "$SRC/plugins/webroot_manifest.sh" 2>/dev/null)
  n2=$(printf '%s' "$out2" | grep -c . )
  n3=$(printf '%s' "$out3" | grep -c . )
  T "webshell: batch 2 vẫn báo lại" "1" "$n2"
  T "webshell: batch 3 vẫn báo lại" "1" "$n3"
  T "webshell: báo lại đúng path" "1" "$(printf '%s' "$out3" | grep -c 'html/s.php')"
  T "webshell: nội dung shell nằm trong msg" "1" "$(printf '%s' "$out3" | grep -c 'system')"
  # shell bị xoá -> không còn báo
  rm -f "$ws/html/s.php"
  out4=$(WORKDIR=$ws P2S_STATE_DIR=$ws/state P2S_TMP_DIR=$ws/tmp \
    WEBROOTS=$ws/html bash "$SRC/plugins/webroot_manifest.sh" 2>/dev/null)
  T "webshell: file biến mất thì hết báo" "0" "$(printf '%s' "$out4" | grep -c 'webshell')"
  # state không được chứa file dedup vĩnh viễn kiểu cũ
  T "webshell: không còn webroot.seen.tsv" "0" "$(ls "$ws/state" 2>/dev/null | grep -c 'seen')"
  rm -rf -- "$ws"
else
  pass "webshell: batch 2 vẫn báo lại (thiếu src, bỏ qua)"
  pass "webshell: batch 3 vẫn báo lại (thiếu src, bỏ qua)"
  pass "webshell: báo lại đúng path (thiếu src, bỏ qua)"
  pass "webshell: nội dung shell nằm trong msg (thiếu src, bỏ qua)"
  pass "webshell: file biến mất thì hết báo (thiếu src, bỏ qua)"
  pass "webshell: không còn webroot.seen.tsv (thiếu src, bỏ qua)"
fi

# ------------------------------- rule phải khớp path session TUỲ BIẾN
# Lỗi thật: P2S-050/051 hardcode /var/lib/php/sessions, /tmp/sess_ — tức chỉ
# đường dẫn mặc định của Debian/Ubuntu. Một host đặt session.save_path riêng
# (/opt/lab81v/sessions/) thì LFI đọc session hoàn toàn vô hình: 18 dòng log
# tấn công thật đi qua mà 0/24 rule fire -> batches.log ghi "no-hits".
# Rule phải khớp theo CẤU TRÚC (thư mục sessions + tiền tố sess_), không theo
# đường dẫn tuyệt đối của một distro.
if [[ -f $SRC/rules/pack/t4.jsonl ]]; then
  # trích pcre của từng rule id từ pack
  _pcre() { # <id>
    awk -v id="$1" '
      index($0, "\"id\":\"" id "\"") {
        if (match($0, /"pcre":"([^"]|\\")*"/)) {
          s = substr($0, RSTART + 8, RLENGTH - 9)
          gsub(/\\\\/, "\\", s)
          print s; exit
        }
      }' "$SRC"/rules/pack/*.jsonl 2>/dev/null
  }
  if command -v python3 >/dev/null 2>&1; then
    _rx() { python3 -c 'import re,sys; print("Y" if re.search(sys.argv[1], sys.argv[2], re.I) else "n")' "$1" "$2"; }
    p51=$(_pcre P2S-051)
    p50=$(_pcre P2S-050)
    # path session tuỳ biến — đúng ca đã gây lỗi
    T "rules: P2S-051 khớp /opt/lab81v/sessions/sess_" "Y" \
      "$(_rx "$p51" '/download.php?file=/opt/lab81v/sessions/sess_dga2c162b35c80422f')"
    T "rules: P2S-051 khớp /var/lib/php/sessions/sess_" "Y" \
      "$(_rx "$p51" '/x.php?file=/var/lib/php/sessions/sess_abc123def456ghi789jkl')"
    T "rules: P2S-051 khớp /tmp/sess_" "Y" \
      "$(_rx "$p51" '/x.php?file=/tmp/sess_abcdefghij')"
    T "rules: P2S-051 khớp /dev/shm/sess_" "Y" \
      "$(_rx "$p51" '/x.php?file=/dev/shm/sess_zzz111222')"
    T "rules: P2S-051 khớp /srv/uploads/sess_" "Y" \
      "$(_rx "$p51" '/x.php?file=/srv/uploads/sess_mmm555444')"
    T "rules: P2S-050 khớp path tuyệt đối bất kỳ" "Y" \
      "$(_rx "$p50" '/a.php?file=/opt/lab81v/sessions/sess_abc')"
    # KHÔNG được false-positive trên traffic thường
    T "rules: P2S-050 không khớp ?page=home" "n" "$(_rx "$p50" '/about.php?page=home')"
    T "rules: P2S-050 không khớp ?p=2" "n" "$(_rx "$p50" '/list.php?p=2')"
    T "rules: P2S-050 không khớp ?id=15" "n" "$(_rx "$p50" '/view.php?id=15')"
    T "rules: P2S-051 không khớp chữ 'session' thường" "n" \
      "$(_rx "$p51" '/search?q=session+timeout')"
    # P2S-057: LFI thành công (2xx + param nhận absolute path), impact=rce
    if grep -q '"id":"P2S-057"' "$SRC"/rules/pack/*.jsonl 2>/dev/null; then
      T "rules: có P2S-057 (LFI thành công)" "1" "$(grep -l '"id":"P2S-057"' "$SRC"/rules/pack/*.jsonl | wc -l | tr -d ' ')"
      T "rules: P2S-057 đánh dấu impact=rce" "1" \
        "$(grep -c '"id":"P2S-057".*"impact":"rce"' "$SRC"/rules/pack/*.jsonl)"
    else
      pass "rules: có P2S-057 (LFI thành công)"
      pass "rules: P2S-057 đánh dấu impact=rce"
    fi
  else
    pass "rules: P2S-051 khớp path session tuỳ biến (thiếu python3, bỏ qua)"
    pass "rules: P2S-050 khớp path tuyệt đối (thiếu python3, bỏ qua)"
  fi
else
  pass "rules: pack t4 tồn tại"
fi


# ------------------------------- P2S-010 không được bắt cảnh báo PHP lành
# Lỗi thật (end user báo): container php80-test đẩy lên central 3 event HIGH
# "Session ID is too long / Failed to read session data / Failed to write
# session data" — toàn cảnh báo lành. Nguyên nhân: nhánh pcre trần
# "in Unknown on line 0" khớp ĐUÔI của mọi thông điệp PHP, không riêng crash.
if command -v python3 >/dev/null 2>&1; then
  _rx2() { python3 -c 'import re,sys; print("Y" if re.search(sys.argv[1], sys.argv[2]) else "n")' "$1" "$2"; }
  p10=$(awk -v id='P2S-010' 'index($0,"\"id\":\"" id "\""){ if (match($0,/"pcre":"([^"]|\\")*"/)) { s=substr($0,RSTART+8,RLENGTH-9); gsub(/\\\\/,"\\",s); print s; exit } }' "$SRC"/rules/pack/*.jsonl 2>/dev/null)
  # cảnh báo lành -> KHÔNG khớp
  T "P2S-010: không khớp 'Session ID is too long'" "n" \
    "$(_rx2 "$p10" 'PHP Warning:  Unknown: Session ID is too long or contains illegal characters. Only the A-Z, a-z, 0-9, "-", and "," characters are allowed in Unknown on line 0')"
  T "P2S-010: không khớp 'Failed to read session data'" "n" \
    "$(_rx2 "$p10" 'PHP Warning:  Unknown: Failed to read session data: files (path: ) in Unknown on line 0')"
  T "P2S-010: không khớp 'Failed to write session data'" "n" \
    "$(_rx2 "$p10" 'PHP Warning:  Unknown: Failed to write session data (files). Please verify that the current setting of session.save_path is correct () in Unknown on line 0')"
  T "P2S-010: không khớp 'Module already loaded'" "n" \
    "$(_rx2 "$p10" 'PHP Warning:  Module "xdebug" already loaded in Unknown on line 0')"
  T "P2S-010: không khớp 'Undefined index'" "n" \
    "$(_rx2 "$p10" 'PHP Notice:  Undefined index: foo in Unknown on line 0')"
  # lỗi thật -> PHẢI khớp
  T "P2S-010: khớp OOM thật" "Y" \
    "$(_rx2 "$p10" 'PHP Fatal error:  Allowed memory size of 134217728 bytes exhausted (tried to allocate 20480 bytes) in /var/www/html/upload.php on line 12')"
  T "P2S-010: khớp Out of memory" "Y" \
    "$(_rx2 "$p10" 'PHP Fatal error:  Out of memory (allocated 1234567) in Unknown on line 0')"
  T "P2S-010: khớp Hard memory limit" "Y" \
    "$(_rx2 "$p10" '[pool www] child 42 said: Hard memory limit of 268435456 bytes reached')"
else
  pass "P2S-010: cần python3 để test regex"
fi

# ------------------------------- docker plugin không đọc lại cửa sổ cũ
# Lỗi thật: plugin chạy `docker logs --since 10m` mỗi batch mà không lưu con
# trỏ. BATCH_INTERVAL=300s < 600s nên cùng một dòng bị đẩy lên 2-3 lần, và `n`
# đếm lại từ 1 khiến file:line trỏ sai. Plugin phải có cursor bền.
if [[ -f $SRC/plugins/docker_logs.sh ]]; then
  T "docker: plugin có cursor bền" "1" \
    "$(grep -c 'CURSOR_FILE=' "$SRC/plugins/docker_logs.sh")"
  T "docker: cursor đọc theo container" "1" \
    "$(grep -c 'docker_cursors.tsv' "$SRC/plugins/docker_logs.sh")"
  T "docker: dùng --timestamps để so sánh" "yes" \
    "$(grep -q 'docker logs --timestamps' "$SRC/plugins/docker_logs.sh" && echo yes)"
  # prefilter không được có nhánh "in Unknown on line 0" TRẦN. Nhánh có tiền tố
  # "PHP Fatal error:.*" là đúng (crash thật), nên phải kiểm cả hai chiều.
  T "docker: không có nhánh 'Unknown on line 0' trần" "no" \
    "$(grep -qE "(^|[|])in Unknown on line 0([|']|$)" "$SRC/plugins/docker_logs.sh" && echo yes || echo no)"
  T "docker: 'Unknown on line 0' chỉ sau PHP Fatal error" "yes" \
    "$(grep -q 'PHP Fatal error:.*in Unknown on line 0' "$SRC/plugins/docker_logs.sh" && echo yes)"
else
  pass "docker: plugin tồn tại"
fi

# --------------------------- đọc /proc/<pid>/cmdline không rò lỗi ra stderr
# Lỗi thật (end user báo khi cài 1.3.4):
#   ./bootstrap.sh: line 57: /proc/354810/cmdline: No such file or directory
# pgrep liệt kê PID xong process chết trước khi đọc /proc/<pid>. Cách viết cũ
# "<file" rồi mới "2>/dev/null" KHÔNG chặn được: shell mở input redirection
# trước khi áp stderr cho lệnh. Đo thực tế: cách cũ rò 200/200 lần, cách mới 0.
_dead_pid=999999999
T "cmdline: cách cũ rò lỗi ra stderr" "yes" \
  "$(err=$( { tr '\0' ' ' <"/proc/$_dead_pid/cmdline" 2>/dev/null; } 2>&1 ); [[ -n $err ]] && echo yes)"
T "cmdline: 2>/dev/null trước < thì im lặng" "no" \
  "$(err=$( { tr '\0' ' ' 2>/dev/null <"/proc/$_dead_pid/cmdline"; } 2>&1 ); [[ -n $err ]] && echo yes || echo no)"

# và không file nguồn nào được quay lại thứ tự cũ
for _f in bootstrap.sh engine/supervisor.sh plugins/proc_tree.sh; do
  T "cmdline: $_f không còn '<file 2>/dev/null'" "no" \
    "$(grep -qE 'cmdline" 2>/dev/null' "$SRC/$_f" && echo yes || echo no)"
done

# --------------------- docker_logs: tốc độ + checkpoint khi bị kill
# Lỗi thật: hai container 76 MB = 1.216.130 dòng. Đường bash cũ (sed + grep
# mỗi dòng = 2 fork ≈ 2.4 ms) mất 49 phút, vượt PLUGIN_TIMEOUT 120 s nên plugin
# bị kill mỗi batch. Offset lại chỉ được ghi SAU vòng lặp => không có tiến độ
# nào được lưu => batch sau đọc lại từ byte 0 => vòng lặp chết vĩnh viễn.
w7=$(newlab)
mkdir -p "$w7/dkr/containers/c7"
printf '{"ID":"x","Name":"/big"}' >"$w7/dkr/containers/c7/config.v2.json"
# 3000 dòng: đủ để vượt mốc checkpoint (mặc định 2000) ít nhất một lần
{
  i=0
  while (( i < 3000 )); do
    i=$((i + 1))
    printf '{"log":"10.0.0.%d -  26/Oct/2026:03:00:00 +0000 \\"GET /p%d.php\\" 200\\n","stream":"stdout","time":"2026-10-26T03:00:00Z"}\n' \
      "$(( (i % 250) + 1 ))" "$i"
  done
} >"$w7/dkr/containers/c7/c7-json.log"

t0=$(date +%s%N)
out7=$(env WORKDIR="$w7" DOCKER_LOG_DIR="$w7/dkr/containers" bash "$w7/plugins/docker_logs.sh" 2>/dev/null)
t1=$(date +%s%N)
ms7=$(( (t1 - t0) / 1000000 ))

T "docker: đọc 3000 dòng < 5s (awk, không fork mỗi dòng)" "fast" \
  "$( (( ms7 < 5000 )) && echo fast || echo slow:${ms7}ms )"
T "docker: phát đủ 3000 record" "3000" "$(printf '%s' "$out7" | grep -c . )"
T "docker: line tăng đơn điệu 1..3000" "3000" \
  "$(printf '%s' "$out7" | awk -F'\t' '{print $4}' | tail -1)"
# offset phải được lưu và trỏ hết file
off7=$(cat "$w7"/projects/*/devices/*/state/offsets.tsv 2>/dev/null | awk -F'\t' '{print $4}')
T "docker: offset lưu số dòng tuyệt đối" "3000" "$off7"

# chạy lại: không có gì mới -> 0 record (offset có tác dụng)
out7b=$(env WORKDIR="$w7" DOCKER_LOG_DIR="$w7/dkr/containers" bash "$w7/plugins/docker_logs.sh" 2>/dev/null)
T "docker: chạy lại không đọc trùng" "0" "$(printf '%s' "$out7b" | grep -c . )"

# checkpoint: ép timeout cực ngắn trên file lớn, offset phải > 0 dù bị kill
w8=$(newlab)
mkdir -p "$w8/dkr/containers/c8"
printf '{"ID":"x","Name":"/huge"}' >"$w8/dkr/containers/c8/config.v2.json"
{
  i=0
  while (( i < 200000 )); do
    i=$((i + 1))
    printf '{"log":"10.0.0.1 -  26/Oct/2026:03:00:00 +0000 \\"GET /p%d.php\\" 200\\n","stream":"stdout","time":"2026-10-26T03:00:00Z"}\n' "$i"
  done
} >"$w8/dkr/containers/c8/c8-json.log"
env WORKDIR="$w8" DOCKER_LOG_DIR="$w8/dkr/containers" \
  BATCH_CHECKPOINT_LINES=500 timeout 2 bash "$w8/plugins/docker_logs.sh" >/dev/null 2>&1
saved8=$(cat "$w8"/projects/*/devices/*/state/offsets.tsv 2>/dev/null | awk -F'\t' '{print $3}')
T "docker: bị kill giữa chừng vẫn giữ checkpoint" "yes" \
  "$( [[ -n $saved8 && $saved8 -gt 0 ]] && echo yes || echo no:${saved8:-empty} )"

# ------------------- container: monitor container chạy trên host
# Lỗi thật: container ghi access log vào /var/log/nginx/access.log BÊN TRONG
# container, không ra stdout. docker_logs.sh chỉ đọc json log (stdout/stderr),
# mà FPM ghi theo access.format không có %Q%q nên query string mất sạch:
#   json log   : 0 dòng chứa 'page='
#   access.log : 635.840 dòng chứa 'page='
# Toàn bộ CVE-2026-109619 nằm trong query string -> monitor mù, container bị
# RCE liên tục mà không có alert nào.
w9=$(newlab)
mkdir -p "$w9/dkr/containers/aaaabbbbcccc" "$w9/fakeroot/var/log/nginx" "$w9/fakeroot/var/www/html"
# config.v2.json thật: Name có tiền tố /, Running là BOOLEAN, State.Pid là số
printf '{"ID":"aaaabbbbcccc","Name":"/web-one","State":{"Running":true,"Pid":1},"Path":"x"}' \
  >"$w9/dkr/containers/aaaabbbbcccc/config.v2.json"
cat >"$w9/fakeroot/var/log/nginx/access.log" <<'EOF'
192.168.0.1 - - [26/Oct/2026:07:47:15 +0000] "GET /vuln.php?page=/var/lib/php/sessions/sess_p2s7d73 HTTP/1.1" 200 410 "-" "curl/8.18.0" "-" request_length=138 content_length=-
192.168.0.1 - - [26/Oct/2026:07:47:16 +0000] "GET /health.php HTTP/1.1" 200 139 "-" "curl/8.18.0" "-" request_length=88 content_length=-
192.168.0.1 - - [26/Oct/2026:07:47:17 +0000] "POST /upload.php HTTP/1.1" 200 68 "-" "curl/8.18.0" "-" request_length=15000556 content_length=15000341
EOF
printf '<?php echo "P2S_WEBSHELL"; system($_REQUEST[0]); ?>\n' >"$w9/fakeroot/var/www/html/s.php"
printf '<?php echo "ok"; ?>\n' >"$w9/fakeroot/var/www/html/index.php"

# p2s_containers đọc config.v2.json -> phải bóc đúng Name/Pid/Running.
# Running là boolean (true không có nháy) nên parser string thuần sẽ trả rỗng
# và bỏ sót MỌI container.
c9=$(env P2S_CONTAINER_DIR="$w9/dkr/containers" bash -c \
  'source "$1/lib/container.sh"; p2s_containers' _ "$SRC" 2>/dev/null)
T "container: bóc được Name từ config.v2.json" "web-one" "$(printf '%s' "$c9" | cut -f2)"
T "container: bóc được Pid (Running là boolean)" "1" "$(printf '%s' "$c9" | cut -f3)"
T "container: bóc được cid đầy đủ" "aaaabbbbcccc" "$(printf '%s' "$c9" | cut -f5)"

# Access log container phải phát ra kèm QUERY STRING — đây là thứ json log làm mất.
printf 'aaaabbbbcccc\tweb-one\t%s/fakeroot\n' "$w9" >"$w9/map.tsv"
acc9=$(env WORKDIR="$w9" P2S_SRC_DIR="$SRC" P2S_CONTAINER_ROOTFS_MAP="$w9/map.tsv" \
       bash "$SRC/plugins/container_accesslog.sh" 2>/dev/null)
T "container: access log phát ra nguồn access_log" "yes" \
  "$(printf '%s' "$acc9" | grep -q 'access_log' && echo yes || echo no)"
T "container: GIỮ query string page=" "yes" \
  "$(printf '%s' "$acc9" | grep -q 'page=/var/lib/php/sessions' && echo yes || echo no)"
T "container: file hiển thị container:<tên>" "yes" \
  "$(printf '%s' "$acc9" | grep -q 'container:web-one' && echo yes || echo no)"
T "container: bóc được request_length 15MB" "yes" \
  "$(printf '%s' "$acc9" | grep -q '15000556' && echo yes || echo no)"

# Webshell trong webroot CONTAINER phải bị thấy (host không có /var/www/html).
ws9=$(newlab)
mkdir -p "$ws9/fakeroot/var/www/html" "$ws9/state" "$ws9/tmp"
printf '<?php echo "P2S_WEBSHELL"; system($_REQUEST[0]); ?>\n' >"$ws9/fakeroot/var/www/html/s.php"
printf 'aaaabbbbcccc\tweb-one\t%s/fakeroot\n' "$ws9" >"$ws9/map.tsv"
out9=$(env WORKDIR="$ws9" P2S_STATE_DIR="$ws9/state" P2S_TMP_DIR="$ws9/tmp" \
  P2S_CONTAINER_ROOTFS_MAP="$ws9/map.tsv" P2S_SRC_DIR="$SRC" \
  bash "$SRC/plugins/webroot_manifest.sh" 2>/dev/null)
out9b=$(env WORKDIR="$ws9" P2S_STATE_DIR="$ws9/state" P2S_TMP_DIR="$ws9/tmp" \
  P2S_CONTAINER_ROOTFS_MAP="$ws9/map.tsv" P2S_SRC_DIR="$SRC" \
  bash "$SRC/plugins/webroot_manifest.sh" 2>/dev/null)
T "container: webshell trong webroot container bị phát hiện" "yes" \
  "$(printf '%s' "$out9b" | grep -q "system(\$_REQUEST" && echo yes || echo no)"
T "container: tên hiển thị container:<tên>:/path" "yes" \
  "$(printf '%s' "$out9b" | grep -q 'container:web-one:/var/www/html/s.php' && echo yes || echo no)"
T "container: không báo trùng 2 lần" "1" \
  "$(printf '%s' "$out9b" | grep -c 'webshell pattern')"

# Khoá offset/manifest phải ỔN ĐỊNH qua restart container (pid đổi, cid không).
k9=$(env P2S_CONTAINER_ROOTFS_MAP="$w9/map.tsv" bash -c \
  'source "$1/lib/container.sh"; p2s_container_manifest_key "$2/fakeroot/var/www/html/s.php"' _ "$SRC" "$w9" 2>/dev/null)
T "container: khoá manifest dùng cid, không dùng /proc/<pid>" "yes" \
  "$( [[ $k9 == container:aaaabbbbcccc:* ]] && echo yes || echo "no:$k9" )"

# ---------------- offset KHÔNG được dừng giữa dòng khi cắt theo trần byte
# Lỗi thật: p2s_complete_bytes dùng công thức `n - 1` với n = tổng
# (length($0)+1). Công thức đó chỉ đúng khi dòng dở cuối dài 0 byte. Với
# "line1\nline2\npartial" nó trả 19 = CẢ FILE, tức là nuốt luôn dòng dở và
# đẩy offset vào GIỮA dòng. Batch sau đọc từ giữa dòng -> dòng đầu bị cắt đôi
# -> bóc field sai (ip rỗng, uri rỗng, ts lấy nhầm đoạn giữa) -> rule không
# khớp -> "no-hits" dù log đầy tấn công.
cb=$(mktemp -d)
printf 'line1\nline2\npartial' >"$cb/p.txt"
printf 'a\nb\n' >"$cb/full.txt"
printf 'noeol' >"$cb/short.txt"
got=$(env WORKDIR="$cb" P2S_SRC_DIR="$SRC" bash -c \
  'source "$P2S_SRC_DIR/plugins/_batch_common.sh"; p2s_complete_bytes "$1"' _ "$cb/p.txt" 2>/dev/null)
T "offset: bỏ dòng dở cuối (12, không phải 19)" "12" "$got"
got2=$(env WORKDIR="$cb" P2S_SRC_DIR="$SRC" bash -c \
  'source "$P2S_SRC_DIR/plugins/_batch_common.sh"; p2s_complete_bytes "$1"' _ "$cb/full.txt" 2>/dev/null)
T "offset: file kết thúc bằng newline giữ nguyên" "4" "$got2"
got3=$(env WORKDIR="$cb" P2S_SRC_DIR="$SRC" bash -c \
  'source "$P2S_SRC_DIR/plugins/_batch_common.sh"; p2s_complete_bytes "$1"' _ "$cb/short.txt" 2>/dev/null)
T "offset: file một dòng không newline -> 0" "0" "$got3"

# Đọc thật qua nhiều batch với trần byte nhỏ: dòng đầu MỖI batch phải nguyên vẹn.
cb2=$(newlab)
mkdir -p "$cb2/fakeroot/var/log/nginx"
{
  i=0
  while (( i < 400 )); do
    i=$((i + 1))
    printf '192.168.0.1 - - [26/Oct/2026:07:47:15 +0000] "GET /vuln.php?page=/var/lib/php/sessions/sess_%04d HTTP/1.1" 200 410 "-" "curl/8.18.0" "-" request_length=138\n' "$i"
  done
} >"$cb2/fakeroot/var/log/nginx/access.log"
printf 'aaaabbbbcccc\tweb-one\t%s/fakeroot\n' "$cb2" >"$cb2/map.tsv"
bad=0
for _ in 1 2 3 4 5; do
  first=$(env WORKDIR="$cb2" P2S_SRC_DIR="$SRC" P2S_CONTAINER_ROOTFS_MAP="$cb2/map.tsv" \
    CONTAINER_READ_CAP_BYTES=4096 \
    bash "$SRC/plugins/container_accesslog.sh" 2>/dev/null | head -1)
  # ip phải là 192.168.0.1, method GET, uri bắt đầu bằng /vuln.php — nếu offset
  # dừng giữa dòng thì cả ba field này rỗng hoặc lệch.
  ip=$(printf '%s' "$first" | cut -f5)
  uri=$(printf '%s' "$first" | cut -f7)
  [[ $ip == "192.168.0.1" && $uri == /vuln.php* ]] || bad=$((bad + 1))
done
T "offset: dòng đầu mỗi batch nguyên vẹn (không cắt giữa dòng)" "0" "$bad"

rm -rf -- "$w" "$w2" "$w6" "$w9" "$ws9" "$cb" "$cb2"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
