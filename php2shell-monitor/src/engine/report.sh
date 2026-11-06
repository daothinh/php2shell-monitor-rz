#!/usr/bin/env bash
# report.sh - turn one batch of rule hits into exactly ONE alert.
#
# Rules (the whole point of this file):
#   * at most one alert per batch, whatever matched;
#   * its severity is the highest severity among the hits;
#   * every raw hit line is preserved with its source file and line number.
#
# Writes, per batch:
#   evidence/<batch>.jsonl   one JSON object per hit (full raw line + file:line)
#   alerts/queue.jsonl       one alert line, only when the batch had hits
#   run/batches.log          one summary line, always
set -u
WORKDIR=${WORKDIR:-/opt/php2shell-monitor}
HITS=$1
BATCH=${2:-$(date -u +%Y%m%dT%H%M%SZ)}
WINDOW_START=${3:-0}
WINDOW_END=${4:-$(utc_epoch)}

source "$WORKDIR/lib/common.sh"
source "$WORKDIR/lib/json.sh"
source "$WORKDIR/lib/paths.sh"
p2s_device_init || exit 0
p2s_source_conf "$WORKDIR/conf/default.conf"

MAX_EVIDENCE_INLINE=${MAX_EVIDENCE_INLINE:-0}
# Số nhóm event nhét kèm alert để render Telegram. 0 = tắt.
ALERT_PREVIEW_MAX=${ALERT_PREVIEW_MAX:-8}

_rank() {
  case ${1^^} in
    CRITICAL) echo 5 ;; HIGH) echo 4 ;; MEDIUM) echo 3 ;; LOW) echo 2 ;; INFO) echo 1 ;;
    *) echo 0 ;;
  esac
}

_host=$(hostname 2>/dev/null || echo unknown)

# ---------------------------------------------------------------- no hits
if [[ ! -s $HITS ]]; then
  printf '%s\t%s\t%s\t%s\n' "$BATCH" "$PROJECT" "$DEVICE" "no-hits" \
    >>"$P2S_DEVICE_RUN_DIR/batches.log"
  exit 0
fi

EVIDENCE=$P2S_EVIDENCE_DIR/$BATCH.jsonl
ALERT=$P2S_ALERT_DIR/queue.jsonl

# ------------------------------------------------- 1. evidence (full, raw)
# One JSON object per event, written by a single awk process. The bash loop
# called json_obj (a subshell + fork) per hit: an 80k-hit batch took minutes
# and never finished inside the batch window.
COUNTS=$P2S_TMP_DIR/report.$BATCH.counts.tsv
: >"$COUNTS"
awk -f "$WORKDIR/lib/evidence.awk" -v outcounts="$COUNTS" \
  -v crit_threshold="${CRIT_THRESHOLD:-5000}" \
  "$HITS" >"$EVIDENCE"

total=0
top_sev=INFO
rce_hits=0
declare -A per_rule=()
declare -A per_sev=()
if [[ -s $COUNTS ]]; then
  while IFS=$'\t' read -r kind a b; do
    case $kind in
      R) per_rule[$a]=${b:-0} ;;
      S) per_sev[$a]=${b:-0} ;;
      *) total=${kind:-0}; top_sev=${a:-INFO}; rce_hits=${b:-0} ;;
    esac
  done <"$COUNTS"
fi
rm -f -- "$COUNTS"

# ------------------------------------------------- 2. counts (stable order)
_rule_counts_json() {
  local out='[' first=1 k n
  for k in $(printf '%s\n' "${!per_rule[@]}" | sort); do
    n=${per_rule[$k]}
    [[ $first -eq 1 ]] && first=0 || out+=','
    out+=$(json_obj "rule_id" "$(json_str "$k")" "hits" "$(json_num "$n")")
  done
  printf '%s]' "$out"
}
_sev_counts_json() {
  local out='[' first=1 k n
  for k in $(printf '%s\n' "${!per_sev[@]}" | sort); do
    n=${per_sev[$k]}
    [[ $first -eq 1 ]] && first=0 || out+=','
    out+=$(json_obj "severity" "$(json_str "${k^^}")" "hits" "$(json_num "$n")")
  done
  printf '%s]' "$out"
}

