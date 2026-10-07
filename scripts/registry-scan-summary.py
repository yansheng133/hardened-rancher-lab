#!/usr/bin/env python3
"""列出 Harbor 相容 Registry（例如 SUSE Private Registry）某個專案／儲存庫底下每個 artifact 的標籤、
Trivy 掃描摘要與 accessory（SBOM、簽章）。

用法：
  python3 -I registry-scan-summary.py <project> <repository> [--wait]
    --wait   等到每個 artifact 都掃完（最多 15 分鐘）

環境變數：
  REGISTRY_HOST           （必填）例如 registry.192.0.2.10.sslip.io
  REGISTRY_USER           帳號（預設 admin；建議改用唯讀的帳號）
  REGISTRY_PASSWORD_FILE  密碼檔路徑。不設就從 stdin 讀第一行。密碼不經 argv、不印出。
  REGISTRY_CA_FILE        簽發 Registry 憑證的 CA（PEM）。不設就用系統信任的 CA。

範例：
  REGISTRY_HOST=registry.192.0.2.10.sslip.io REGISTRY_CA_FILE=lab-ca.crt \\
    python3 -I registry-scan-summary.py payment payment-api < ~/.secrets/registry-password
"""
import base64, json, os, ssl, sys, time, urllib.parse, urllib.request

args = [a for a in sys.argv[1:] if not a.startswith("--")]
if len(args) != 2:
    sys.exit(__doc__)
host = os.environ.get("REGISTRY_HOST") or sys.exit("請設定 REGISTRY_HOST")
user = os.environ.get("REGISTRY_USER", "admin")
pw_file = os.environ.get("REGISTRY_PASSWORD_FILE")
pw = (open(pw_file).read() if pw_file else sys.stdin.readline()).strip()
if not pw:
    sys.exit("沒有讀到密碼（REGISTRY_PASSWORD_FILE 或 stdin）")

BASE = f"https://{host}/api/v2.0"
ctx = ssl.create_default_context(cafile=os.environ.get("REGISTRY_CA_FILE") or None)
auth = "Basic " + base64.b64encode(f"{user}:{pw}".encode()).decode()
del pw
proj = args[0]
repo = urllib.parse.quote(urllib.parse.quote(args[1], safe=""), safe="")


def arts():
    r = urllib.request.Request(
        f"{BASE}/projects/{proj}/repositories/{repo}/artifacts?with_tag=true&with_scan_overview=true&with_accessory=true&page_size=50",
        headers={"Authorization": auth, "X-Accept-Vulnerabilities": "application/vnd.security.vulnerability.report; version=1.1"})
    with urllib.request.urlopen(r, context=ctx, timeout=60) as resp:
        return json.loads(resp.read())


deadline = time.time() + 900
while True:
    a = arts()
    pending = [x for x in a if not x.get("scan_overview")
               or any(v.get("scan_status") not in ("Success", "Error") for v in x["scan_overview"].values())]
    if "--wait" not in sys.argv or not pending or time.time() > deadline:
        break
    time.sleep(15)

for x in a:
    tags = [t["name"] for t in x.get("tags") or []]
    for v in (x.get("scan_overview") or {}).values():
        summ = v.get("summary") or {}
        s = summ.get("summary") or {}
        print(f"{','.join(tags) or '(no tag)':<22} {x['digest'][:19]} scan={v.get('scan_status'):<8} "
              f"Critical={s.get('Critical', 0)} High={s.get('High', 0)} Medium={s.get('Medium', 0)} "
              f"Low={s.get('Low', 0)} Unknown={s.get('Unknown', 0)} total={summ.get('total', 0)} fixable={summ.get('fixable', 0)}")
    acc = [(c.get("type"), c.get("digest", "")[:19]) for c in x.get("accessories") or []]
    if acc:
        print(f"{'':<22} accessories={acc}")
