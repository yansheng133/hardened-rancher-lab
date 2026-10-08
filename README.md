# hardened-rancher-lab

在 AWS 上用 SLES 16 搭一套「hardened RKE2 ＋ Rancher」展示環境的自動化素材：建網路與 EC2、開關機、
下游叢集定義、監控與日誌的 values，以及在 **SELinux enforcing ＋ CIS profile** 下實際會踩到的幾個坑與修法。

> **僅供展示與學習。** 全部是單節點叢集，不是官方建議的拓撲，不適合正式環境。
>
> SELinux 相關做法已於 2026-10-07 在 SLES 16.0／RKE2 v1.35.8（hardened）＋rancher-selinux 0.10-1.sle 實測。

## 架構

| 角色 | EC2 名稱（預設） | 規格（預設） | 內容 |
|---|---|---|---|
| 管理端（A） | `${LAB_TAG}-mgmt` | m6i.2xlarge、200 GiB gp3、Elastic IP | 單節點 RKE2；Rancher、cert-manager（自建實驗室 CA）、SUSE Private Registry（Harbor）、local-path StorageClass |
| 下游 prod-sim（B） | `${LAB_TAG}-prod-1` | m6i.2xlarge、150 GiB gp3 | 由 Rancher 建立的 hardened RKE2：`profile: cis`、`selinux: true`、稽核日誌、`rancher-restricted` PSA、Cilium、Traefik；裝 rancher-monitoring、rancher-logging、rancher-compliance |
| 下游 dr-sim（C，選用） | `${LAB_TAG}-dr-1` | m6i.xlarge、100 GiB gp3 | 一般 RKE2（不開 CIS），用來展示 Fleet 多叢集派送與組態漂移 |

```
             你的電腦（OPEN_CIDR）
                   │ 22／443
   ┌───────────────┼──────────────────────────── VPC（預設 10.0.0.0/16）
   │   A: mgmt（EIP）── Rancher ── Registry                       │
   │        │  安全群組內互通（Rancher agent、拉映像檔）            │
   │   B: prod-sim（hardened）        C: dr-sim（選用）            │
   └───────────────────────────────────────────────────────────────┘
```

