# payment-api

[hardened-rancher-lab](https://github.com/yansheng133/hardened-rancher-lab) 的示範服務：每 5 秒輸出一行 JSON 日誌（模擬付款處理），
並提供 HTTP 端點，讓 Rancher Monitoring、Logging 與 Ingress 儀表板有真實的流量和日誌可看。

```
GET /healthz        → ok
GET /api/payments   → {"service": "payment-api", "status": "up"}
（任何其他路徑）     → 同上
```

日誌範例：

```json
{"level": "info", "service": "payment-api", "event": "payment.processed", "payment_id": "PAY-0000105", "amount": 30282.45, "currency": "USD", "latency_ms": 119, "ts": "2026-10-07T02:21:58Z"}
```

## 映像檔

- `linux/amd64`、`linux/arm64`，附 SBOM 與 provenance attestation。
- 基底 `registry.suse.com/bci/python:3.14.7-base-8.13`（SLES 16.1），非 root（UID 1000）執行，可搭配 `readOnlyRootFilesystem: true`。
- 只用 Python 標準函式庫，沒有任何相依套件。
- 1.0.1 以 Trivy 掃描為 0 個弱點（2026-10-07）。

## 用法

```yaml
containers:
  - name: payment-api
    image: docker.io/yansheng133/payment-api:1.0.1
    ports: [{containerPort: 8080}]
    securityContext:
      runAsNonRoot: true
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities: {drop: [ALL]}
```

## 自己簽章時

要讓 SUSE Security（NeuVector 5.6.x）的准入控制驗證簽章，簽章必須是 cosign v2 的格式（`.sig` tag）。
用 cosign 3.x 簽時，**同時**加上 `--new-bundle-format=false --use-signing-config=false`；只用預設值簽的不會被驗證。
實測紀錄見 [docs/sl-micro-validation](https://github.com/yansheng133/hardened-rancher-lab/tree/main/docs/sl-micro-validation)。

這只是展示用的假服務，不處理任何真實交易。部署檔、建置方式與環境說明都在 GitHub：
https://github.com/yansheng133/hardened-rancher-lab
