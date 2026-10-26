#!/usr/bin/env bash
# main.sh - CLI dispatcher. Runs with cwd=WORKDIR.
set -u
export WORKDIR=${WORKDIR:-/opt/php2shell-monitor}
P2S_SRC_DIR=$WORKDIR
export P2S_SRC_DIR
source "$WORKDIR/lib/common.sh"
source "$WORKDIR/lib/log.sh"
source "$WORKDIR/lib/paths.sh"
source "$WORKDIR/lib/endpoint.sh"

usage() {
  cat <<'EOF'
php2shell-monitor — cảnh báo an ninh php2Shell

TRIỂN KHAI (một lệnh duy nhất):

  sudo php2shell-monitor.sh --project <tên-dự-án> --chatid <id>

    --project  tên dự án khách hàng, ví dụ khach-hang-A
    --chatid   Chat ID Telegram: nhắn /id cho bot để lấy
               (chat riêng: số dương; group: số âm)

  Lệnh này ghi conf/device.conf, ghép nối với central server, lấy API key,
  rồi bật supervisor rà log mỗi 5 phút + forwarder đẩy alert về Telegram.

  Thiết bị đã thiết lập rồi thì chạy lại sẽ báo "THIẾT BỊ ĐÃ ĐƯỢC THIẾT LẬP"
  và thoát — không ghi đè conf, không cấp key mới. Ngoại lệ: nếu dự án đã
  bị /unlink trên bot (key bị thu hồi), đúng lệnh này TỰ ghép nối lại.

  Muốn ĐỔI cấu hình: thêm --force (xoá ghép nối cũ, cấp API key mới).
    sudo php2shell-monitor.sh --force --project <tên> --chatid <id>

Chế độ khác:
  once       Chạy một batch ngay
  run        Bật supervisor nền
  test       Gửi một alert thử
  status     Trạng thái thiết bị và batch gần nhất
  stop       Dừng supervisor
  discover   Rà host read-only
  retro      Săn một lượt trên log đã rotate
  export     Copy alert queue + evidence ra export/
  clean      stop + xoá toàn bộ /opt/php2shell-monitor
EOF
}

die() { printf 'php2shell-monitor: %s\n' "$*" >&2; exit 2; }

# Banner ASCII "VCCSEC" — printed once at the top of the deploy run.
banner() {
  cat <<'BANNER'
 __     __   ____   ____  ____   _____   ____
 \ \   / /  / ___| / ___|/ ___| | ____| / ___|
  \ \ / /  | |    | |    \___ \ |  _|  | |
   \ V /   | |___ | |___  ___) || |___ | |___
    \_/     \____| \____||____/ |_____| \____|
BANNER
}

# makeself passes the script args verbatim, so callers may write `-- once`.
[[ ${1:-} == -- ]] && shift

valid_project() { [[ $1 =~ ^[A-Za-z0-9._-]{1,64}$ ]]; }
valid_chatid()  { [[ $1 =~ ^-?[1-9][0-9]{2,14}$ ]]; }

mode=
opt_project=
opt_chatid=
opt_force=0
positional=()

first=${1:-}
case $first in
  help|-h|--help) mode=help ;;
  once|run|test|status|stop|discover|retro|export|clean) mode=$first ;;
esac
[[ -n $mode ]] && shift

# ---- tham số của lệnh triển khai ----
while (($#)); do
  case $1 in
    --server)  shift 2 ;;   # bỏ: endpoint nằm trong mã nguồn
    --project) [[ -n ${2:-} ]] || die "--project cần tên dự án"; opt_project=$2; shift 2 ;;
    --chatid)  [[ -n ${2:-} ]] || die "--chatid cần Chat ID"; opt_chatid=$2; shift 2 ;;
    --force)   opt_force=1; shift ;;
    --) shift; positional+=("$@"); break ;;
    -*) die "tham số không hợp lệ: $1 (xem: php2shell-monitor.sh help)" ;;
    *)  positional+=("$1"); shift ;;
  esac
done

