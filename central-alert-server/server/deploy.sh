#!/usr/bin/env bash
# deploy.sh — vận hành Central Security Alert Server (Docker) với data mount ra host.
#
#   ./deploy.sh up        build + start (idempotent)
#   ./deploy.sh down      stop + remove container (GIỮ data trên host)
#   ./deploy.sh restart   restart nhanh (không rebuild)
#   ./deploy.sh rebuild   rebuild image rồi recreate container
#   ./deploy.sh logs      tail log container
#   ./deploy.sh status    trạng thái + healthz + thống kê nhanh
#   ./deploy.sh backup    dump DB + tar evidence vào backups/
#   ./deploy.sh pair      in hướng dẫn ghép nối Telegram cho server mới
#
# Biến môi trường: DATA_DIR (mặc định /home/gaban/Downloads/php2shell-wrap/data-server)
set -euo pipefail

SRV_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DATA_DIR=${DATA_DIR:-/home/gaban/Downloads/php2shell-wrap/data-server}
ENV_FILE=$SRV_DIR/.env
BASE=http://127.0.0.1:8000

die() { printf 'lỗi: %s\n' "$*" >&2; exit 1; }

need_env() {
  [[ -f $ENV_FILE ]] || die "thiếu $ENV_FILE — copy .env.example rồi điền ALERT_BOT_TOKEN"
  grep -q '^ALERT_BOT_TOKEN=.\+' "$ENV_FILE" || die "ALERT_BOT_TOKEN trống trong $ENV_FILE"
}

read_tok() { grep -oP "^$1=\K.*" "$ENV_FILE" 2>/dev/null | head -1; }

cmd_up() {
  need_env
  mkdir -p "$DATA_DIR"
  docker compose -f "$SRV_DIR/docker-compose.yml" up -d --build
  wait_healthy
  cmd_status
}

wait_healthy() {
  for _ in $(seq 1 40); do
    if curl -fsS --max-time 2 "$BASE/api/v1/healthz" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  docker compose -f "$SRV_DIR/docker-compose.yml" logs --tail 40 || true
  die "server không lên healthy sau 40s"
}

cmd_down() {
  docker compose -f "$SRV_DIR/docker-compose.yml" down
  printf 'data vẫn còn tại %s\n' "$DATA_DIR"
}

cmd_restart() {
  docker compose -f "$SRV_DIR/docker-compose.yml" restart
  wait_healthy
}

cmd_rebuild() {
  need_env
  docker compose -f "$SRV_DIR/docker-compose.yml" build --pull
  docker compose -f "$SRV_DIR/docker-compose.yml" up -d --force-recreate
  wait_healthy
  cmd_status
}

cmd_logs() { docker compose -f "$SRV_DIR/docker-compose.yml" logs -f --tail 100; }

cmd_status() {
  docker compose -f "$SRV_DIR/docker-compose.yml" ps
  printf '\n-- healthz --\n'
  curl -s "$BASE/api/v1/healthz" || true; printf '\n'
  local rt; rt=$(read_tok ALERT_READ_TOKEN)
  if [[ -n $rt ]]; then
    printf -- '-- devices --\n'
    curl -s -H "X-Read-Token: $rt" "$BASE/api/v1/devices" | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
if not devices:
    print("  chưa có device nào")
for x in devices:
    print("  %s/%s: %d alert, %d hit, cuối %s" % (
        x["project_name"], x["device_name"], x["alerts"], x["hits"],
        x["last_severity"] or "-"))
' 2>/dev/null || true
  fi
  printf -- '-- data trên host --\n'
  du -sh "$DATA_DIR" 2>/dev/null || echo "  (chưa có dữ liệu)"
  if [[ -d $DATA_DIR/evidence ]]; then
    find "$DATA_DIR/evidence" -name '*.jsonl' | wc -l | sed 's/^/  evidence file: /'
  else
    printf '  evidence file: 0\n'
  fi
  return 0
}

cmd_backup() {
  local ts out; ts=$(date +%Y%m%dT%H%M%S); out=$SRV_DIR/backups; mkdir -p "$out"
  if [[ -f $DATA_DIR/alerts.db ]]; then
    sqlite3 "$DATA_DIR/alerts.db" ".backup '$out/alerts-$ts.db'" 2>/dev/null \
      || cp "$DATA_DIR/alerts.db" "$out/alerts-$ts.db"
  fi
  tar czf "$out/evidence-$ts.tgz" -C "$DATA_DIR" evidence 2>/dev/null || true
  printf 'backup: %s\n' "$out"
  ls -lh "$out" | tail -5
}

cmd_pair() {
  # tên dự án BẮT BUỘC — hostname là danh tính thiết bị, không phải tên dự án
  local name=${1:-}
  [[ -n $name ]] || die "thiếu tên dự án: ./deploy.sh pair <tên-dự-án>"
  printf 'Ghép nối dự án "%s" với bot Telegram:\n\n' "$name"
  printf '  1. Mở bot, nhấn /id để lấy Chat ID của chat (riêng hoặc group):\n'
  printf '       https://t.me/lenp2shell_bot\n\n'
  printf '  2. Trên server cần monitor (cả 3 tham số BẮT BUỘC):\n'
  printf '       cd central-alert-server/client\n'
  printf '       sudo ./p2s-agent.sh --server http://<IP_HOST>:8000 --project %q --chatid <chat-id>\n\n' "$name"
  printf '     Ghép nối TỰ ĐỘNG, không cần xác nhận.\n'
  printf '     Thiết bị = hostname của máy chạy agent (tự gửi kèm, không phải tham số).\n\n'
  printf '  3. Kiểm tra rồi bật agent thường trực:\n'
  printf '       sudo ./p2s-agent.sh test\n'
  printf '       sudo systemctl enable --now p2s-agent\n'
}

case ${1:-} in
  up)      cmd_up ;;
  down)    cmd_down ;;
  restart) cmd_restart ;;
  rebuild) cmd_rebuild ;;
  logs)    cmd_logs ;;
  status)  cmd_status ;;
  backup)  cmd_backup ;;
  pair)    shift; cmd_pair "$@" ;;
  *) sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
