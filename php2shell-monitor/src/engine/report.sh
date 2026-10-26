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
[[ -f $WORKDIR/conf/default.conf ]] && source "$WORKDIR/conf/default.conf"

MAX_EVIDENCE_INLINE=${MAX_EVIDENCE_INLINE:-0}

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
      p = index(s, "\"file\":\"docker:")
      if (p > 0) f = substr(s, p + 15)
      else {
        p = index(s, "\"file\":\"container:")
        if (p > 0) f = substr(s, p + 18)
        else next
      }
      q = index(f, "\""); if (q > 0) f = substr(f, 1, q - 1)
      # bóc name rồi đoạn kế tiếp: 12 hex là cid12, còn lại (path...) bỏ qua
      id = ""
      c = index(f, ":")
      if (c > 0) {
        seg = substr(f, c + 1); f = substr(f, 1, c - 1)
        c2 = index(seg, ":"); if (c2 > 0) seg = substr(seg, 1, c2 - 1)
        if (length(seg) == 12 && seg ~ /^[0-9a-f]+$/) id = seg
      }
      disp = f
      if (f != "" && !(f in seen)) { seen[f] = id; order[++n] = f }
      else if (f in seen && seen[f] == "" && id != "") seen[f] = id
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