# ------------------------------------------------- 2b. container gây alert
# Alert sinh từ log/artifact của container phải nói rõ container nào:
# docker:<tên>[:<cid12>]      — json log stdout (plugin docker_logs)
# container:<tên>[:<cid12>][:...path] — access log/webroot BÊN TRONG container
# Operator đọc tin nhắn phân biệt ngay alert của host và của container nào
# (tên + id 12 ký tự). Evidence là JSONL: quét awk một lượt, tối đa 5 tên.
_containers_json() {
  [[ -s $EVIDENCE ]] || { printf '[]'; return; }
  awk '
    {
      s = $0
      # file = docker:<tên>:<cid12>:<đường dẫn>  |  container:<tên>:<đường dẫn>
      p = index(s, "\"file\":\"docker:")
      kind = "docker"; off = 15
      if (p == 0) {
        p = index(s, "\"file\":\"container:")
        kind = "container"; off = 18
      }
      if (p == 0) next
      f = substr(s, p + off)
      q = index(f, "\""); if (q > 0) f = substr(f, 1, q - 1)
      # tách tên container (phần trước dấu ":" đầu tiên)
      c = index(f, ":")
      if (c == 0) next
      name = substr(f, 1, c - 1)
      rest = substr(f, c + 1)
      id = ""
      # Đoạn ngay sau tên có thể là cid12 (bản cũ) hoặc đường dẫn tuyệt đối (bản
      # mới). Chỉ nhận khi đúng 12 hex — đường dẫn luôn bắt đầu bằng "/".
      c2 = index(rest, ":")
      seg = (c2 > 0) ? substr(rest, 1, c2 - 1) : rest
      if (length(seg) == 12 && seg ~ /^[0-9a-f]+$/) id = seg
      if (name == "") next
      if (!(name in seen)) { seen[name] = id; order[++n] = name }
      else if (seen[name] == "" && id != "") seen[name] = id
    }
    END {
      printf "["
      m = (n < 5 ? n : 5)
      for (j = 1; j <= m; j++) {
        f = order[j]; id = seen[f]
        printf "%s\"%s\"", (j > 1 ? "," : ""), (id != "" ? f " (" id ")" : f)
      }
      printf "]"
    }
  ' "$EVIDENCE"
}

# ------------------------------------------------- 3. evidence travels out-of-band
# The alert line stays small and metadata-only. Embedding the full set inline
# made one queue line 148 MB for a 300k-hit batch: mapfile held it in bash
# memory (761 MB RSS), paste built a second copy, and the agent never finished.
# The evidence file is uploaded separately as gzipped JSONL, complete and
# already deduplicated, and the server writes it straight to the mirror.
# MAX_EVIDENCE_INLINE>0 still embeds a preview for manual/debug use only.
truncated=false
inline='[]'
if [[ -n ${MAX_EVIDENCE_INLINE:-} && ${MAX_EVIDENCE_INLINE:-0} =~ ^[0-9]+$ ]] \
   && (( MAX_EVIDENCE_INLINE > 0 )); then
  inline="[$(head -n "$MAX_EVIDENCE_INLINE" -- "$EVIDENCE" | paste -sd, -)]"
  (( total > MAX_EVIDENCE_INLINE )) && truncated=true
fi

