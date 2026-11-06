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

  CẬP NHẬT bản mới (bắt buộc --force): chạy lại installer với --force. Cài đè
  mà không có --force thì installer giữ nguyên cấu hình cũ và KHÔNG gửi tin xác
  nhận, nên không biết máy đã lên bản mới hay chưa.
    sudo php2shell-monitor.sh --force --project <tên> --chatid <id>

Chế độ khác:
  run        Bật supervisor nền
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

# Nạp conf/default.conf cho các mode chạy trực tiếp từ main.sh (setup, retro,
# run...). scan.sh và retro_hunt.sh tự source file này, nhưng setup thì không —
# thiếu bước này thì mọi tham số vận hành đặt trong conf (P2S_RETRO_TIMEOUT,
# RETRO_SINCE, PLUGINS_DISABLED...) bị bỏ qua âm thầm và
# người vận hành tưởng đã cấu hình được. set -a để biến đi vào tiến trình con.
if [[ -r $P2S_CONF_DIR/default.conf ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$P2S_CONF_DIR/default.conf"
  set +a
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

    # 1b) DỪNG supervisor + agent cũ TRƯỚC khi chạy tiếp.
    #
    # Đây là chỗ từng làm "đổi chat nhận alert" không có tác dụng. Đường dẫn
    # dữ liệu phụ thuộc PROJECT:
    #   projects/<PROJECT>/devices/<DEVICE>/run/supervisor.pid
    # Khi --force đổi project (hoặc chỉ đổi chat mà tên dự án khác), kick-agent
    # tìm pidfile ở thư mục của project MỚI — nó không thấy gì, nên supervisor
    # và agent của project CŨ vẫn sống và tiếp tục gửi alert bằng API key cũ
    # tới chat cũ. Người dùng đổi chat xong vẫn thấy alert về group.
    #
    # Dừng hẳn bằng pidfile cũ (đọc trước khi apply_project ghi conf mới) rồi
    # mới khởi động lại ở bước 2.
    _old_run=''
    if [[ -r $WORKDIR/conf/device.conf ]]; then
      _old_proj=$(sed -n 's/^PROJECT="\(.*\)"$/\1/p' "$WORKDIR/conf/device.conf" | head -1)
      _old_dev=$(sed -n 's/^DEVICE="\(.*\)"$/\1/p' "$WORKDIR/conf/device.conf" | head -1)
      if [[ -n $_old_proj && -n $_old_dev ]]; then
        _old_run="$WORKDIR/projects/$_old_proj/devices/$_old_dev/run"
      fi
      unset _old_proj _old_dev
    fi
    if [[ -n $_old_run && -d $_old_run ]]; then
      for _pf in "$_old_run/supervisor.pid" "$_old_run/agent/agent.pid"; do
        [[ -r $_pf ]] || continue
        _p=$(cat "$_pf" 2>/dev/null)
        [[ $_p =~ ^[0-9]+$ ]] || continue
        # chỉ kill tiến trình đúng là monitor của WORKDIR này (chống PID tái sử dụng)
        _cmd=$(tr '\0' ' ' 2>/dev/null <"/proc/$_p/cmdline") || continue
        [[ $_cmd == *"$WORKDIR"* ]] || continue
        kill -TERM "$_p" 2>/dev/null || true
        printf '  đã dừng tiến trình cũ (pid %s) của dự án trước\n' "$_p"
      done
      unset _pf _p _cmd
      sleep 1
    fi
    unset _old_run
    # agent cũ (nếu có) còn giữ API key cũ trong bộ nhớ — kick để supervisor
    # respawn nó với conf mới trong ≤AGENT_CHECK giây (trường hợp cùng project)
    bash "$WORKDIR/engine/supervisor.sh" kick-agent >/dev/null 2>&1 || true

    # 1c) QUÉT BÙ CHẠY NỀN: retro-hunt (log đã rotate/gzip) + lượt quét đầu tiên
    # trên log hiện có.
    #
    # Vì sao KHÔNG chạy đồng bộ: cài đặt phải trả kết quả ngay — ghép nối
    # server, cấp API key, gửi tin Telegram. Quét log cũ trên máy thật có thể
    # mất vài phút (hàng trăm MB, kể cả .gz), nên bắt operator ngồi chờ trước
    # màn hình chỉ để đọc "chưa xong trong 90s" là vô nghĩa: người dùng không
    # biết được gì thêm, và tệ hơn là tưởng tool chưa chạy.
    #
    # Nền nhưng KHÔNG thả rông: catchup.sh giữ scan.lock suốt cả hai lượt và
    # truyền fd 9 xuống cho retro_hunt.sh/scan.sh. Supervisor bật ở bước 2 thấy
    # lock bận nên bỏ batch đầu, tick kế tiếp chạy sau BATCH_INTERVAL — không
    # có chuyện batch 5 phút chen vào giữa retro và sinh alert thứ hai cho cùng
    # một khoảng thời gian.
    #
    # Cửa sổ retro mặc định = 00:00 UTC hôm nay (= 07:00 giờ VN). Muốn phủ trọn
    # ngày theo giờ VN thì đặt 17:00Z hôm trước; muốn sâu nhiều ngày thì lùi xa:
    #   RETRO_SINCE=2026-11-02T17:00:00Z sudo php2shell-monitor.sh --project ...
    mkdir -p -- "$P2S_DEVICE_RUN_DIR"
    rm -f -- "$P2S_DEVICE_RUN_DIR/catchup.status"
    if [[ -n ${RETRO_SINCE:-} ]]; then
      export RETRO_SINCE
    else
      unset RETRO_SINCE
    fi
    # fd 9 giữ lock NGAY TẠI ĐÂY, trước khi supervisor tồn tại, để không có
    # khoảng trống nào cho batch chen vào. Lock đi theo fd sang tiến trình con
    # (fork xảy ra trước khi installer đóng fd của mình), nên catchup.sh thừa
    # hưởng đúng ổ khoá đó và giữ nó suốt vòng đời — catchup tự kiểm bằng
    # `flock -n 9` chứ không tin một biến môi trường.
    exec 9>"$P2S_DEVICE_RUN_DIR/scan.lock"
    flock -w 5 9 || true
    setsid bash "$WORKDIR/engine/catchup.sh" \
      >>"$P2S_DEVICE_RUN_DIR/catchup.log" 2>&1 </dev/null &
    exec 9>&-

    # 2) start the supervisor; it spawns the forwarder itself. Output is shown
    #    only on failure — the pid line is not operator-facing.
    sup_out=$(bash "$WORKDIR/engine/supervisor.sh" start 2>&1) || {
      printf '%s\n' "$sup_out" >&2
      exit 1
    }

    # 3) summary — operator-facing only, no server or chat details.
    #    Quét bù vẫn đang chạy nền; nói rõ điều đó thay vì để operator đoán,
    #    nhưng không bắt chờ và không hứa một kết quả chưa có.
    cat <<EOF

✅ GHÉP NỐI THÀNH CÔNG

 Dự án     :  $PROJECT
 Thiết bị   :  $DEVICE

 Quét log cũ: chạy nền, không cần chờ.

 Kiểm tra trạng thái:   sudo php2shell-monitor.sh status
EOF
    ;;
  once)
    # ĐÃ BỎ khỏi giao diện: supervisor chạy realtime (batch mỗi 5 phút, cộng
    # lượt quét đầu ngay lúc cài) nên "once" không còn ý nghĩa nghiệp vụ.
    # Giữ nhánh này để script cài đặt cũ của khách gọi vào không chết với
    # "unknown mode" — hành vi y như trước.
    bash "$WORKDIR/engine/scan.sh"
    ;;
  run)
    bash "$WORKDIR/engine/supervisor.sh" start
    ;;
  test)
    # ĐÃ BỎ: alert TEST-001 đi qua đúng khung "CENTRAL SECURITY ALERT" nên
    # người trực ca không phân biệt được với sự cố thật, và mỗi lần bấm lại
    # sinh thêm một tin. Nghiệp vụ giờ là: ngay lúc cài, server gửi thông báo
    # GHÉP NỐI THÀNH CÔNG vào chat — đó mới là minh chứng Telegram hoạt động.
    # Giữ nhánh này để script cũ không chết; nó chỉ in hướng dẫn.
    cat >&2 <<'EOF'
Lệnh "test" đã bỏ.

Minh chứng Telegram hoạt động là tin GHÉP NỐI THÀNH CÔNG mà server gửi vào
chat ngay khi cài. Kiểm tra lại:
  sudo php2shell-monitor.sh status
  (hoặc xem tin nhắn trong chat Telegram của dự án)
EOF
    exit 2
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
