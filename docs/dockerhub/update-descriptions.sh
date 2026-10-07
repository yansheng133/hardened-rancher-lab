#!/usr/bin/env bash
# 把這個目錄裡的說明推上 Docker Hub 的倉庫描述。
#
#   bash docs/dockerhub/update-descriptions.sh            # 先看會送什麼（dry-run）
#   bash docs/dockerhub/update-descriptions.sh --apply
#
# 憑證從 macOS keychain 讀（docker login 存的那份），**全程不印出來**。
# 沒有登入過的話先跑 `docker login`。
#
# 為什麼要有這支：Docker Hub 的倉庫描述是另一個會漂移的地方。
# 把它寫成檔案放進版控、用腳本送上去，才不會變成「只有當時那個人知道寫了什麼」。
# 描述刻意只放導向，不複製整份 README——那會變成第三個要同步的副本。
set -uo pipefail
case "${1:-}" in -h|--help) sed -n '2,12p' "$0"; exit 0 ;; esac

USER_NAME="${DOCKERHUB_USER:-yansheng133}"
HERE=$(cd "$(dirname "$0")" && pwd)
APPLY=0; [ "${1:-}" = --apply ] && APPLY=1

declare -a REPOS=("payment-api")
declare -a SHORTS=(
  "Demo payment service for hardened-rancher-lab: JSON logs + HTTP, SUSE BCI base, amd64/arm64"
)

echo "帳號　${USER_NAME}"
echo "模式　$([ ${APPLY} = 1 ] && echo '送出' || echo 'dry-run，不會寫入')"
echo

for i in "${!REPOS[@]}"; do
  f="${HERE}/${REPOS[$i]}.md"
  [ -f "$f" ] || { echo "錯誤：找不到 $f" >&2; exit 1; }
  echo "── ${REPOS[$i]} ──"
  # **Docker Hub 算的是位元組不是字元。** 中文一個字三個位元組，
  # 用 ${#var} 算字元的話，81 字元的字串會是 103 位元組——檢查通過、API 退回。
  bytes=$(printf '%s' "${SHORTS[$i]}" | wc -c | tr -d ' ')
  echo "  短描述（${bytes} 位元組／${#SHORTS[$i]} 字元，上限 100 位元組）：${SHORTS[$i]}"
  echo "  完整說明：$(wc -c < "$f" | tr -d ' ') 位元組"
  [ "${bytes}" -le 100 ] || { echo "  錯誤：短描述 ${bytes} 位元組，超過 100" >&2; exit 1; }
done

if [ ${APPLY} = 0 ]; then
  echo
  echo "（dry-run：沒有送出。加 --apply 才會更新 Docker Hub。）"
  exit 0
fi

# 從 keychain 取憑證。這一段不可以把內容印出來，也不要寫進檔案或放進 argv。
CRED=$(echo "https://index.docker.io/v1/" | docker-credential-osxkeychain get 2>/dev/null)
if [ -z "${CRED}" ]; then
  echo "錯誤：keychain 裡沒有 Docker Hub 的憑證，請先 docker login" >&2; exit 1
fi

TOKEN=$(CRED="${CRED}" USER_NAME="${USER_NAME}" python3 - <<'PY'
import json, os, sys, urllib.request
cred = json.loads(os.environ["CRED"])
body = json.dumps({"username": cred.get("Username") or os.environ["USER_NAME"],
                   "password": cred.get("Secret")}).encode()
req = urllib.request.Request("https://hub.docker.com/v2/users/login/", data=body,
                             headers={"Content-Type": "application/json"})
try:
    print(json.load(urllib.request.urlopen(req, timeout=30))["token"])
except Exception as e:
    print("", end="")
    sys.stderr.write(f"登入失敗：{type(e).__name__}\n")
PY
)
unset CRED
[ -n "${TOKEN}" ] || { echo "錯誤：取不到 Docker Hub 的 token" >&2; exit 1; }

FAIL=0
for i in "${!REPOS[@]}"; do
  repo="${REPOS[$i]}"
  TOKEN="${TOKEN}" USER_NAME="${USER_NAME}" REPO="${repo}" \
  SHORT="${SHORTS[$i]}" FULLFILE="${HERE}/${repo}.md" python3 - <<'PY' || FAIL=1
import json, os, sys, urllib.request, urllib.error
body = json.dumps({"description": os.environ["SHORT"],
                   "full_description": open(os.environ["FULLFILE"]).read()}).encode()
url = f"https://hub.docker.com/v2/repositories/{os.environ['USER_NAME']}/{os.environ['REPO']}/"
req = urllib.request.Request(url, data=body, method="PATCH",
                             headers={"Content-Type": "application/json",
                                      "Authorization": "JWT " + os.environ["TOKEN"]})
try:
    urllib.request.urlopen(req, timeout=30)
    print(f"  {os.environ['REPO']} → 已更新")
except urllib.error.HTTPError as e:
    # 一定要把回應內容印出來。只說「HTTP 400」等於沒說——
    # 400 可能是描述太長、欄位名稱錯、或權限不足，處理方式完全不同。
    detail = e.read().decode("utf-8", "replace")[:300]
    sys.stderr.write(f"  {os.environ['REPO']} → 失敗 HTTP {e.code}：{detail}\n")
    sys.exit(1)
except Exception as e:
    sys.stderr.write(f"  {os.environ['REPO']} → 失敗 {type(e).__name__}\n")
    sys.exit(1)
PY
done
unset TOKEN

echo
echo "用匿名管道確認外人看到的（不要只信送出成功）："
USER_NAME="${USER_NAME}" REPOS="${REPOS[*]}" python3 - <<'PY'
import json, os, urllib.request
for repo in os.environ["REPOS"].split():
    d = json.load(urllib.request.urlopen(
        f"https://hub.docker.com/v2/repositories/{os.environ['USER_NAME']}/{repo}/", timeout=20))
    full = (d.get("full_description") or "").strip()
    print(f"  {repo}: 短描述 {'有' if d.get('description') else '空白'}"
          f"、完整說明 {len(full)} 字元")
PY
exit ${FAIL}
