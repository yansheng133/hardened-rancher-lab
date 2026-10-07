"""payment-api：展示用的示範服務。每 5 秒輸出一行 JSON 日誌（給 rancher-logging 收），提供 /healthz 與 /api/payments（給 Ingress 與 Traefik 儀表板）。資料全為隨機產生。"""
import json, random, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

def log(**kw):
    kw.setdefault("ts", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    print(json.dumps(kw), flush=True)

def worker():
    n = 0
    while True:
        n += 1
        log(level="info", service="payment-api", event="payment.processed",
            payment_id=f"PAY-{n:07d}", amount=round(random.uniform(100, 50000), 2), currency="USD",
            latency_ms=random.randint(8, 120))
        time.sleep(5)

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            body = b"ok"
        else:
            body = json.dumps({"service": "payment-api", "status": "up"}).encode()
        self.send_response(200); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a):
        pass

threading.Thread(target=worker, daemon=True).start()
log(level="info", service="payment-api", event="startup", port=8080)
ThreadingHTTPServer(("", 8080), H).serve_forever()
