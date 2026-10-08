#!/usr/bin/env python3
"""擴縮時效量測（在控制平面節點上以 root 執行，時間戳全部來自同一個節點時鐘）。
用法：c-scale-measure.node.py <ns> <pod label selector> <佇列 ClusterIP> <事件值> <目標就緒數> <次數> <輸出 tsv> [基準就緒數=1]
每次：等就緒 Pod 數回到基準 → 記 T0 → 對佇列服務 GET /set?n=<事件值>（事件發生）→ 以 API watch 等到就緒 Pod 數達到目標，記 T1
     → GET /set?n=0，等回到基準再做下一次。
"""
import http.client, json, random, ssl, sys, threading, time, urllib.request

ns, sel, qip, val, target, n, out = sys.argv[1:8]
base = int(sys.argv[8]) if len(sys.argv) > 8 else 1
val, target, n = int(val), int(target), int(n)
TLS = "/var/lib/rancher/rke2/server/tls/"
ctx = ssl.create_default_context(cafile=TLS + "server-ca.crt")
ctx.load_cert_chain(TLS + "client-admin.crt", TLS + "client-admin.key"); ctx.check_hostname = False
ready = {}   # pod -> ready bool
lock = threading.Lock()
changed = threading.Condition(lock)


def watch():
    while True:
        c = http.client.HTTPSConnection("127.0.0.1", 6443, context=ctx)
        c.request("GET", f"/api/v1/namespaces/{ns}/pods?watch=1&labelSelector={sel}")
        r = c.getresponse()
        while True:
            line = r.readline()
            if not line: break
            ev = json.loads(line); o = ev["object"]; name = o["metadata"]["name"]
            ok = ev["type"] != "DELETED" and o["metadata"].get("deletionTimestamp") is None and any(
                x["type"] == "Ready" and x["status"] == "True" for x in o.get("status", {}).get("conditions", []))
            with changed:
                if ev["type"] == "DELETED": ready.pop(name, None)
                else: ready[name] = ok
                changed.notify_all()
threading.Thread(target=watch, daemon=True).start()


def nready():
    return sum(1 for v in ready.values() if v)


def wait_until(pred, timeout):
    end = time.time() + timeout
    with changed:
        while not pred():
            left = end - time.time()
            if left <= 0: return False
            changed.wait(min(left, 0.5))
    return True


def setq(v):
    urllib.request.urlopen(f"http://{qip}/set?n={v}", timeout=5).read()


time.sleep(2)
with open(out, "a") as f:
    for i in range(1, n + 1):
        setq(0)
        if not wait_until(lambda: nready() == base and len(ready) == base, 300):
            print(f"{i}\tbaseline-timeout\t{dict(ready)}", flush=True)
        time.sleep(3 + random.uniform(0, 15))   # 打散與 HPA 15 秒同步週期的相位
        t0 = time.time(); setq(val)
        ok = wait_until(lambda: nready() >= target, 300); t1 = time.time()
        line = f"{i}\t{t0:.3f}\t{t1:.3f}\t{(t1 - t0):.3f}\t{'ok' if ok else 'timeout'}"
        print(line, flush=True); f.write(line + "\n"); f.flush()
    setq(0)
