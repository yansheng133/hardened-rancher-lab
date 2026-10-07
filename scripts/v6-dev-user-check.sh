#!/bin/bash
# 以「受測使用者自己的登入 token」（不是 kubectl --as 模擬）經 Rancher proxy 驗證專案角色的權限邊界，測完登出 token。
# 搭配 manifests/t4-project-role.yaml（payment-developer）：該可以的應該可以、不該可以的應該被拒。
#
# 秘密處理：
#   - 密碼從 DEV_PASSWORD_FILE 指定的檔案讀；不設就從 stdin 讀第一行。密碼與 token 都不經 argv、不印出。
#   - token 只存在本腳本行程的記憶體，以及權限 600 的暫存 kubeconfig（腳本結束即刪除）。
#
# 環境變數：
#   RANCHER_HOST      （必填）例如 rancher.192.0.2.10.sslip.io
#   CLUSTER_ID        （必填）下游叢集在 Rancher 的 ID（Cluster Management 叢集詳細頁網址裡 c-m- 開頭那段）
#   DEV_USER          Rancher 本機使用者名稱（預設 dev-user）
#   DEV_PASSWORD_FILE 密碼檔；不設就讀 stdin
#   APP_NS            受測命名空間（預設 demo），DEPLOY 為其中的 Deployment（預設 payment-api）
#   DENIED_NS         應該看不到的命名空間，空白分隔（預設 "kube-system central-log"）
#   RANCHER_CA_FILE   Rancher 憑證的 CA（PEM）。不設就用系統信任的 CA。
#   RANCHER_INSECURE=1  不驗證 TLS（僅限自簽憑證的實驗環境；預設關閉）
set -uo pipefail
: "${RANCHER_HOST:?請設定 RANCHER_HOST}"
: "${CLUSTER_ID:?請設定 CLUSTER_ID}"
DEV_USER="${DEV_USER:-dev-user}"
APP_NS="${APP_NS:-demo}"
DEPLOY="${DEPLOY:-payment-api}"
DENIED_NS="${DENIED_NS:-kube-system central-log}"
R="https://${RANCHER_HOST}"
TMP=$(mktemp -d); chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
umask 077

# Python 端共用的 TLS 設定
cat > "$TMP/tls.py" <<'PY'
import os, ssl
def ctx():
    if os.environ.get("RANCHER_INSECURE") == "1":
        c = ssl.create_default_context(); c.check_hostname = False; c.verify_mode = ssl.CERT_NONE
        return c
    return ssl.create_default_context(cafile=os.environ.get("RANCHER_CA_FILE") or None)
PY

if [ -n "${DEV_PASSWORD_FILE:-}" ]; then
  PWSRC="$DEV_PASSWORD_FILE"
else
  PWSRC=/dev/stdin
fi

# 登入：密碼經 stdin 進 Python，token 由 stdout 回到變數
cat > "$TMP/login.py" <<'PY'
import json, os, sys, urllib.request
sys.path.insert(0, os.path.dirname(__file__)); import tls
pw = sys.stdin.readline().strip()
req = urllib.request.Request(f"https://{os.environ['RANCHER_HOST']}/v3-public/localProviders/local?action=login", method="POST",
      data=json.dumps({"username": os.environ["DEV_USER"], "password": pw, "responseType": "json", "description": "permission check"}).encode(),
      headers={"Content-Type": "application/json"})
print(json.load(urllib.request.urlopen(req, context=tls.ctx(), timeout=30))["token"])
PY
TOKEN=$(head -n1 "$PWSRC" | RANCHER_HOST="$RANCHER_HOST" DEV_USER="$DEV_USER" python3 "$TMP/login.py")
[ -n "$TOKEN" ] || { echo "${DEV_USER} 登入失敗"; exit 1; }

if [ "${RANCHER_INSECURE:-}" = 1 ]; then
  TLSLINE="insecure-skip-tls-verify: true"
elif [ -n "${RANCHER_CA_FILE:-}" ]; then
  TLSLINE="certificate-authority: \"${RANCHER_CA_FILE}\""
else
  TLSLINE=""
fi
cat > "$TMP/kc" <<EOF
apiVersion: v1
kind: Config
clusters: [{name: target, cluster: {server: "$R/k8s/clusters/${CLUSTER_ID}"${TLSLINE:+, $TLSLINE}}}]
users: [{name: tester, user: {token: "$TOKEN"}}]
contexts: [{name: c, context: {cluster: target, user: tester}}]
current-context: c
EOF
k() { kubectl --kubeconfig "$TMP/kc" --request-timeout=20s "$@"; }

echo "whoami: $(k auth whoami -o jsonpath='{.status.userInfo.username}' 2>&1)"
echo "-- 應該可以"
echo "list pods ${APP_NS}:   $(k -n "$APP_NS" get pods --no-headers 2>&1 | wc -l | tr -d ' ') pods"
P=$(k -n "$APP_NS" get pods -o name 2>/dev/null | head -1)
echo "logs ${P:-（無 Pod）}: $(k -n "$APP_NS" logs "$P" --tail=1 2>&1 | cut -c1-90)"
echo "can-i patch deployments: $(k -n "$APP_NS" auth can-i patch deployments)"
echo "dry-run scale ${DEPLOY}: $(k -n "$APP_NS" scale "deploy/${DEPLOY}" --replicas=2 --dry-run=server 2>&1 | tail -1)"
echo "-- 應該不行"
Q=$(k -n "$APP_NS" get resourcequota -o name 2>/dev/null | head -1)
[ -n "$Q" ] && echo "patch $Q: $(k -n "$APP_NS" patch "$Q" --type merge -p '{"spec":{"hard":{"pods":"99"}}}' --dry-run=server 2>&1 | tail -1 | cut -c1-140)"
echo "can-i update resourcequotas: $(k -n "$APP_NS" auth can-i update resourcequotas)"
echo "can-i create rolebindings: $(k -n "$APP_NS" auth can-i create rolebindings)"
for ns in $DENIED_NS; do
  echo "list pods ${ns}: $(k -n "$ns" get pods 2>&1 | tail -1 | cut -c1-120)"
done

# 登出 token：token 經 stdin 傳給 Python，不出現在 argv 或程式碼裡
cat > "$TMP/logout.py" <<'PY'
import os, sys, urllib.request
sys.path.insert(0, os.path.dirname(__file__)); import tls
tok = sys.stdin.readline().strip()
req = urllib.request.Request(f"https://{os.environ['RANCHER_HOST']}/v3/tokens?action=logout", method="POST", data=b"{}",
      headers={"Content-Type": "application/json", "Authorization": f"Bearer {tok}"})
print("logout:", urllib.request.urlopen(req, context=tls.ctx(), timeout=30).status)
PY
printf '%s\n' "$TOKEN" | RANCHER_HOST="$RANCHER_HOST" python3 "$TMP/logout.py"
unset TOKEN
