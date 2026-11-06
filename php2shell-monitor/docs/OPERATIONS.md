# OPERATIONS

Vận hành php2shell-monitor trên một host.

## 1. Cài / nâng cấp

```bash
sudo bash php2shell-monitor.sh -- discover   # map log, patch status
sudo bash php2shell-monitor.sh -- once       # 1 batch thử
sudo bash php2shell-monitor.sh -- run        # supervisor
sudo bash php2shell-monitor.sh -- status
```

Archive giải nén trực tiếp vào `/opt/php2shell-monitor`; sau đó mọi lệnh đều
chạy được từ thư mục đó (`sudo bash /opt/php2shell-monitor/main.sh -- status`).

`conf/` và `projects/` được giữ nguyên khi nâng cấp; code trong
`lib/ engine/ plugins/ rules/ discovery/ export/` bị ghi đè, file không còn
trong `MANIFEST` bị xoá. Không tạo cron/systemd/file ngoài thư mục này.

## 2. Nhịp chạy

`BATCH_INTERVAL=300` (5 phút). Mỗi batch:

1. plugin đọc phần log mới từ offset đã lưu (`state/offsets.tsv`, theo inode + byte + số dòng);
2. rule pack khớp trên từng field;
3. **tối đa một alert** — severity: có `impact=rce` thì CRITICAL (một event cũng
   đủ), còn lại theo số lượng (`>= CRIT_THRESHOLD` là MODERATE), kèm mọi dòng
   log gốc;
4. lưu offset, ghi `run/batches.log`.

**Alert là cảnh báo HÀNH VI, không phải báo cáo trạng thái.** Điều kiện đứng
yên (webshell đã nằm trên đĩa, file đã bị sửa) không sinh thêm tin mỗi batch;
khi điều kiện biến mất cũng không gửi tin "đã hết". Một sự cố = một tin.

Không có batch nào bị bỏ: nếu một batch đang chạy, batch sau thấy lock và thoát
(`scan already running; batch skipped`) — batch kế tiếp đọc bù phần log còn lại.

## 3. Đọc kết quả

```bash
D=/opt/php2shell-monitor/projects/<project>/devices/<device>

tail -5  "$D/run/batches.log"                 # mọi batch, kể cả no-hits
tail -1  "$D/alerts/queue.jsonl" | jq .       # alert gần nhất (đầy đủ)
ls -t    "$D/evidence" | head                 # evidence theo batch
```

Một alert:

```json
{
  "ts_utc": "...", "batch_id": "20261024T000500Z",
  "project": "khach-hang-a", "device": "web01",
  "severity": "CRITICAL", "hits": 8,
  "rules": [{"rule_id":"P2S-010","hits":5},{"rule_id":"P2S-020","hits":1}],
  "evidence_file": ".../evidence/20261024T000500Z.jsonl",
  "evidence": [
    {"rule_id":"P2S-020","file":"/var/www/shell.php","line":0,"raw":"webroot file NEW: ..."},
    {"rule_id":"P2S-030","file":"/var/log/nginx/access.log","line":42,
     "raw":"203.0.113.42 - - ... \"GET /sh.php?cmd=whoami\""}
  ]
}
```

Mở đúng dòng log:

```bash
tail -1 "$D/alerts/queue.jsonl" | jq -r '.evidence[] | "\(.file):\(.line)"' |
while IFS=: read -r f l; do [ "$l" -gt 0 ] && sed -n "${l}p" "$f"; done
```

## 4. Tuning

| Việc | Cách |
|---|---|
| Tắt một rule | `conf/rules.d/*.jsonl`: `{"id":"P2S-016","enabled":false}` |
| Đổi ngưỡng | lặp lại rule với `"min": N` (số hit tối thiểu trong batch) |
| Bỏ nhiễu | `conf/whitelist.conf`, 1 PCRE/dòng, áp lên cả record |
| Tắt plugin | `PLUGINS_DISABLED="docker_logs sessions"` |
| Giới hạn inline | `MAX_EVIDENCE_INLINE=100` (file evidence vẫn đủ) |
| Giữ evidence bao lâu | `EVIDENCE_KEEP=2016` (số batch ≈ 7 ngày ở 300s) |