網址用 [sslip.io](https://sslip.io) 從 IP 推出主機名稱，例如 `rancher.192.0.2.10.sslip.io`、`registry.192.0.2.10.sslip.io`
（本文件的 IP 一律是 RFC 5737 的文件用位址，請換成自己的）。

測試時用的版本：SLES 16.0、RKE2 v1.35.8+rke2r1、Rancher v2.15.2、SUSE Private Registry 1.2.x、
rancher-monitoring 110.0.2、rancher-logging 110.0.0、local-path-provisioner v0.0.37。
版本請依 Rancher 與 Registry 的支援矩陣自行調整（Registry 對 Kubernetes 版本有限制，選 RKE2 版本前先查）。

## 目錄

```
scripts/
  step2-network-ec2.sh      建 VPC／子網路／IGW／路由／安全群組／EIP／EC2，預設 dry-run
  lab.sh                    三台 status／up／down，附每小時費用估算
  fleet-drift.sh            製造／還原 Fleet 組態漂移（Modified 畫面）
  registry-scan-summary.py  列出 Registry artifact 的 Trivy 掃描摘要、SBOM 與簽章
  n3-secret-scan.py         秘密外洩掃描（秘密只經 stdin）
  v5-check.py               Prometheus 歷史資料長度檢查
  v6-dev-user-check.sh      用受測使用者自己的 token 驗證專案角色權限邊界
manifests/
  local-path-storage.yaml               local-path-provisioner（映像檔改 registry.suse.com）
  monitoring-values.yaml                rancher-monitoring values
  logging-values.yaml                   rancher-logging values
  m2-traefik-podmonitor.yaml            Prometheus 抓 RKE2 內附 Traefik 的指標
  m2-traefik-metrics-netpol.yaml        CIS NetworkPolicy 下放行監控抓取
  m2-traffic-gen.yaml                   叢集內流量產生器
  m2-traefik-dashboard.yaml             Grafana 儀表板「Ingress / Traefik」
  p5-central-log.yaml                   示範用 syslog 接收端＋ClusterOutput／ClusterFlow
  t4-project-role.yaml                  專案角色範本 payment-developer
  templates/prod-sim-cluster.yaml.tmpl  hardened 下游叢集定義（Registry 位址與 CA 用占位符）
  templates/dr-sim-cluster.yaml         一般下游叢集定義
  fallback-selinux/rancher-selinux-sle-logreader-fix.cil  rancher-selinux 0.10 SLE 政策的暫時補丁（見下文）
demo-app/
  app.py、Containerfile                 示範服務 payment-api（JSON 日誌＋HTTP）
```

## 前置需求

- AWS 帳號與 AWS CLI v2（身分用你自己的 `AWS_PROFILE` 或其他 CLI 設定；腳本不含任何憑證）
- 已在 AWS Marketplace 訂閱 SLES 16 BYOS 映像檔，並有自己的 SLES 註冊碼
- 事先建立或匯入的 EC2 key pair（預設名稱 `${LAB_TAG}-key`）
- Rancher 與 SUSE Private Registry 所需的訂閱與存取權限（依 SUSE 官方文件取得）
- 本機：`kubectl`、`helm`、`python3`（3.9 以上）、`envsubst`（gettext）

## 秘密處理原則

- repo 裡**沒有**任何密碼、token、註冊碼或憑證。
- 腳本需要的秘密一律從「使用者指定的檔案」或 stdin 讀，**不經命令列參數（argv）**，避免出現在行程清單與 shell 歷史。
- 暫存的 kubeconfig 權限 600，腳本結束即刪除。
- 白名單式 `.gitignore`：預設忽略全部，新增檔案要明確放行；`state/`、kubeconfig、金鑰不會被誤 commit。

## 步驟

### 1. 建網路與 EC2

```bash
export LAB_TAG=hardened-lab AWS_REGION=ap-northeast-1
export AMI=<SLES 16 BYOS 的 AMI ID>          # 查法見腳本檔頭
export OPEN_CIDR=192.0.2.50/32               # 你自己的對外 IP；不要隨手設 0.0.0.0/0
bash scripts/step2-network-ec2.sh            # dry-run，先看會做什麼
bash scripts/step2-network-ec2.sh --apply    # 真的建立（開始計費）
WITH_DR=1 bash scripts/step2-network-ec2.sh --apply   # 需要第三台 dr-sim 時
```

建立的資源 ID 記在 `state/resources.tsv`（不會進 Git）。

### 2. 節點準備（每台，root）

1. 用自己的註冊碼註冊 SLES 並更新套件（依 SUSE 文件操作；註冊碼不要寫進腳本或指令歷史）。
2. 確認 SELinux 為 enforcing。
3. **SELinux 政策套件：官方 rancher-selinux**（SLE 16 支援自 v0.10.production.1 起；見下面「SELinux 的三個坑」）。
   建立 `/etc/zypp/repos.d/rancher-selinux.repo`：
   ```ini
   [rancher-selinux]
   name=Rancher SELinux (production, SLE 16)
   baseurl=https://rpm.rancher.io/rancher/production/sle/16/noarch
   enabled=1
   gpgcheck=1
   gpgkey=https://rpm.rancher.io/public.key
   ```
   然後安裝（實測裝到 0.10-1.sle）：
   ```bash
   zypper --gpg-auto-import-keys refresh
   zypper install -y rancher-selinux
   ```
   要跑 rancher-logging 的節點，再加裝 rancher-selinux 0.10 SLE 政策的暫時補丁（原因見下文）：
   ```bash
   semodule -i manifests/fallback-selinux/rancher-selinux-sle-logreader-fix.cil
   ```
4. 會用到 local-path 的節點設定檔案標籤：
   ```bash
   semanage fcontext -a -t container_file_t "/opt/local-path-provisioner(/.*)?"
   mkdir -p /opt/local-path-provisioner && restorecon -Rv /opt/local-path-provisioner
   ```

### 3. 管理端 A

1. 安裝單節點 RKE2，建議設 `system-default-registry`，讓系統映像檔來自你指定的 registry。
2. `kubectl apply -f manifests/local-path-storage.yaml`，並設為預設 StorageClass。
3. 依官方文件安裝 cert-manager、Rancher、SUSE Private Registry。Registry 的憑證可用 cert-manager 自建的實驗室 CA 簽發。
4. 用 `scripts/lab.sh status` 確認狀態：
   ```bash
   RANCHER_HOST=rancher.192.0.2.10.sslip.io REGISTRY_HOST=registry.192.0.2.10.sslip.io bash scripts/lab.sh status
   ```

### 4. 下游叢集

```bash
export REGISTRY_HOST=registry.192.0.2.10.sslip.io
export REGISTRY_CA_BUNDLE_B64=$(base64 < lab-ca.crt | tr -d '\n')
envsubst '${REGISTRY_HOST} ${REGISTRY_CA_BUNDLE_B64}' < manifests/templates/prod-sim-cluster.yaml.tmpl \
  | kubectl --kubeconfig <管理叢集 kubeconfig> apply -f -
kubectl --kubeconfig <管理叢集 kubeconfig> apply -f manifests/templates/dr-sim-cluster.yaml   # 選用
```

Registry 的拉取帳密（建議用只能 pull 的機器人帳號）放在 `fleet-default/prod-sim-registry-auth` Secret，另行建立，不放進 Git。
接著在 Rancher 介面複製各叢集的註冊指令，到 B、C 上執行。

### 5. 監控、日誌與示範工作負載（prod-sim）

1. 從 Rancher「Apps」安裝 rancher-monitoring（`manifests/monitoring-values.yaml`）與 rancher-logging（`manifests/logging-values.yaml`）。
2. Traefik 指標與儀表板：
   ```bash
   kubectl apply -f manifests/m2-traefik-metrics-netpol.yaml -f manifests/m2-traefik-podmonitor.yaml -f manifests/m2-traefik-dashboard.yaml
   ```
3. 建置並推送 `demo-app/`，在命名空間 `demo` 部署 payment-api 與 Ingress（主機名稱例如 `payment.192.0.2.20.sslip.io`）。
4. 改好 `m2-traffic-gen.yaml` 裡的 `PAYMENT_HOST` 後套用；日誌接收端套用 `p5-central-log.yaml`。
5. 專案權限：建 Rancher 專案、把 `demo` 移入，套用 `t4-project-role.yaml`，把測試使用者以 `payment-developer` 加入專案，再驗證：
   ```bash
   RANCHER_HOST=rancher.192.0.2.10.sslip.io CLUSTER_ID=<下游叢集 ID> RANCHER_CA_FILE=lab-ca.crt \
     bash scripts/v6-dev-user-check.sh < ~/.secrets/dev-user-password
   ```

### 6. 驗證與展示輔助

```bash
KUBECONFIG=<prod-sim kubeconfig> python3 -I scripts/v5-check.py --wait     # 等 Prometheus 累積 2 小時資料
REGISTRY_HOST=registry.192.0.2.10.sslip.io REGISTRY_CA_FILE=lab-ca.crt \
  python3 -I scripts/registry-scan-summary.py payment payment-api --wait < ~/.secrets/registry-password
TARGET_KUBECONFIG=<dr-sim kubeconfig> MGMT_KUBECONFIG=<管理叢集 kubeconfig> bash scripts/fleet-drift.sh on|off|status
<取出秘密的指令> | python3 -I scripts/n3-secret-scan.py ~/.zsh_history ./     # 檢查秘密有沒有外洩到檔案
```

### 7. 開關機

```bash
bash scripts/lab.sh down    # 只停機；EBS 與 Elastic IP 仍會計費
bash scripts/lab.sh up      # B、C 的公開 IP 會變，直連它們的 kubeconfig 要更新
```

## 每個 manifest 解決什麼問題

### SELinux 的三個坑

在 SELinux enforcing 的節點上，以下三件事的共同點是：**Pod 看起來是 Running 或只有部分功能壞掉，不一定會直接報錯**。

**1. local-path 的檔案標籤（`semanage fcontext`）**
local-path-provisioner 在 `/opt/local-path-provisioner` 底下建目錄給 PVC。這個路徑預設不是 `container_file_t`，
容器寫入時會 Permission denied，PVC 卡住。修法是 `semanage fcontext` 把該路徑標成 `container_file_t` 再 `restorecon`（見步驟 2）。
另外在 hardened 叢集上，helper Pod 用 hostPath，所以 `local-path-storage` 命名空間標成 PSA `privileged`
（只放寬這個命名空間，全叢集預設仍是 restricted）。

**2. rancher-logging 的 `rke_logreader_t`**
rancher-logging 開啟 SELinux 選項時，收集器（fluentbit）以 `rke_logreader_t` 執行。節點上沒有這個型別時：
不開 SELinux 選項 → 收集器以 `container_t` 執行，讀不到 `/var/log/containers`，一筆日誌都收不到（無聲失敗）；
開了 → 型別不存在，Pod CrashLoop。

- **做法**：節點安裝官方 **rancher-selinux**（提供 `rke_logreader_t`），values 設 `global.seLinux.enabled: true`（見 `logging-values.yaml`）。
- **但 rancher-selinux 0.10-1.sle 的 SLE 政策有缺漏**：與同版的 centos9 政策相比，`rke_logreader_t` 少了
  `self:tcp_socket listen`、對 `container_log_t`／`container_var_lib_t`／`var_log_t` 檔案的 `watch`，
  以及對 `syslogd_var_run_t`／`var_log_t` 檔案的 `map`。實測 fluentbit 因監聽 2020（metrics）被拒而 CrashLoop。
- **暫時補丁**：`manifests/fallback-selinux/rancher-selinux-sle-logreader-fix.cil` 只補上這幾條 centos9 版已有的規則，
  不多開任何權限，裝在 rancher-selinux 之上。上游修正後以 `semodule -r rancher-selinux-sle-logreader-fix` 移除。

**3. node-exporter 讀不到 `/proc/1/mountinfo`**
node-exporter 以 `container_t` 執行時，SELinux 拒絕它搜尋 PID 1（`init_t`）在 `/proc` 下的目錄，
filesystem collector 失敗，Grafana 的磁碟相關面板顯示 No data，但 Pod 是 Running。

- **做法**：節點安裝 **rancher-selinux**（提供 `prom_node_exporter_t`），rancher-monitoring 的 values 設 `global.seLinux.enabled: true`
  （見 `monitoring-values.yaml`）。node-exporter 容器會帶 `seLinuxOptions.type: prom_node_exporter_t`；
  實測行程 context 為 `prom_node_exporter_t`、`node_filesystem_*` 指標正常、0 筆 AVC，**不需要自寫政策**。

### Grafana `initChownData`

Grafana 的 init 容器 `init-chown-data` 只有 `CHOWN` capability，進不了 Grafana 自己建立的 700 權限子目錄。
PVC 裡已有資料時（例如升級或重啟後），Grafana 會卡在 `Init:CrashLoopBackOff`。
資料本來就屬 uid 472、Pod 也有 `fsGroup: 472`，所以 `monitoring-values.yaml` 把 `grafana.initChownData.enabled` 設為 `false`。
這個問題看起來很像 SELinux 標籤問題，但不是；對 PVC 目錄跑 `restorecon` 不會好。

### CIS NetworkPolicy 擋住監控抓取

RKE2 的 CIS profile 會在 `kube-system` 建立限制性的 NetworkPolicy（只放行同命名空間，以及 Traefik 的 web／websecure），
所以 Prometheus 抓 kube-system 裡元件的指標會逾時——Traefik 本身預設就有指標，不需要改它。

- `m2-traefik-podmonitor.yaml`：讓 Prometheus 抓 Traefik 的 metrics 埠（9100）。
- `m2-traefik-metrics-netpol.yaml`：只放行 `cattle-monitoring-system` 裡 `app.kubernetes.io/name=prometheus` 的 Pod 連 Traefik 的 metrics 埠，RKE2 的預設政策都不改。
- `m2-traffic-gen.yaml`：經叢集內的 `rke2-traefik` Service 持續打 Ingress（含 404），儀表板才有數字。
- `m2-traefik-dashboard.yaml`：Grafana 儀表板「Ingress / Traefik」，8 個面板（每秒請求數、p50／p95／p99 延遲、錯誤比例、連線數、回應碼分布）。

### 其他

- `local-path-storage.yaml`：上游 manifest，只把兩個映像檔換成 registry.suse.com 上的版本，並標記命名空間 PSA。
- `p5-central-log.yaml`：叢集內的示範 syslog 接收端（RFC5424 over TCP）＋指向它的 ClusterOutput（Rancher 介面支援的 syslog 類型）與 ClusterFlow。資料在 emptyDir，**不是正式的日誌平台**。
- `t4-project-role.yaml`：專案角色 `payment-developer`，可管理工作負載、看日誌；不可改配額、成員與 RBAC。用 `v6-dev-user-check.sh` 以使用者自己的 token（不是 `--as`）驗證。
- `templates/prod-sim-cluster.yaml.tmpl`：CIS profile、SELinux、etcd 指標、稽核政策與稽核日誌輪替、Registry 的驗證 Secret 與 CA（不略過 TLS 驗證）。

## SL Micro 6.1 下游叢集實測

同一套管理端，再接一組 **SUSE Linux Micro 6.1** 的下游叢集（三台控制平面加一台單節點，SELinux enforcing、CIS profile），
逐項驗證快照還原、不中斷升級、縮減至零、事件驅動擴縮、執行期防護、靜態加密等能力。
紀錄與工具在 [`docs/sl-micro-validation/`](docs/sl-micro-validation/)，最重要的三個結論：

- **Rancher 的 etcd 快照還原在 RKE2 v1.35.8 上做不完，v1.35.9 起可以。** 根因是 system-agent-installer 的 `restorecon`
  遇到正在被刪除的目錄就中止（上游 [rancher/rke2#11137](https://github.com/rancher/rke2/pull/11137) 已修正），和機器規格無關。
- **「不中斷升級」取決於外部負載平衡器的健康檢查。** 1 秒×1 次只掉 1／約 3700 筆；5 秒×2 次、10 秒×3 次分別掉 30～75 筆。
- **SL Micro 預設每天自動更新，有新套件就在維護時段自己重開機**，正式環境要先決定怎麼管理。

## 已知限制

- **單節點、非官方建議拓撲，僅供展示。** Rancher、Registry 與各元件都是單副本，沒有高可用；Registry 官方要求的節點數也沒有滿足。
- 管理端只有 A 掛 Elastic IP；B、C 停機再開機後公開 IP 會變。
- `fallback-selinux/rancher-selinux-sle-logreader-fix.cil` 是針對 rancher-selinux 0.10-1.sle 的暫時補丁；升級 rancher-selinux 後請確認上游是否已修正，修正後就移除。
- 費用估算（`lab.sh`）的單價是某一時點的查詢值，請依自己的區域與時間更新。
- `fleet-drift.sh` 預設對應 rancher/fleet-examples 的 `hardened` 範例；該範例使用的映像檔不一定來自 SUSE 來源，請自行評估。
- 若用 cosign 3.x 簽章，預設會把簽章資訊上傳到公開的 Rekor 透明度紀錄（等於公開映像檔 digest 與 Registry 網址），實驗環境請自行決定是否關閉。

## 授權

Apache License 2.0，見 [LICENSE](LICENSE)。
