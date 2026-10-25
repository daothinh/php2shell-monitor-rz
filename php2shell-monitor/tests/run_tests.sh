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
  printf 'BATCH_INTERVAL=300\nMAX_EVIDENCE_INLINE=500\nEVIDENCE_KEEP=50\nPLUGINS_DISABLED=""\n' \
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
T "alert: evidence keeps file path"    "/var/www/shell.php" "$(jq -r '.evidence[2].file' "$alert")"
T "alert: evidence keeps line number"  "11"       "$(jq -r '.evidence[0].line' "$alert")"
T "alert: evidence keeps raw line"     "cmd=id"   "$(jq -r '.evidence[1].raw' "$alert")"
T "alert: project carried"             "test-project" "$(jq -r '.project' "$alert")"
T "alert: device carried"              "test-device"  "$(jq -r '.device' "$alert")"
T "alert: evidence file written"       "20261024T000000Z.jsonl" "$(jq -r '.evidence_file' "$alert")"
T "evidence: one record per hit"       "3" "$(wc -l <"$w/projects/test-project/devices/test-device/evidence/20261024T000000Z.jsonl" | tr -d ' ')"

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

# inline cap
sed -i 's/^MAX_EVIDENCE_INLINE=.*/MAX_EVIDENCE_INLINE=2/' "$w/conf/default.conf"
report "$w" "$hits" "20261024T001500Z"
T "alert: inline evidence capped" "true" "$(jq -r '.evidence_truncated' "$alert" | tail -1)"
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
T "endpoint: giải mã ra URL http"      "http://" "$ep_out"
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
# fake Central Alert Server — emulates the endpoints central.sh calls
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
    printf '{"pair_ref":"SEC-TEST-REF","chat_id":"812345678","bot":"@test_bot","expires_in":900,"warning":null}'
    ;;
  *pairing-status*)
    n=$(cat "$self/poll_count" 2>/dev/null || echo 0)
    n=$((n + 1)); printf '%s' "$n" >"$self/poll_count"
    if ((n < 3)); then
      printf '{"status":"pending"}'
    else
      printf '{"status":"linked","api_key":"p2sk-test-key-42"}'
    fi
    ;;
  *ingest-log)
    for ((i = 0; i < $#; i++)); do
      [[ ${args[$i]} == X-API-Key:* ]] && printf '%s' "${args[$i]}" >"$self/ingest_key"
    done
    printf '%s' "$body" >"$self/ingest_body"
    printf '{"received":1,"delivered":1}'
    ;;
  *) printf '{"error":"unknown endpoint %s"}' "$url"; exit 1 ;;
esac
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

# test mode: gửi 1 alert INFO qua đúng API key đã lưu
out=$(env "${PAIR_ENV[@]}" bash "$w2/engine/central.sh" test 2>&1)
T "test: delivered >= 1 trong phản hồi" "delivered" "$out"
T "test: dùng API key từ conf"          "X-API-Key: p2sk-test-key-42" "$(cat "$stub/ingest_key")"
T "test: message alert thử nêu device"  "test-device" "$(cat "$stub/ingest_body")"
T "test: payload là alert thử INFO"     '"severity":"INFO"' "$(cat "$stub/ingest_body")"

rm -rf -- "$w" "$w2"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
