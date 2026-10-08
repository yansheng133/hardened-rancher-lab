#!/usr/bin/env python3
"""叢集外流量產生器：同時跑三組模擬負載平衡器（只用標準函式庫，在叢集外、能連到各節點 80／6443 的機器上執行）。

用法：LB_NODES=192.0.2.41,192.0.2.42,192.0.2.43 LB_HOST=payment.example.lab python3 d1-traffic3.py <輸出前綴> <秒數>
  LB_NODES：各節點位址（Traefik 以 hostPort 80 提供入口）；LB_HOST：Ingress 主機名稱；請求路徑 /healthz（健康檢查）與 /api/payments
  <前綴>.lb-A.tsv／lb-B.tsv／lb-C.tsv  三組模擬負載平衡器，只差在健康檢查：
        A：每 1 秒檢查、連續 1 次失敗剔除；B：每 5 秒、連續 2 次；C：每 10 秒、連續 3 次；三組都是 1 次成功即放回。
        每組各自每 0.2 秒把一個請求送到「目前判定健康」的節點（輪流），逾時 2 秒。
  <前綴>.hc-A.tsv…        每次健康檢查的結果與判定狀態（驗證量具用：看得到何時剔除、何時放回）
  <前綴>.node.tsv         不做健康檢查：每 1 秒對每個節點各送一次請求
  <前綴>.api.tsv          API Server：每 1 秒對三台的 6443/readyz 建立 TLS 連線，有 HTTP 回應（含 401）就算有回應
"""
import http.client, itertools, os, ssl, sys, threading, time

NODES = os.environ.get("LB_NODES", "192.0.2.41,192.0.2.42,192.0.2.43").split(",")
HOST = os.environ.get("LB_HOST", "payment.example.lab")
GROUPS = {"A": (1, 1), "B": (5, 2), "C": (10, 3)}   # 名稱: (檢查間隔秒, 判定不健康的連續失敗次數)
prefix, duration = sys.argv[1], float(sys.argv[2])
end = time.time() + duration


def get(ip, path, timeout=2.0):
    t0 = time.time()
    try:
        c = http.client.HTTPConnection(ip, 80, timeout=timeout)
        c.request("GET", path, headers={"Host": HOST, "Connection": "close"})
        r = c.getresponse(); r.read(); c.close()
        return r.status, (time.time() - t0) * 1000
    except Exception as e:
        return type(e).__name__, (time.time() - t0) * 1000


class LB:
    def __init__(self, name, interval, fall):
        self.name, self.interval, self.fall = name, interval, fall
        self.healthy = {n: True for n in NODES}; self.fails = {n: 0 for n in NODES}; self.lock = threading.Lock()

    def check_node(self, n, f):
        s, ms = get(n, "/healthz", 1.0)
        with self.lock:
            if s == 200: self.fails[n] = 0; self.healthy[n] = True
            else:
                self.fails[n] += 1
                if self.fails[n] >= self.fall: self.healthy[n] = False
            st = self.healthy[n]
        f.write(f"{time.time():.3f}\t{n}\t{s}\t{ms:.1f}\t{'UP' if st else 'DOWN'}\n"); f.flush()

    def health_loop(self):
        with open(f"{prefix}.hc-{self.name}.tsv", "w") as f:
            f.write("ts\tnode\tresult\tms\tstate\n")
            while time.time() < end:
                t0 = time.time()
                th = [threading.Thread(target=self.check_node, args=(n, f)) for n in NODES]
                for t in th: t.start()
                for t in th: t.join()
                time.sleep(max(0, self.interval - (time.time() - t0)))

    def req_loop(self):
        rr = itertools.cycle(NODES)
        with open(f"{prefix}.lb-{self.name}.tsv", "w") as f:
            f.write("ts\tnode\tresult\tms\n")
            while time.time() < end:
                with self.lock:
                    cands = [n for n in NODES if self.healthy[n]]
                node = None
                for _ in range(len(NODES)):
                    n = next(rr)
                    if n in cands: node = n; break
                if node is None:
                    f.write(f"{time.time():.3f}\t-\tNO_HEALTHY_NODE\t0\n")
                else:
                    s, ms = get(node, "/api/payments")
                    f.write(f"{time.time():.3f}\t{node}\t{s}\t{ms:.1f}\n")
                f.flush(); time.sleep(0.2)


def node_loop():
    with open(prefix + ".node.tsv", "w") as f:
        f.write("ts\tnode\tresult\tms\n")
        while time.time() < end:
            for n in NODES:
                s, ms = get(n, "/api/payments", 1.5)
                f.write(f"{time.time():.3f}\t{n}\t{s}\t{ms:.1f}\n")
            f.flush(); time.sleep(1)


def api_loop():
    ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
    with open(prefix + ".api.tsv", "w") as f:
        f.write("ts\tnode\tresult\tms\n")
        while time.time() < end:
            for n in NODES:
                t0 = time.time()
                try:
                    c = http.client.HTTPSConnection(n, 6443, timeout=2, context=ctx)
                    c.request("GET", "/readyz"); r = c.getresponse(); r.read(); c.close(); s = r.status
                except Exception as e:
                    s = type(e).__name__
                f.write(f"{time.time():.3f}\t{n}\t{s}\t{(time.time()-t0)*1000:.1f}\n")
            f.flush(); time.sleep(1)


ts = []
for g, (iv, fall) in GROUPS.items():
    lb = LB(g, iv, fall); ts += [threading.Thread(target=lb.health_loop, daemon=True), threading.Thread(target=lb.req_loop, daemon=True)]
ts += [threading.Thread(target=x, daemon=True) for x in (node_loop, api_loop)]
for t in ts: t.start()
for t in ts: t.join()
