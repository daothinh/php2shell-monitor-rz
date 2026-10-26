#!/usr/bin/env bash
# bootstrap.sh - makeself startup script. Finishes the install in place.
# Invariants: root required; only the install directory is written; code is
# replaced on upgrade while conf/ and projects/ are preserved.
set -u

die() { printf 'php2shell-monitor: %s\n' "$*" >&2; exit 1; }

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  die "root is REQUIRED (run with sudo). Aborting, nothing was written."
fi

# The install directory is where the payload was unpacked. Deriving it from our
# own path keeps the tarball fallback (untar anywhere) working, while the
# self-extracting archive always lands in /opt/php2shell-monitor.
WORKDIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) ||
  die "cannot resolve install directory"
[[ -d $WORKDIR && ! -L $WORKDIR ]] || die "$WORKDIR is not a real directory"
[[ -f $WORKDIR/main.sh && -d $WORKDIR/engine ]] || die "$WORKDIR does not look like a payload"
export WORKDIR

# Data directories live under the install dir as well; they survive upgrades
# because they are not part of the payload.
for d in conf projects reports run tmp; do
  if [[ -e "$WORKDIR/$d" && ! -d "$WORKDIR/$d" ]]; then
    die "$WORKDIR/$d is not a directory. Aborting."
  fi
  [[ -d "$WORKDIR/$d" ]] || (umask 077 && mkdir -p -- "$WORKDIR/$d") || die "cannot create $WORKDIR/$d"
done