### Log Docker (plugin `docker_logs`)

Script chạy sudo nên plugin đọc **thẳng** file json log của mọi container dưới
`/var/lib/docker/containers/*/` (đổi qua biến `DOCKER_LOG_DIR`) — offset-tracked
như access log, không quét lại dòng cũ giữa các batch. Thư mục đó không đọc
được thì tự chuyển sang `docker logs --timestamps` với **con trỏ bền** theo
container (`state/docker_cursors.tsv` lưu timestamp + số thứ tự cuối): dòng đã
đưa lên ở batch trước không được đẩy lại, và `file:line` không đếm lại từ 1.
`DOCKER_LOG_SINCE` chỉ còn là cửa sổ của lượt QUÉT ĐẦU TIÊN (chưa có con trỏ).

#### Vì sao dùng `lib/dockerlog.awk`

Bản trước bung từng dòng bằng `sed` rồi lọc bằng `grep -qP`: **2 fork mỗi
dòng ≈ 2.4 ms**. Hai container 76 MB (1.216.130 dòng) mất **49 phút**, vượt
`PLUGIN_TIMEOUT=120` nên plugin bị kill mỗi batch. Tệ hơn, offset chỉ được ghi
sau khi đọc hết chunk, nên bị kill là mất sạch tiến độ và batch sau đọc lại
từ byte 0 — log lớn không bao giờ quét xong dù phần host vẫn bình thường.

Nay toàn bộ việc bóc JSON + nhận dạng access-log + lọc marker chạy trong
**một process awk**. Đo lại trên cùng dữ liệu: 615k dòng hết **10 s**, hai
container hết **21 s**.

Thêm nữa, awk ghi mốc tiến độ mỗi `BATCH_CHECKPOINT_LINES` dòng (mặc định
2000) ra file tạm; nếu plugin bị `PLUGIN_TIMEOUT` cắt giữa chừng, trap EXIT
đọc mốc đó vào state nên phần đã quét không mất trắng. Batch sau tiếp tục
đúng dòng, không trùng không sót.

Hai loại dòng ra khỏi container:

- dòng **access-log** → phát dưới nguồn `access_log` với đủ field
  ip/method/uri/status/ua nên toàn bộ rule tấn công (P2S-008/015/016/017/030/
  050–058) phủ cả app chạy trong container. Nhận **cả hai** định dạng: combined
  đầy đủ (`IP - - [ts] "GET /x HTTP/1.1" 200 12 "-" "ua"`) và dạng nginx ngắn
  không có referer/ua (`IP -  dd/Mon/yyyy:hh:mm:ss +zzzz "GET /x" 200`) — dạng
  sau là thứ container lab thực tế ghi ra, và regex combined cũ bỏ sót 100%;
- dòng còn lại chỉ phát khi có marker crash/OOM (P2S-010/011/014/018) hoặc
  marker tấn công php2shell/upload-progress (P2S-041) → nguồn `docker`, file
  hiển thị `docker:<tên-container>`.

Nếu log container tăng rất nhanh (ứng dụng ghi hàng trăm MB mỗi ngày), cân
nhắc bật log rotation của Docker (`max-size`/`max-file`) — plugin đọc được cả
file đã rotate, nhưng file quá lớn làm lượt quét đầu chậm.

Rule bị loại vì `min` xuất hiện trong `run/batches.log`:
`suppressed  P2S-016  4 hit(s) < min 5`.

### Monitor ứng dụng chạy TRONG container (plugin `container_accesslog`)

Một install trên host phải monitor cả host lẫn container chạy trên host đó.
Đây là plugin làm việc đó, và nó **bắt buộc phải có**: `docker_logs` một mình
là mù với CVE-2026-109618/109619.

#### Vì sao `docker_logs` không đủ