# tên dự án đứng đầu (kiểu cũ) vẫn nhận: php2shell-monitor.sh <tên> --chatid ...
if [[ -z $opt_project && ${#positional[@]} -gt 0 ]]; then
  opt_project=${positional[0]}
fi

[[ $mode == help ]] && { usage; exit 0; }

# Không có mode tường minh -> đây là lệnh triển khai.
[[ -z $mode ]] && mode=setup

# Banner only for deploy; other modes keep their output parseable.
[[ $mode == setup ]] && banner

# Một lệnh: validate -> ghi identity -> ghép nối -> bật supervisor.
if [[ $mode == setup ]]; then
  # No wizard, no prompt: missing parameters are reported and the run stops.
  missing=()
  [[ -n $opt_project ]] || missing+=(--project)
  [[ -n $opt_chatid  ]] || missing+=(--chatid)
  if ((${#missing[@]})); then
    die "thiếu tham số bắt buộc: ${missing[*]}
  sudo php2shell-monitor.sh --project <tên-dự-án> --chatid <chat-id>"
  fi

  opt_project=$(printf '%s' "$opt_project" | tr -d ' ')
  valid_project "$opt_project" ||
    die "--project không hợp lệ: chỉ A-Z a-z 0-9 . _ - (1-64 ký tự)"
  opt_chatid=$(printf '%s' "$opt_chatid" | tr -d ' ')
  valid_chatid "$opt_chatid" ||
    die "--chatid không hợp lệ: phải là số Telegram (chat riêng dương, group âm)"
  opt_server=$(p2s_endpoint) || die "không đọc được endpoint trong mã nguồn"
  [[ $opt_server =~ ^https?:// ]] || die "endpoint trong mã nguồn không hợp lệ"
fi

# ---- guard: is this device already configured? ----
# Re-running deploy on a configured device would overwrite conf/device.conf,
# issue a new API key and move the alert chat. Report and exit instead, unless
# --force was given.
already_setup() {
  local dconf=$WORKDIR/conf/device.conf cconf=$WORKDIR/conf/central.conf
  local cur_proj='' cur_dev='' cur_key=''
  [[ -r $dconf ]] && {
    cur_proj=$(sed -n 's/^PROJECT="\(.*\)"$/\1/p' "$dconf" | head -1)
    cur_dev=$(sed -n 's/^DEVICE="\(.*\)"$/\1/p' "$dconf" | head -1)
  }
  [[ -r $cconf ]] && cur_key=$(sed -n 's/^API_KEY=//p' "$cconf" | head -1)
  # Configured = a real project (not "default") AND an API key.
  [[ -n $cur_proj && $cur_proj != default && -n $cur_key ]] || return 1
  ALREADY_PROJ=$cur_proj ALREADY_DEV=$cur_dev
  return 0
}

report_already_setup() {
  cat <<EOF

╔══════════════════════════════════════════════════════════════╗
║   ℹ️   THIẾT BỊ ĐÃ ĐƯỢC THIẾT LẬP MONITOR php2Shell          ║
╚══════════════════════════════════════════════════════════════╝
 Máy này đã cài đặt và ghép nối xong — không chạy lại lệnh triển khai.

 Dự án      :  ${ALREADY_PROJ}
 Thiết bị    :  ${ALREADY_DEV:-$(hostname 2>/dev/null || echo unknown)}

 Muốn xem trạng thái :  sudo php2shell-monitor.sh status
 Muốn gửi alert thử :  sudo php2shell-monitor.sh test
 Muốn dừng monitor   :  sudo php2shell-monitor.sh stop

 Muốn ĐỔI cấu hình (dự án / server / chat khác), thêm --force:
   sudo php2shell-monitor.sh --force --project <tên> --chatid <id>
   (lệnh này xoá ghép nối cũ, cấp API key mới và đổi chat nhận alert)

 Bị ngắt trên bot (/unlink)? Chạy lại đúng lệnh deploy ban đầu — script tự
 phát hiện key đã bị thu hồi và ghép nối lại, không cần --force.
EOF
}

# ---- write identity: PROJECT from the flag, DEVICE is always the hostname ----
# Must run before p2s_device_init: paths.sh reads conf/device.conf.
apply_project() { # <tên dự án>
  local name=$1 conf=$WORKDIR/conf/device.conf dev
  dev=$(hostname 2>/dev/null || echo unknown)
  (umask 077 && mkdir -p -- "$WORKDIR/conf")
  (umask 077 && printf '# php2shell-monitor — device identity (do lệnh triển khai ghi)\nPROJECT="%s"\nDEVICE="%s"\n' \
    "$name" "$dev" >"$conf")
  # recompute every path that was derived from the previous conf
  unset P2S_DATA_DIR P2S_ALERT_DIR P2S_EVIDENCE_DIR P2S_STATE_DIR P2S_DEVICE_RUN_DIR
  p2s_device_init || die "không tạo được thư mục dữ liệu dưới $WORKDIR"
}

if [[ $mode == setup ]]; then
  if already_setup; then
    if (( opt_force )); then
      # --force = ĐỔI cấu hình: xoá pair cũ hẳn để pair lại thật (cấp key mới),
      # không giữ lại conf cũ khiến guard thứ hai trong central.sh bỏ qua.
      rm -f -- "$WORKDIR/conf/central.conf"
    else
      # Guard phải hỏi server, không chỉ tin conf local: /unlink trên bot không
      # có kênh báo về máy. Key còn sống (hoặc không kiểm tra được) -> giữ hành
      # vi cũ; server từ chối (401) -> ghép nối lại ngay thay vì chặn người dùng.
      bash "$WORKDIR/engine/central.sh" is-alive
      alive=$?
      if (( alive != 1 )); then
        report_already_setup
        exit 0
      fi
      printf '\n⚠️  API key hiện tại đã bị server từ chối (dự án đã /unlink trên bot?)\n'
      printf ' — tiến hành ghép nối lại cho dự án %s...\n' "$opt_project"
    fi
  fi
  apply_project "$opt_project"
fi

# Các mode khác cần path hợp lệ; setup đã init ở trên.
if [[ $mode != setup ]]; then
  p2s_device_init || die "không tạo được thư mục dữ liệu dưới $WORKDIR"
fi

# jq là tuỳ chọn: rule pack đọc bằng lib/jsonl.awk nên thiếu jq vẫn phát hiện
# bình thường. Ở đây chỉ cố cài thêm nếu host cho phép — không chặn lượt chạy.
case $mode in
  setup|once|run|retro) p2s_want_jq ;;
esac

case $mode in
  setup)
    # 1) pair (idempotent; TỰ ghép nối lại khi key cũ đã bị server thu hồi)
    bash "$WORKDIR/engine/central.sh" pair \
      --server "$opt_server" --chatid "$opt_chatid" || exit $?

    # 1b) agent cũ (nếu có) còn giữ API key cũ trong bộ nhớ — kick để
    # supervisor respawn nó với conf mới trong ≤AGENT_CHECK giây
    bash "$WORKDIR/engine/supervisor.sh" kick-agent >/dev/null 2>&1 || true

    # 2) start the supervisor; it spawns the forwarder itself. Output is shown
    #    only on failure — the pid line is not operator-facing.
    sup_out=$(bash "$WORKDIR/engine/supervisor.sh" start 2>&1) || {
      printf '%s\n' "$sup_out" >&2
      exit 1
    }

    # 3) summary — operator-facing only, no server or chat details
    cat <<EOF

✅ GHÉP NỐI THÀNH CÔNG

 Dự án     :  $PROJECT
 Thiết bị   :  $DEVICE

 Kiểm tra trạng thái:   sudo php2shell-monitor.sh status
EOF
    ;;
  once)
    bash "$WORKDIR/engine/scan.sh"
    ;;
  run)
    bash "$WORKDIR/engine/supervisor.sh" start
    ;;
  test)
    bash "$WORKDIR/engine/central.sh" test
    ;;
  status)
    bash "$WORKDIR/engine/status.sh"
    ;;
  stop)
    bash "$WORKDIR/engine/supervisor.sh" stop
    ;;
  discover)
    bash "$WORKDIR/discovery/discovery.sh" "${positional[0]:-}"
    ;;
  retro)
    bash "$WORKDIR/discovery/retro_hunt.sh" "${positional[0]:-}"
    ;;
  export)
    bash "$WORKDIR/export/export_json.sh"
    echo "export written to $P2S_EXPORT_DIR"
    ;;
  clean)
    bash "$WORKDIR/engine/supervisor.sh" stop 2>/dev/null
    rm -rf -- "$WORKDIR"
    echo "workdir removed: $WORKDIR"
    ;;
  *)
    echo "unknown mode: $mode" >&2
    usage
    exit 2
    ;;
esac
