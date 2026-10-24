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
# 13 columns: ts source file line ip method uri status ua pid msg rule severity
printf '%s\n' \
  $'2026-10-24T00:00:01Z\tfpm_error\t/var/log/fpm.log\t11\t\t\t\t\t\t42\tAllowed memory size exhausted\tP2S-010\tHIGH' \
  $'2026-10-24T00:00:02Z\taccess_log\t/var/log/access.log\t7\t1.2.3.4\tGET\t/sh.php\t200\tcurl\t\tGET /sh.php?cmd=id\tP2S-030\tHIGH' \
  $'2026-10-24T00:00:03Z\twebroot\t/var/www/shell.php\t0\t\t\t\t\t\t\twebroot file NEW\tP2S-020\tCRITICAL' \
  >"$hits"
report "$w" "$hits" "20261024T000000Z"
alert="$w/projects/test-project/devices/test-device/alerts/queue.jsonl"
T "alert: exactly one line per batch" "1" "$(wc -l <"$alert" | tr -d ' ')"
T "alert: severity is the highest hit" "CRITICAL" "$(jq -r '.severity' "$alert")"
T "alert: hit count preserved"         "3"        "$(jq -r '.hits' "$alert")"
T "alert: all rules counted"           "P2S-020"  "$(jq -r '[.rules[].rule_id]|join(",")' "$alert")"
T "alert: evidence keeps file path"    "/var/www/shell.php" "$(jq -r '.evidence[2].file' "$alert")"
T "alert: evidence keeps line number"  "11"       "$(jq -r '.evidence[0].line' "$alert")"
T "alert: evidence keeps raw line"     "cmd=id"   "$(jq -r '.evidence[1].raw' "$alert")"
T "alert: project carried"             "test-project" "$(jq -r '.project' "$alert")"
T "alert: device carried"              "test-device"  "$(jq -r '.device' "$alert")"
T "alert: evidence file written"       "20261024T000000Z.jsonl" "$(jq -r '.evidence_file' "$alert")"
T "evidence: one record per hit"       "3" "$(wc -l <"$w/projects/test-project/devices/test-device/evidence/20261024T000000Z.jsonl" | tr -d ' ')"

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
PAIR_ENV=(PATH="$stub:$PATH" WORKDIR="$w2" P2S_PAIR_POLL=1 P2S_PAIR_TIMEOUT=30)

# chat ID sai định dạng -> báo lỗi rồi đọc lại; giá trị hợp lệ ở lần 2 được dùng
out=$(printf 'abc\n812345678\n' | env "${PAIR_ENV[@]}" \
      bash "$w2/engine/central.sh" pair --server http://fake-central.test 2>&1)
T "pair: chatid sai bị từ chối"  "không đúng định dạng" "$out"
T "pair: đăng ký với chatid nhập lại" '"chat_id":"812345678"' "$(cat "$stub/register_body")"
N "pair: chatid sai không gửi lên server" '"abc"' "$(cat "$stub/register_body")"

# luồng đầy đủ --chatid: wizard -> register -> poll -> lưu conf
rm -f "$stub/poll_count"
out=$(env "${PAIR_ENV[@]}" \
      bash "$w2/engine/central.sh" pair --server http://fake-central.test --chatid 998877665 2>&1)
T "pair: nhắc chờ /confirm"          "Đang chờ /confirm"   "$out"
T "pair: đăng ký đúng project"       '"project_name":"test-project"' "$(cat "$stub/register_body")"
T "pair: thành công sau khi confirm" "GHÉP NỐI THÀNH CÔNG" "$out"
T "pair: gợi ý bước tiếp theo"        "php2shell-monitor.sh -- run" "$out"
T "pair: conf lưu server + key"      "SERVER_URL=http://fake-central.test" \
  "$(cat "$w2/conf/central.conf")"
T "pair: conf 0600"                  "600" "$(stat -c %a "$w2/conf/central.conf")"
N "pair: không tự bật agent khi chưa có supervisor" "agent" \
  "$(ls "$w2/projects/test-project/devices/test-device/run/agent" 2>/dev/null)"

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
