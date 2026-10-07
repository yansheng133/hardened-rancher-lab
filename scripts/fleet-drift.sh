#!/bin/bash
# 製造／還原 Fleet 組態漂移，用來展示 Rancher Continuous Delivery 的 Modified 狀態。
#   on     ：把目標叢集上由 Fleet 派送的 ${NS}/${DEPLOY} 改成 1 個副本
#            → Fleet 偵測到與 Git 不一致，BundleDeployment 狀態變成 Modified
#   off    ：改回 Git 裡的副本數（GIT_REPLICAS）→ 回到 Ready
#   status ：只讀，列出副本數與 GitRepo／BundleDeployment 狀態
# 每一條 kubectl 都明確指定 kubeconfig；修改只發生在 TARGET_KUBECONFIG 指向的叢集。
# 前提：GitRepo 沒有開 correctDrift，否則 on 之後 Fleet 會自動改回。
#
# 環境變數：
#   TARGET_KUBECONFIG  （必填）被製造漂移的下游叢集 kubeconfig
#   MGMT_KUBECONFIG    （必填）Rancher 管理叢集 kubeconfig，只用來讀 Fleet 狀態
#   TARGET_CLUSTER     目標叢集在 Rancher 的名稱，用來挑出它的 BundleDeployment（預設 dr-sim）
#   GITREPO            fleet-default 裡的 GitRepo 名稱（預設 platform-baseline）
#   NS／DEPLOY         被改的命名空間與 Deployment（預設 hardened-fleet-deployments／redis-slave，
#                      對應 rancher/fleet-examples 的 hardened 範例）
#   GIT_REPLICAS       Git 裡的副本數（預設 2）
set -euo pipefail
: "${TARGET_KUBECONFIG:?請設定 TARGET_KUBECONFIG}"
: "${MGMT_KUBECONFIG:?請設定 MGMT_KUBECONFIG}"
TARGET_CLUSTER="${TARGET_CLUSTER:-dr-sim}"
GITREPO="${GITREPO:-platform-baseline}"
NS="${NS:-hardened-fleet-deployments}"
DEPLOY="${DEPLOY:-redis-slave}"
GIT_REPLICAS="${GIT_REPLICAS:-2}"

status() {
  echo "${TARGET_CLUSTER} ${NS}/${DEPLOY} replicas: $(kubectl --kubeconfig "$TARGET_KUBECONFIG" -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.replicas}')"
  kubectl --kubeconfig "$MGMT_KUBECONFIG" -n fleet-default get gitrepo "$GITREPO" \
    -o jsonpath='GitRepo ready={.status.readyClusters}/{.status.desiredReadyClusters} {.status.display.state}{"\n"}'
  kubectl --kubeconfig "$MGMT_KUBECONFIG" get bundledeployments -A -l "fleet.cattle.io/repo-name=${GITREPO}" \
    -o 'custom-columns=CLUSTER-NS:.metadata.namespace,STATE:.status.display.state,MESSAGE:.status.display.message'
}

wait_state() { # $1 = 期待目標叢集的 BundleDeployment 出現的狀態
  local s=""
  for _ in $(seq 1 30); do
    s=$(kubectl --kubeconfig "$MGMT_KUBECONFIG" get bundledeployments -A -l "fleet.cattle.io/repo-name=${GITREPO}" \
          -o jsonpath='{range .items[*]}{.metadata.namespace}={.status.display.state}{"\n"}{end}' | grep -- "$TARGET_CLUSTER" | cut -d= -f2 || true)
    [ "$s" = "$1" ] && return 0
    sleep 5
  done
  echo "等了 150 秒，${TARGET_CLUSTER} 的 BundleDeployment 仍不是 $1（目前：${s:-未知}）" >&2
  return 1
}

case "${1:-status}" in
  on)
    kubectl --kubeconfig "$TARGET_KUBECONFIG" -n "$NS" scale deploy "$DEPLOY" --replicas=1
    wait_state Modified || true
    status
    ;;
  off)
    kubectl --kubeconfig "$TARGET_KUBECONFIG" -n "$NS" scale deploy "$DEPLOY" --replicas="$GIT_REPLICAS"
    wait_state Ready || true
    status
    ;;
  status) status ;;
  *) echo "用法：$0 on|off|status" >&2; exit 2 ;;
esac