# First install only: seed conf/ from the shipped templates. Existing files are
# never touched, so operator edits survive every upgrade.
for f in "$WORKDIR"/conf.default/*.conf; do
  [[ -f $f ]] || continue
  b=$(basename -- "$f")
  [[ -e "$WORKDIR/conf/$b" ]] || (umask 077 && cp -a -- "$f" "$WORKDIR/conf/$b") ||
    die "cannot seed conf/$b"
done
[[ -d "$WORKDIR/conf/rules.d" ]] || (umask 077 && mkdir -p -- "$WORKDIR/conf/rules.d")

# Dừng mọi tiến trình của bản cài CŨ trước khi thay code.
#
# makeself giải nén đè lên thư mục cài nhưng không đụng tới process đang chạy.
# Supervisor/agent cũ sống tiếp với cwd trỏ vào inode đã bị xoá
# ("/opt/php2shell-monitor (deleted)"): chúng vẫn quay vòng batch, vẫn ghi alert
# và vẫn forward lên server bằng CODE CŨ, song song với bản mới. Trên lab đã thấy
# đúng 2 cặp supervisor+agent cùng chạy, và các batch do bản cũ sinh ra không hề
# xuất hiện trong log của bản mới — nhìn bên ngoài chỉ thấy severity nhảy lộn xộn.
# Chúng còn giữ flock trên inode đã xoá, nên lock của bản mới không hề chặn được.
p2s_kill_stale() {
  local pid cmd _pat
  # Pattern phải khớp ĐƯỜNG DẪN THẬT: "engine/supervisor.sh", không phải
  # "engine.sh". pgrep -f chạy ERE trên toàn cmdline.
  _pat="$WORKDIR/(engine|plugins|discovery)/[a-z_]+\.sh|$WORKDIR/main\.sh"
  for pid in $(pgrep -f "$_pat" 2>/dev/null); do
    [[ $pid == "$$" ]] && continue
    # 2>/dev/null phải đứng TRƯỚC "<": shell mở redirection input trước khi áp
    # redirection stderr cho lệnh, nên "<file" hỏng vẫn in lỗi ra terminal dù
    # phía sau có 2>/dev/null. pgrep và /proc không nguyên tử: process chết
    # giữa hai bước là chuyện thường (respawn, batch timeout), và mỗi lần như
    # vậy lại rò một dòng "/proc/NNN/cmdline: No such file or directory".
    cmd=$(tr '\0' ' ' 2>/dev/null <"/proc/$pid/cmdline") || continue
    # chỉ kill process thuộc bản cài này, không đụng process khác trên host
    [[ $cmd == *"$WORKDIR"* ]] || continue
    kill -TERM "$pid" 2>/dev/null || continue
  done
  # cho chúng thoát êm, rồi cưỡng bức nếu còn cứng đầu
  local _wait
  for _wait in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "$_pat" >/dev/null 2>&1 || break
    sleep 0.3
  done
  for pid in $(pgrep -f "$_pat" 2>/dev/null); do
    [[ $pid == "$$" ]] && continue
    cmd=$(tr '\0' ' ' 2>/dev/null <"/proc/$pid/cmdline") || continue
    [[ $cmd == *"$WORKDIR"* ]] || continue
    kill -KILL "$pid" 2>/dev/null
  done
  return 0
}
p2s_kill_stale

# Upgrade: the payload is unpacked over the previous install, so files that the
# new version dropped would linger and keep running. MANIFEST lists everything
# the build shipped; delete anything else under the CODE trees. conf/ and
# projects/ are operator data, and export/ holds the exported alerts, so none of
# them is ever pruned.
#
# LC_ALL=C phải áp cho CẢ sort VÀ comm. Trước đây chỉ sort có LC_ALL=C còn comm
# chạy theo locale của máy: hai bên sắp xếp khác nhau ("lib/json.sh" đứng trước
# "lib/jsonl.awk" ở C, nhưng sau ở en_US.UTF-8), comm thấy input "not in sorted
# order" rồi trả về danh sách rác. Hậu quả: bootstrap xoá gần hết code vừa giải
# nén và main.sh chết với "No such file or directory". Toàn bộ khối này chạy
# trong một subshell có LC_ALL=C nên không thể lệch lại lần nữa.
if [[ -s $WORKDIR/MANIFEST ]]; then
  (
    LC_ALL=C
    export LC_ALL
    cd -- "$WORKDIR" || exit 1
    find lib engine plugins rules discovery third_party conf.default \
      -type f 2>/dev/null | LC_ALL=C sort >.present
    LC_ALL=C sort MANIFEST >.manifest

    # Chốt chặn: MANIFEST phải là superset của những gì đang có. Nếu không,
    # phép trừ là vô nghĩa (comm lỗi thứ tự, MANIFEST hỏng, payload thiếu) và
    # xoá tiếp sẽ phá bản cài. Bỏ qua việc prune còn hơn để lại file cũ.
    if ! LC_ALL=C comm -13 .present .manifest >/dev/null 2>&1; then
      rm -f -- .present .manifest
      exit 0
    fi
    LC_ALL=C comm -23 .present .manifest >.stale 2>/dev/null || : >.stale

    # Lưới an toàn cuối: danh sách "cần xoá" không được vượt quá nửa số file
    # đang có. Vượt ngưỡng đó gần như chắc chắn là lỗi tính toán, không phải
    # một bản nâng cấp bình thường.
    n_present=$(wc -l <.present)
    n_stale=$(wc -l <.stale)
    if (( n_present > 0 && n_stale * 2 > n_present )); then
      rm -f -- .present .manifest .stale
      exit 0
    fi

    while IFS= read -r rel; do
      [[ -n $rel ]] || continue
      case $rel in
        /*|*..*) continue ;;   # không bao giờ xoá ngoài WORKDIR
      esac
      rm -f -- "$WORKDIR/$rel"
    done <.stale
    rm -f -- .present .manifest .stale
  )
fi

# Everything below the install dir holds raw log lines (IPs, URIs, request
# bodies): root-only, no world access. The payload keeps the build machine's
# ownership through tar, so ownership is forced here: a non-root owner could
# edit code that root later executes.
chown -R -- root:root "$WORKDIR" 2>/dev/null || die "cannot chown $WORKDIR to root"
find "$WORKDIR" -xdev -type d -exec chmod 0700 {} + 2>/dev/null
find "$WORKDIR" -xdev -type f -exec chmod 0600 {} + 2>/dev/null
find "$WORKDIR" -xdev -name '*.sh' -exec chmod 0700 {} + 2>/dev/null
find "$WORKDIR" -xdev -name '*.awk' -exec chmod 0600 {} + 2>/dev/null

cd -- "$WORKDIR" || die "cannot cd into $WORKDIR"
exec bash ./main.sh "$@"
