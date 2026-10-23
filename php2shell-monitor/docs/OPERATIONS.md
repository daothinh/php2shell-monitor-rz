# php2shell-monitor — Hướng dẫn triển khai & vận hành

> Bản thực thi của `cook.md` (PLAN v4). Artifact: `dist/php2shell-monitor.sh`
> (makeself, 1 file tự giải nén, kèm `.sha256`).

## 1. Cài đặt / chạy

```bash
sudo bash dist/php2shell-monitor.sh -- <mode>
```

Mode (xem `-- help`):
| Mode | Việc |
|---|---|
| `discover` | Discovery read-only → `reports/log-map-actual.md` + patch status + capabilities |
| `retro` | Retro-hunt từ 2026-10-17 → `reports/retro-hunt-report.md/.json` |
| `run` | Nền supervisor: batch 300s + watcher realtime |
| `status` | Trạng thái supervisor/plugin/rule + 10 alert cuối |
| `stop` | Dừng supervisor (state giữ nguyên) |
| `export` | JSON SIEM + SQL vào `export/` |
| `clean` | stop + xóa toàn bộ workdir |

## 2. Bất biến bảo mật (đã kiểm bằng smoke test)

- Root bắt buộc; không phải root → thoát, không ghi gì.
- Workdir `/tmp/php2shell-monitor` là **thay đổi hệ thống duy nhất**:
  real-dir, owner root, `0700`, không symlink → sai bất kỳ → dừng.
- Đã verify: chạy non-root bị chặn (rc=1, không tạo thư mục); workdir 0755
  bị từ chối; symlink bị từ chối; không ghi ngoài workdir.
- Không cron/systemd/user; **không tự sống lại sau reboot** → chạy lại `-- run`.

## 3. Thứ tự vận hành khuyến nghị

1. `-- discover` → đọc `reports/log-map-actual.md`, chú ý patch status
   (changelog-based, không tin version number).
2. `-- retro` → nếu hit CRITICAL: dừng, chuyển incident response (cook.md §6.6/8.2).
3. `-- run` (supervisor nền). Kiểm `-- status` sau 5 phút.
4. Định kỳ: `-- export` rồi lấy file trong `export/` ra khỏi host trước reboot
   (`/tmp` volatile — systemd-tmpfiles có thể dọn).

## 4. Trạng thái rule (xem `-- status`)

Rule tự tắt khi thiếu năng lực; lý do in ở cột cuối:

| Rule | Điều kiện bật |
|---|---|
| P2S-008/015/016/017/026/030 | có access log (nginx/apache) |
| P2S-010/011/013/014/018/027 | FPM/Apache/nginx error log; 027 cần PID worker (`catch_workers_output`) |
| P2S-020/022 | webroot đọc được |
| P2S-021 | auditd log đọc được |
| P2S-024/025 | chạy root (quét `/proc`) |
| P2S-040 | ModSec/njs/Suricata đang ghi log |

Body rules (P2S-001/002/003/005/006/007) chỉ sống qua **P2S-040** (ingest) —
monitor không đọc request body (plan §6).

## 5. Tuning

- `conf/whitelist.conf`: 1 PCRE/dòng, áp lên toàn bộ record.
- `conf/rules.d/*.jsonl`: ghi đè/tắt rule không cần build lại
  (vd `{"id":"P2S-026","enabled":false}`).
- Ngưỡng aggregate mặc định: P2S-010 = 5 hit/300s/host; P2S-016 = 5×500/600s/IP;
  P2S-015 burst 413/499/502/504; dedup (rule,ip,uri) 15 phút.

## 6. Build lại (trên máy build)

```bash
bash build.sh   # shellcheck → tests (17 assertions) → makeself → sha256
```
Yêu cầu build machine: `makeself` (đã cài). Đích chỉ cần bash4+/jq/coreutils.

## 7. Đã smoke test trên máy này

- non-root chặn, workdir 0755/symlink chặn, discover/retro/run/status/stop/
  export/clean hoạt động, double-run guard (`flock`) hoạt động.
- Fixture Lexsah (MIT): UA `php2shell-109619` → **P2S-008 HIGH**; FPM
  memory-exhausted ×5 → **P2S-010** (agg 5/5); FPM sig11 → **P2S-011 HIGH**;
  exit code 70 → **P2S-018**; watcher realtime phát P2S-010 sau **3s**.
- Export SQL hợp lệ (chuẩn SQL, quote-doubling; MySQL cần NO_BACKSLASH_ESCAPES).

## 8. Giới hạn đã biết (kế thừa plan §8.1)

- Không body log → BODY rules tắt, T1 dựa 413/burst/status/UA.
- IP ở T2/T3 là **ứng viên có xếp hạng**, không phải kết luận (FPM log không có IP).
- `memory_limit=-1` (mitigation) làm P2S-010 im lặng → dựa P2S-011/kernel.
- /tmp volatile → export trước reboot; kẻ có root trên host đọc được workdir.
