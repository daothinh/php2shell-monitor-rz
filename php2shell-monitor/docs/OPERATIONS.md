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

Hai loại dòng ra khỏi container:

- dòng **access-log combined** (image apache/nginx chính thức ghi access ra
  stdout) → phát dưới nguồn `access_log` với đủ field ip/method/uri/status/ua
  nên toàn bộ rule tấn công (P2S-008/015/016/017/030/050–056) phủ cả app chạy
  trong container;
- dòng còn lại chỉ phát khi có marker crash/OOM (P2S-010/011/014/018) hoặc
  marker tấn công php2shell/upload-progress (P2S-041) → nguồn `docker`, file
  hiển thị `docker:<tên-container>`.

Rule bị loại vì `min` xuất hiện trong `run/batches.log`:
`suppressed  P2S-016  4 hit(s) < min 5`.

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
| `supervisor failed to start` | lock còn hoặc thiếu quyền | xem `run/supervisor.log` |
| Batch chạy quá lâu | log quá lớn / plugin treo | `PLUGIN_TIMEOUT`, `MAX_EVENTS_PER_BATCH` |

## 7. Bảo mật

- Workdir 0700, file 0600 — chứa IP, URI, dòng log gốc.
- Monitor không gửi gì ra ngoài. Việc gửi là của `p2s-agent.sh` (xem central).
- Kẻ có root trên host đọc được workdir; không có cơ chế chống điều đó.
- Evidence chứa dữ liệu thật của log ⇒ đối xử như dữ liệu nhạy cảm khi copy ra ngoài.
