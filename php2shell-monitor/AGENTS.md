# AGENTS.md — bản đồ repo cho người/agent sửa code

## Mô hình

Một install = một **device** thuộc một **project**. Mỗi batch 5 phút tạo **tối đa
một alert**, severity = cao nhất trong batch, kèm toàn bộ dòng log gốc đã khớp.

## Cây code

```
src/
├── main.sh                 CLI: (mặc định) triển khai+pair một lệnh | once | run
│                           | test | status | stop | discover | retro | export | clean
├── bootstrap.sh            makeself entry: root check, seed conf/, prune cũ, exec main.sh
│                           (archive giải nén thẳng vào /opt/php2shell-monitor)
├── conf/
│   ├── device.conf         PROJECT + DEVICE (giữ nguyên khi upgrade)
│   ├── default.conf        BATCH_INTERVAL, MAX_EVIDENCE_INLINE, đường dẫn log, PLUGINS_DISABLED
│   ├── rules.conf          ghi chú override rule
│   └── whitelist.conf      1 PCRE/dòng
├── lib/
│   ├── common.sh           hằng số, utc_now, sanitize_field, jq path
│   ├── paths.sh            p2s_device_init: PROJECT/DEVICE -> projects/<p>/devices/<d>/*
│   ├── stream.sh           12-field TSV contract + emit_record
│   ├── state.sh            offsets (inode/byte/line) + last_batch
│   ├── json.sh             json_escape/json_str/json_obj (không fork jq)
│   ├── log.sh, time_utc.sh
│   └── accesslog.awk       parser access log, giữ FILENAME + FNR
├── engine/
│   ├── scan.sh             1 batch: plugins -> rule_match -> report
│   ├── plugins.sh          chạy mọi plugin, cô lập lỗi, timeout
│   ├── rule_match.sh       khớp rule trên TỪNG field, source gate, and/neg, min
│   ├── report.sh           gom hit -> MỘT alert + evidence/<batch>.jsonl
│   ├── supervisor.sh       vòng lặp batch + PID/lock
│   └── status.sh           báo cáo trạng thái
├── plugins/                13 nguồn log; _batch_common.sh giữ offset + dòng
├── rules/pack/{t1,t2,t3}.jsonl
├── discovery/              discovery.sh (read-only), retro_hunt.sh, patch_status.sh
└── export/export_json.sh
```

## Bất biến khi sửa

1. `report.sh` là nơi **duy nhất** tạo alert. Không thêm đường ghi alert thứ hai.
2. Alert phải giữ `file`, `line`, `raw` cho mọi hit. `evidence_file` luôn đầy đủ,
   kể cả khi `evidence[]` bị cắt.
3. `rule_match.sh` khớp trên giá trị field. Đừng quay lại `grep` trên cả dòng TSV
   (`^500$` sẽ chết).
4. Offset phải lưu cả **số dòng**; alert dựa vào nó để chỉ đúng `file:line`.
5. Plugin chạy trong process con ⇒ mỗi plugin tự `state_save_offsets` (đã có trap EXIT).
6. Không thêm state toàn cục/dedup/correlation: một batch = một alert là hợp đồng.
7. Mọi ghi phải nằm dưới `$WORKDIR`; host là read-only.

## Kiểm thử

```bash
SRC=$PWD/src bash tests/run_tests.sh   # 50 assertion, không cần bats
bats tests/unit                        # parser tests
shellcheck -x src/lib/*.sh src/engine/*.sh src/plugins/*.sh
./build.sh                             # shellcheck + tests + makeself
```

Khi sửa rule pack: chạy `-- once` trên lab có log mẫu rồi kiểm
`alerts/queue.jsonl` (đúng 1 dòng) và `evidence/<batch>.jsonl` (đủ hit).

## Tài liệu

- `README.md` — mô hình alert + layout + dùng.
- `ARCHITECTURE.md` — luồng batch, contract stream, schema alert.
- `docs/OPERATIONS.md` — vận hành, tuning, sự cố.
- `../central-alert-server/README.md` — kho tập trung nhiều device.
