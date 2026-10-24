#!/usr/bin/env bash
# monitor.sh — php2shell-monitor chạy TRỰC TIẾP trên host (VPS), đọc LOG CHUẨN:
#   nginx : /var/log/nginx/php2shell-lab.{access,error}.log
#   fpm   : /var/log/php<ver>-fpm/{fpm,www-error}.log
#   webroot: /var/www/php2shell-lab  (webshell drop hiện thật tại đây)
# Workdir : /var/lib/php2shell-monitor (queue alert: alerts/queue.jsonl)
# Agent   : đẩy alert về central server (mặc định localhost:8000) -> Telegram.
#
# Chạy trên VPS với root:
#   bash monitor.sh start [--conf /etc/php2shell/agent.conf] [--interval 10]
#   bash monitor.sh stop
#   bash monitor.sh status
set -u
CONF=/etc/php2shell/agent.conf
INTERVAL=10
W=/var/lib/php2shell-monitor
PIDFILE=$W/monitor.pid
LOGPIDFILE=$W/agent.pid
SRC=/opt/alert-central/../php2shell-monitor/src   # sẽ fallback về rsync src nếu thiếu
SRC=${P2S_SRC:-/opt/php2shell-monitor-src}

sub=${1:-}; shift || true
while [[ $# -gt 0 ]]; do
  case $1 in
    --conf) CONF=${2:?}; shift 2 ;;
    --interval) INTERVAL=${2:?}; shift 2 ;;
    *) echo "tham số lạ: $1" >&2; exit 2 ;;
  esac
done

PHPV=$(ls -d /var/log/php*-fpm 2>/dev/null | head -1 | grep -oP 'php\K[0-9.]+(?=-fpm)')
PHPV=${PHPV:-8.2}
FPMLOGS="/var/log/php${PHPV}-fpm/fpm.log /var/log/php${PHPV}-fpm/www-error.log /var/log/php${PHPV}-fpm.log"

deploy() {
  [[ -d $W/engine ]] && return 0   # chỉ deploy lần đầu — giữ state/manifest nguyên vẹn
  [[ -d $SRC/engine ]] || { echo "không thấy engine src tại $SRC (đặt P2S_SRC=...)" >&2; exit 2; }
  mkdir -p "$W"
  cp -a "$SRC/." "$W/"
  sed -i "s|^WORKDIR=.*|WORKDIR=$W|" "$W/conf/default.conf"
  mkdir -p "$W"/{alerts,export,reports,run,tmp,state/agg}
  touch "$W/alerts/queue.jsonl" /var/log/nginx/php2shell-lab.access.log \
        /var/log/nginx/php2shell-lab.error.log
  # manifest học webroot hiện có -> chỉ file MỚI (webshell) mới báo
  { printf '# path\tsize\tmtime\towner\n'
    find /var/www/php2shell-lab -xdev -type f \
      \( -name '*.php' -o -name '*.phtml' -o -name '*.phar' -o -name '*.php5' \
         -o -name '*.inc' -o -name '.user.ini' -o -name '.htaccess' -o -name '*.sh' \) \
      -printf '%p\t%s\t%T@\t%U\n' 2>/dev/null
  } >"$W/state/webroot.manifest.tsv"
}

_running() { [[ -f $PIDFILE ]] && kill -0 "$(cat $PIDFILE)" 2>/dev/null; }

loop() {
  echo "== monitor host: batch mỗi ${INTERVAL}s — log php-fpm $PHPV =="
  while true; do
    WORKDIR=$W \
    NGINX_ACCESS=/var/log/nginx/php2shell-lab.access.log \
    NGINX_ERROR=/var/log/nginx/php2shell-lab.error.log \
    FPM_LOG="$FPMLOGS" \
    APACHE_ACCESS=/nonexistent APACHE_ERROR=/nonexistent \
    WEBROOTS=/var/www/php2shell-lab \
    SESSION_DIRS=/var/lib/php/sessions AUDIT_LOG=/nonexistent PROC_SCAN=1 \
      bash "$W/engine/scan.sh" >>"$W/scan.log" 2>&1
    printf '[%s] queue: %d alert\n' "$(date +%H:%M:%S)" "$(wc -l <"$W/alerts/queue.jsonl")"
    sleep "$INTERVAL"
  done
}

case $sub in
  start)
    _running && { echo "đang chạy (pid $(cat $PIDFILE))"; exit 0; }
    deploy
    # agent: queue -> central server -> Telegram
    if [[ -r $CONF ]]; then
      ( while true; do
          P2S_AGENT_CONF=$CONF P2S_AGENT_STATE=$W/agent-state \
          P2S_ALERT_FILE=$W/alerts/queue.jsonl P2S_AGENT_POLL=3 \
            bash /usr/local/bin/p2s-agent.sh run >>"$W/agent.log" 2>&1
          sleep 5   # agent chết (vd mất mạng dài) -> tự sống lại
        done ) &
      echo $! >"$LOGPIDFILE"
      echo "agent pid $(cat $LOGPIDFILE) (conf $CONF)"
    else
      echo "chưa có conf agent ($CONF) — chạy p2s-agent.sh pair trước; monitor vẫn quét."
    fi
    ( loop ) >>"$W/monitor.log" 2>&1 &
    echo $! >"$PIDFILE"
    echo "monitor pid $(cat $PIDFILE) — log: $W/monitor.log | alert queue: $W/alerts/queue.jsonl"
    ;;
  stop)
    for f in "$PIDFILE" "$LOGPIDFILE"; do
      [[ -f $f ]] && { kill "$(cat $f)" 2>/dev/null; rm -f "$f"; }
    done
    pkill -f "$W/engine/scan.sh" 2>/dev/null
    echo "đã dừng"
    ;;
  status)
    _running && echo "monitor: chạy (pid $(cat $PIDFILE))" || echo "monitor: dừng"
    [[ -f $LOGPIDFILE ]] && kill -0 "$(cat $LOGPIDFILE)" 2>/dev/null \
      && echo "agent: chạy (pid $(cat $LOGPIDFILE))" || echo "agent: dừng"
    echo "queue: $(wc -l <"$W/alerts/queue.jsonl" 2>/dev/null || echo 0) alert"
    ;;
  *) echo "usage: monitor.sh start|stop|status [--conf ...] [--interval N]"; exit 2 ;;
esac