Mỗi container ghi access log **hai nơi**, nội dung khác nhau:

| Nguồn | Ví dụ | Query string |
|---|---|---|
| `docker_logs` đọc: stderr → `*-json.log` | `127.0.0.1 -  26/Oct/2026:07:47:47 +0000 "GET /vuln.php" 200` | **mất** |
| `container_accesslog` đọc: `/var/log/nginx/access.log` trong container | `192.168.0.1 - - [26/Oct/2026:07:47:15 +0000] "GET /vuln.php?page=/var/lib/php/sessions/sess_p2s7d73... HTTP/1.1" 200 410 ... request_length=138` | **có** |

PHP-FPM ghi access log theo `access.format` không có `%Q%q` (`%r` chỉ có
path), nên query string biến mất trước khi tới json log. Thực đo trên lab:

```
json log   :       0 dòng chứa 'page='
access.log : 635.840 dòng chứa 'page='
```

Toàn bộ CVE nằm trong query string (`?page=/var/lib/php/sessions/sess_...`,
upload progress 15 MB), nên chỉ đọc json log thì **container bị RCE liên tục
mà không có alert nào** — đúng sự cố đã gặp.

#### Cách đi vào container mà không cần docker CLI/socket

Mỗi container có PID process chính trong `config.v2.json` (`State.Pid`).
`/proc/<pid>/root` trỏ vào root filesystem của container và đọc được từ host
khi có root — **độc lập storage driver** (overlay2, overlayfs, btrfs, zfs,
vfs). Inode qua đường này trùng khớp với qua overlayfs mount, nên offset
tracking vẫn đúng.

Plugin cũng tự dò thêm `$DOCKER_LOG_DIR/rootfs/overlayfs/<cid>/` và
`overlay2/<cid>/merged/` làm dự phòng.

#### Khoá offset ổn định qua restart

Offset và manifest khoá theo **`container:<cid>/<relpath>`**, KHÔNG theo
`/proc/<pid>/root/...`. Container restart thì PID đổi, đường dẫn `/proc` cũ
biến mất — khoá theo đường dẫn sẽ khiến lần chạy sau đọc lại từ byte 0 và
manifest coi toàn bộ webroot là "file NEW". CID thì ổn định suốt vòng đời
container.

Alert hiển thị `container:<tên>:/var/www/html/s.php` để người đọc biết ngay
container nào và đường dẫn nào bên trong nó.

#### Nhiều container trên một host

Mỗi container một dòng offset riêng, một mục manifest riêng; plugin không giữ
state chung nên số container không ảnh hưởng lẫn nhau. Đã kiểm với 2 container
chạy song song: mỗi cái có offset riêng, alert ghi đúng `container:php2shell-
lab-1` / `container:php2shell-lab-2`.

`CONTAINER_READ_CAP_BYTES` (mặc định 16 MiB) chặn trần đọc mỗi file mỗi lượt:
container chạy lâu có thể có access log 100+ MB, đọc hết một lượt thì vượt
`PLUGIN_TIMEOUT`. Cắt theo trần rồi các batch sau đọc tiếp — không mất dòng
nào, chỉ trải ra nhiều batch.

#### Webroot trong container

`webroot_manifest` quét thêm webroot **bên trong** từng container, nên webshell
đã drop vào container cũng bị thấy. Trước đây plugin chỉ quét `/var/www/html`
trên host — host không có thư mục đó khi ứng dụng chạy trong container, nên
`s.php` (`system($_REQUEST[0])`) nằm im trong `php2shell-lab-1` mà không ai báo.

Chỉ quét thư mục **nông nhất** còn tồn tại (`/var/www/html` bao `/var/www`),
nếu không mỗi file sẽ vào manifest hai lần và mỗi webshell bị báo hai lần.

#### Khi /proc bị chặn hoặc muốn quét snapshot offline

Đặt `P2S_CONTAINER_ROOTFS_MAP` trỏ tới file TSV:

```
<cid>	<tên>	<đường dẫn rootfs>
```

