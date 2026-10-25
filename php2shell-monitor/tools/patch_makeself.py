#!/usr/bin/env python3
"""Cho phep truyen flag thang xuong script ben trong archive makeself.

Mac dinh makeself tu choi moi flag la (--server, --project, --chatid...) va
doi nguoi dung dat "--" phan cach. Voi mot tool ma lenh chinh la
"php2shell-monitor.sh --server ... --project ... --chatid ...", viec do la
thua. Script nay thay khoi "-*)" trong stub de break ngay, giu nguyen "$@"
va do do khong can dau "--".

Rang buoc: phai giu NGUYEN so dong cua stub — makeself tinh offset payload
bang "head -n $skip | wc -c", nen them/bot dong se lam hong archive.
"""
import sys

PATH = sys.argv[1]
data = open(PATH, 'rb').read()

# stub la phan text ASCII o dau file, ket thuc o byte nhi phan dau tien
end = 0
while end < len(data) and data[end] <= 127 and data[end] != 0:
    end += 1
stub, rest = data[:end], data[end:]
lines = stub.split(b'\n')

OLD = [b'    -*)',
       b'\techo Unrecognized flag : "$1" >&2',
       b'\tMS_Help',
       b'\texit 1',
       b'\t;;']
NEW = [b'    -*) break ;;   # user flag: giu nguyen trong "$@" cho script ben trong',
       b'    # Khong tieu thu flag la (--server/--project/--chatid): break de thu tu',
       b'    # tham so duoc giu nguyen va chuyen xuong script, nho vay khong can',
       b'    # dau "--" phan cach.',
       b'    #']

idx = None
for n in range(len(lines) - len(OLD) + 1):
    if lines[n:n + len(OLD)] == OLD:
        idx = n
        break
if idx is None:
    if any(b'user flag: giu nguyen' in l for l in lines):
        print('already patched:', PATH)
        sys.exit(0)
    sys.exit('patch_makeself: khoi "-*)" khong tim thay trong stub')

assert len(NEW) == len(OLD), 'phai giu nguyen so dong'
lines[idx:idx + len(OLD)] = NEW
open(PATH, 'wb').write(b'\n'.join(lines) + rest)
print('patched:', PATH)
