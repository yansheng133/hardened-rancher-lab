#!/usr/bin/env python3
"""Prometheus 資料長度檢查：經 Kubernetes API proxy 查 rancher-monitoring 的 Prometheus，
對三類指標回報序列數、資料點數與最舊資料點距今幾小時。用來確認「儀表板截圖前已累積足夠歷史資料」。

用法：
  python3 -I v5-check.py           立即查一次；任一類為空或不滿 MIN_HOURS 就以 1 結束
  python3 -I v5-check.py --wait    每 2 分鐘查一次，直到三類都滿 MIN_HOURS（另有 4 小時逾時）

環境變數：
  KUBECONFIG  （必填）裝了 rancher-monitoring 的叢集
  MIN_HOURS   需要的最短歷史長度（預設 2）

注意：查詢失敗（kubectl 錯誤、權限不足）會被當成 EMPTY，結果是 FAIL，不會誤判成 PASS。
"""
import json, os, subprocess, sys, time, urllib.parse

KCFG = os.environ.get("KUBECONFIG") or sys.exit("請設定 KUBECONFIG")
PR = "/api/v1/namespaces/cattle-monitoring-system/services/rancher-monitoring-prometheus:9090/proxy/api/v1"
QUERIES = {
    "node_cpu": 'sum by (instance) (rate(node_cpu_seconds_total{mode!="idle"}[5m]))',
    "etcd": "etcd_server_has_leader",
    "apiserver": "sum(rate(apiserver_request_total[5m]))",
}
MIN_HOURS = float(os.environ.get("MIN_HOURS", "2"))


def check():
    now = time.time(); ok = True; lines = []
    for name, q in QUERIES.items():
        url = f"{PR}/query_range?query={urllib.parse.quote(q)}&start={int(now - (MIN_HOURS + 1) * 3600)}&end={int(now)}&step=60"
        out = subprocess.run(["kubectl", "--kubeconfig", KCFG, "get", "--raw", url], capture_output=True, text=True, timeout=60)
        try:
            res = json.loads(out.stdout)["data"]["result"] if out.returncode == 0 else []
        except (ValueError, KeyError):
            res = []
        if not res:
            lines.append(f"{name:<10} EMPTY {out.stderr.strip()[:120]}"); ok = False; continue
        t0 = min(float(s["values"][0][0]) for s in res)
        age = (now - t0) / 3600
        points = sum(len(s["values"]) for s in res)
        lines.append(f"{name:<10} series={len(res)} points={points} oldest={time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(t0))} age_h={age:.2f}")
        ok = ok and age >= MIN_HOURS
    return ok, lines


if "--wait" in sys.argv:
    deadline = time.time() + 4 * 3600
    while True:
        ok, lines = check()
        if ok or time.time() > deadline:
            break
        time.sleep(120)
else:
    ok, lines = check()
print(time.strftime("checked at %Y-%m-%d %H:%M:%S %Z"))
print("\n".join(lines))
print("RESULT", "PASS" if ok else "NOT YET / FAIL")
sys.exit(0 if ok else 1)
