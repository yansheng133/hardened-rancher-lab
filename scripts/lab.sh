#!/bin/bash
# 實驗環境開關機：只操作帶 Project=${LAB_TAG} 標籤、名稱為 ${LAB_TAG}-mgmt／-prod-1／-dr-1 的 EC2。
# 用法：bash lab.sh status | up | down
#   status：各台狀態、公開 IP、這次開機累計多久、每小時費用估算
#   up    ：start-instances，等到 running；mgmt 若掛 Elastic IP 則不變，其他台的公開 IP 會變
#   down  ：stop-instances（只停機，不 terminate；EBS 與 Elastic IP 仍會計費）
#
# 環境變數（皆可覆寫）：
#   LAB_TAG        資源標籤與名稱前綴（預設 hardened-lab）
#   AWS_PROFILE    AWS CLI 設定檔（不設就用 AWS CLI 自己的預設）
#   AWS_REGION     區域（預設 ap-northeast-1）
#   RANCHER_HOST   只用來在 status 印出網址，例如 rancher.192.0.2.10.sslip.io
#   REGISTRY_HOST  同上，例如 registry.192.0.2.10.sslip.io
#   PRICE_*        單價（美元），預設是某次查詢東京區 On-Demand 的值，請依自己的區域與時間查詢
#   DISK_GB        三台 EBS 合計 GiB（預設 450 = 200＋150＋100）
# 不含任何憑證；AWS 身分取自 AWS CLI 的設定。
set -euo pipefail
LAB_TAG="${LAB_TAG:-hardened-lab}"
export AWS_REGION="${AWS_REGION:-ap-northeast-1}"
NAMES="${LAB_TAG}-mgmt,${LAB_TAG}-prod-1,${LAB_TAG}-dr-1"

PRICE_2XL="${PRICE_2XL:-0.496}"              # m6i.2xlarge / 小時
PRICE_XL="${PRICE_XL:-0.248}"                # m6i.xlarge / 小時
PRICE_GP3_GB_MONTH="${PRICE_GP3_GB_MONTH:-0.096}"
PRICE_IPV4="${PRICE_IPV4:-0.005}"            # 公開 IPv4 / 小時
DISK_GB="${DISK_GB:-450}"

ids() {
  local out
  out=$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=${LAB_TAG}" "Name=tag:Name,Values=${NAMES}" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  [ -n "$out" ] || { echo "找不到標籤 Project=${LAB_TAG} 的執行個體" >&2; exit 1; }
  echo "$out"
}

status() {
  # shellcheck disable=SC2046
  aws ec2 describe-instances --instance-ids $(ids) --output json | python3 -I -c '
import json, sys, datetime as dt
p_2xl, p_xl, p_gb, p_ip, disk_gb = map(float, sys.argv[1:6])
price = {"m6i.2xlarge": p_2xl, "m6i.xlarge": p_xl}
now = dt.datetime.now(dt.timezone.utc)
running = 0; inst_cost = 0.0
for r in json.load(sys.stdin)["Reservations"]:
    for i in r["Instances"]:
        name = next((t["Value"] for t in i.get("Tags", []) if t["Key"] == "Name"), "?")
        st = i["State"]["Name"]
        up = ""
        if st == "running":
            running += 1; inst_cost += price.get(i["InstanceType"], p_2xl)
            h = (now - dt.datetime.fromisoformat(i["LaunchTime"].replace("Z", "+00:00"))).total_seconds() / 3600
            up = f"開機 {h:.1f} 小時"
        ip = i.get("PublicIpAddress") or "-"; itype = i["InstanceType"]
        print(f"{name:<22} {itype:<12} {st:<9} 公開IP {ip:<16} {up}")
hourly = inst_cost + disk_gb * p_gb / 730 + (running + 1) * p_ip
print(f"目前每小時合計約 US${hourly:.3f}（{running} 台執行中＋EBS {disk_gb:.0f} GiB＋公開 IP，估算值）")
' "$PRICE_2XL" "$PRICE_XL" "$PRICE_GP3_GB_MONTH" "$PRICE_IPV4" "$DISK_GB"
  [ -n "${RANCHER_HOST:-}" ] && echo "Rancher：https://${RANCHER_HOST}"
  [ -n "${REGISTRY_HOST:-}" ] && echo "Registry：https://${REGISTRY_HOST}"
  return 0
}

case "${1:-status}" in
  status) status ;;
  up)
    I=$(ids)
    # shellcheck disable=SC2086
    aws ec2 start-instances --instance-ids $I --query 'StartingInstances[].[InstanceId,CurrentState.Name]' --output text
    # shellcheck disable=SC2086
    aws ec2 wait instance-running --instance-ids $I
    status
    echo "沒有 Elastic IP 的節點公開 IP 可能已改變：直連這些節點的 kubeconfig 要更新 server 位址"
    ;;
  down)
    I=$(ids)
    # shellcheck disable=SC2086
    aws ec2 stop-instances --instance-ids $I --query 'StoppingInstances[].[InstanceId,CurrentState.Name]' --output text
    # shellcheck disable=SC2086
    aws ec2 wait instance-stopped --instance-ids $I
    status
    ;;
  *) echo "用法：$0 status|up|down" >&2; exit 2 ;;
esac