Plugin dùng danh sách này thay cho việc dò `config.v2.json` + `/proc`. Hữu ích
khi host hardening (`hidepid=2`), container PID namespace, hoặc khi cần quét
bản backup rootfs đã copy ra ngoài.

## 5. Trạng thái

`-- status` in: supervisor, project/device, thư mục dữ liệu, plugin lần cuối,
capabilities, 5 batch gần nhất, alert cuối.

Capabilities (`state/capabilities.txt`) do `-- discover` ghi; rule có `needs[]`
chỉ chạy khi capability tương ứng tồn tại.

## 6. Sự cố thường gặp

| Hiện tượng | Nguyên nhân | Xử lý |
|---|---|---|
| `no-hits` liên tục nhưng log có tấn công | log không nằm ở đường dẫn mặc định | đặt `NGINX_ACCESS`/`FPM_LOG` trong `conf/default.conf`, chạy `-- once` |
| Không thấy alert T2 | thiếu quyền đọc log FPM | chạy bằng root hoặc thêm user vào group đọc log |
| Alert lặp cùng nội dung mỗi batch | offset không lưu được (workdir chỉ đọc) | kiểm tra quyền ghi `projects/<p>/devices/<d>/state` |
| Tin Telegram hiện `Nguồn: kernel` thay vì `Path:` | máy không có file journal đọc được (`/var/log/journal/<id>/system.journal`) | `journalctl --file /var/log/journal/*/system.journal -k -n 1`; xem mục `health` của `status` |
| `Path:` trỏ file không tồn tại | monitor cũ gửi chuỗi mô tả vào field `file` | nâng cấp monitor ≥ 1.4.13; server tự bỏ nhãn Path cho giá trị không phải đường dẫn |
| Webshell có trên đĩa nhưng chỉ báo 1 lần rồi im | đúng thiết kế: không có hành vi mới thì không có tin mới | xem `state/webroot.shells.tsv` để biết shell nào đã báo |
| `supervisor failed to start` | lock còn hoặc thiếu quyền | xem `run/supervisor.log` |
| Một plugin `rc=124` mỗi batch | bị `PLUGIN_TIMEOUT` cắt: một nguồn chậm/không bao giờ EOF giữ cả plugin | `status` mục `health`; `plugins.err` có dòng `readcap: timeout` hoặc `-> /dev/stdout` |
| `health` báo `da bao` cho `plugin/x` | monitor tự mù ≥ `P2S_HEALTH_STRIKES` batch — đã sinh alert P2S-090 | xử lý nguồn trong `plugins.err`, rồi `status` để xác nhận bộ đếm đã về 0 |
| `access.log` container không được đọc | file là symlink `/dev/stdout` (nginx official/alpine) | đúng thiết kế: nội dung thật nằm ở `docker_logs` (`*-json.log`); `health` ghi nhận để không im lặng |
| Log lớn (syslog 269 MB) không bao giờ quét xong | `P2S_READ_CAP_BYTES`/`P2S_READ_JUMP_BYTES` quá lớn so với đĩa | lần đầu vượt `P2S_READ_JUMP_BYTES` sẽ nhảy tới EOF-cap; giảm cap để batch ngắn hơn |
| `readcap: ... bỏ qua phần đầu` | file lớn hơn `P2S_READ_JUMP_BYTES` và chưa có cursor | đúng thiết kế: lịch sử là việc của `retro` (`RETRO_SINCE`) |
| Batch chạy quá lâu | log quá lớn / plugin treo | `PLUGIN_TIMEOUT`, `MAX_EVENTS_PER_BATCH` |

## 7. Bảo mật

- Workdir 0700, file 0600 — chứa IP, URI, dòng log gốc.
- Monitor không gửi gì ra ngoài. Việc gửi là của `p2s-agent.sh` (xem central).
- Kẻ có root trên host đọc được workdir; không có cơ chế chống điều đó.
- Evidence chứa dữ liệu thật của log ⇒ đối xử như dữ liệu nhạy cảm khi copy ra ngoài.