# ------------------------------------------------- 3b. preview cho tin Telegram
# Alert phải tự đủ để đọc trên Telegram: kèm ALERT_PREVIEW_MAX nhóm event đã gộp
# trùng, giữ NGUYÊN VĂN dòng log gốc. Nhóm impact=rce xếp trước để lệnh đã chạy
# không bị chìm dưới hàng nghìn dòng scan. Đây KHÔNG phải evidence[]: evidence[]
# là bản đầy đủ (và rỗng khi MAX_EVIDENCE_INLINE=0), preview chỉ là ảnh chụp nhỏ
# để render, luôn có kể cả khi evidence[] rỗng.
# preview_meta = "<tổng hit>\t<tổng số nhóm>" để server in "… +N nhóm".
preview='[]'
preview_meta=''
if [[ ${ALERT_PREVIEW_MAX:-8} =~ ^[0-9]+$ ]] && (( ALERT_PREVIEW_MAX > 0 )); then
  meta_file=$P2S_TMP_DIR/report.$BATCH.preview.meta
  : >"$meta_file"
  if [[ -s $EVIDENCE ]]; then
    preview="[$(awk -v outmeta="$meta_file" -v max="$ALERT_PREVIEW_MAX" \
      -f "$WORKDIR/lib/preview.awk" "$EVIDENCE" | paste -sd, -)]"
    IFS=$'\t' read -r _pv_total _pv_uniq <"$meta_file" || true
    preview_meta="${_pv_total:-0}|${_pv_uniq:-0}"
    # preview.awk hỏng/không có (bản cài thiếu file, awk lạ) thì đừng gửi alert
    # KHÔNG có raw: server sẽ in "0 nhóm / 0 events" và operator mất dấu sự kiện.
    # evidence JSONL đã đúng schema nhóm (rule_id/hits/severity/impact/file/
    # line/raw) nên lấy thẳng N dòng đầu là một preview hợp lệ, chỉ là không gộp
    # trùng và không ưu tiên nhóm rce.
    if [[ $preview == '[]' ]]; then
      preview="[$(head -n "$ALERT_PREVIEW_MAX" -- "$EVIDENCE" | paste -sd, -)]"
      preview_meta="${total}|${total}"
      printf '%s\tpreview.awk không sinh nhóm — dùng %s dòng evidence đầu\n' \
        "$BATCH" "$ALERT_PREVIEW_MAX" >>"$P2S_DEVICE_RUN_DIR/batches.log"
    fi
  fi
  rm -f -- "$meta_file"
fi

# ------------------------------------------------- 4. the single alert
alert=$(json_obj \
  "ts_utc" "$(json_str "$(utc_now)")" \
  "batch_id" "$(json_str "$BATCH")" \
  "project" "$(json_str "$PROJECT")" \
  "device" "$(json_str "$DEVICE")" \
  "host" "$(json_str "$DEVICE")" \
  "hostname" "$(json_str "$_host")" \
  "containers" "$(_containers_json)" \
  "window_start" "$(json_str "$(epoch_to_utc "${WINDOW_START:-0}" 2>/dev/null || utc_now)")" \
  "window_end" "$(json_str "$(epoch_to_utc "$WINDOW_END")")" \
  "severity" "$(json_str "$top_sev")" \
  "rce" "$(json_num "$rce_hits")" \
  "hits" "$(json_num "$total")" \
  "rules" "$(_rule_counts_json)" \
  "severities" "$(_sev_counts_json)" \
  "preview" "$preview" \
  "preview_meta" "$(json_str "$preview_meta")" \
  "evidence_file" "$(json_str "$EVIDENCE")" \
  "evidence_count" "$(json_num "$total")" \
  "evidence_truncated" "$truncated" \
  "evidence" "$inline")

printf '%s\n' "$alert" >>"$ALERT"
printf '%s\t%s\t%s\t%s\t%d hit(s)\t%s\n' \
  "$BATCH" "$PROJECT" "$DEVICE" "$top_sev" "$total" "$EVIDENCE" \
  >>"$P2S_DEVICE_RUN_DIR/batches.log"

# ------------------------------------------------- 5. retention
KEEP=${EVIDENCE_KEEP:-2016}   # 7 days of 5-minute batches
count=$(find "$P2S_EVIDENCE_DIR" -maxdepth 1 -name '*.jsonl' -type f | wc -l)
if (( count > KEEP )); then
  find "$P2S_EVIDENCE_DIR" -maxdepth 1 -name '*.jsonl' -type f -printf '%T@ %p\n' 2>/dev/null |
    sort -n | head -n "$((count - KEEP))" | cut -d' ' -f2- |
    while IFS= read -r old; do rm -f -- "$old"; done
fi
