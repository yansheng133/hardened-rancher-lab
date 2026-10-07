#!/usr/bin/env python3
"""秘密外洩掃描：在指定的檔案或目錄中，搜尋已知的秘密值有沒有出現。

秘密值只從 stdin 讀（每行一個），不經 argv、不寫檔。只回報「哪個檔案命中第幾號秘密」，不印出秘密本身。
比對兩種方式：完整值，以及（去掉共用前綴後的）前 N 碼——後者用來抓被截斷或部分貼上的情況，
但也可能誤判（例如二進位檔剛好含同樣的位元組），命中時請再以完整值確認。

用法：
  python3 -I n3-secret-scan.py [--strip-prefix PREFIX] [--prefix-len N] <路徑> [<路徑> ...] < secrets.txt
    --strip-prefix  比對前 N 碼前先去掉的共用前綴（例如註冊碼共有的開頭），可重複指定
    --prefix-len    部分比對的長度（預設 6；設 0 停用部分比對）

範例（從 macOS 鑰匙圈取值，不落地）：
  security find-generic-password -s my-lab-secret -w | python3 -I n3-secret-scan.py ~/.zsh_history ./
"""
import os, sys

argv = sys.argv[1:]
strip, plen, roots = [], 6, []
while argv:
    a = argv.pop(0)
    if a == "--strip-prefix":
        strip.append(argv.pop(0))
    elif a == "--prefix-len":
        plen = int(argv.pop(0))
    elif a in ("-h", "--help"):
        sys.exit(__doc__)
    else:
        roots.append(a)
if not roots:
    sys.exit(__doc__)

secrets = [l.strip() for l in sys.stdin if l.strip()]
needles = []
for i, s in enumerate(secrets, 1):
    core = s
    for p in strip:
        core = core.replace(p, "")
    needles.append((i, s.encode()))
    if plen and len(core) >= plen:
        needles.append((i, core[:plen].encode()))

hits = 0
for root in roots:
    paths = [root] if os.path.isfile(root) else [os.path.join(d, f) for d, _, fs in os.walk(root) for f in fs]
    for p in paths:
        try:
            with open(p, "rb") as fh:
                data = fh.read()
        except Exception:
            continue
        for i, n in needles:
            if n in data:
                print(f"HIT secret#{i} in {p}")
                hits += 1
                break
print(f"secrets={len(secrets)} roots={len(roots)} hits={hits}")
sys.exit(1 if hits else 0)
