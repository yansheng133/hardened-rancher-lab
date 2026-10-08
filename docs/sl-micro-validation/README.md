# SL Micro 6.1 上的 hardened RKE2：快照還原為什麼失敗、升級會掉幾筆請求，以及其他 10 項實測

## 這篇在講什麼

[上一篇](https://hackmd.io/@yansheng133/rkTu14Qofe)在 SLES 16 上建了 hardened RKE2。這一篇把下游叢集換成 **SUSE Linux Micro 6.1**（三台控制平面加一台單節點叢集，SELinux enforcing、CIS profile），一項一項驗證一份架構建議書裡寫的能力。重點有三個：

1. **Rancher 的 etcd 快照還原在 RKE2 v1.35.8 上做不完，v1.35.9 就可以。** 根因是安裝腳本裡 `restorecon` 的錯誤處理；上游已經修了，但很容易誤判成「機器太小、太慢」。
2. **「不中斷升級」成不成立，取決於外部負載平衡器的健康檢查。** 同時跑三組不同設定，量兩次升級，數字很穩定。
3. **每個數字都先驗證過量具。** 這次有兩次是量具本身出錯，靠事先寫好的檢查擋下來。

> 環境：SL Micro 6.1（kernel 6.4）、RKE2 v1.35.7～v1.35.9（`profile: cis`、`selinux: true`）、Cilium 1.19、Traefik 3、Rancher 2.15.2。每台 2 vCPU／8 GiB（m6i.large）。範例位址一律是 192.0.2.x。

## 結果總表

| 項目 | 結果 | 數字 |
|---|---|---|
| etcd 快照還原（Rancher） | v1.35.8 做不到；**v1.35.9 做到** | v1.35.8：0/4（2 vCPU）、1/2（4 vCPU）；v1.35.9：**3/3**（2 vCPU，約 6.5～7.3 分鐘） |
| 不中斷升級 | 取決於健康檢查 | 兩次升級各約 11 分鐘；健康檢查 1 秒×1 次：失敗 1/3687、1/3742；5 秒×2 次：40、32 筆；10 秒×3 次：75、64 筆 |
| 縮減至零後的首個請求（Knative） | 搭配預先拉取可在 3 秒內 | 10/10 在 3 秒內，中位數 1.29 秒；沒預拉時中位數 8.14 秒 |
| HPA 擴縮反應時間 | 秒級，做不到毫秒級 | 同步週期 15 秒：中位數 7.62 秒；改 5 秒：3.93 秒 |
| 執行期行程阻斷（NeuVector 5.6.2） | 不是 100% 阻斷 | 短命指令 8/10～10/10 照常完成，事件一律記成 deny |
| 映像檔簽章驗證 | cosign v3 要加相容旗標 | v3 預設格式驗不過；加兩個旗標後可以 |
| Secret 靜態加密與 TLS 套件 | 既有叢集上可改 | 41/41 個 Secret 改為 secretbox；各端點只剩 ECDHE＋AEAD |
| gVisor | 與 SELinux 不相容 | 要嘛關掉該節點 RKE2 的 SELinux 整合，要嘛關掉作業系統的 SELinux |
| 叢集從零重建（Fleet） | 可行 | 單節點從移除到應用有回應：4 分 50 秒～5 分 18 秒 |

---

## 1. 快照還原：v1.35.8 為什麼一直失敗

### 症狀

在 Rancher 對 etcd 快照按 Restore，不論選哪一種還原類型，叢集都會停在：

```
configuring bootstrap node(s) custom-xxxx: error applying plan -- check rancher-system-agent.service and rke2-server.service logs on node
```

etcd 資料其實已經還原成功：快照前放的標記還在、快照後的不見了。但只剩第一台節點 Ready，另外兩台 NotReady，而且不會自己恢復。重啟服務、再觸發一次還原，都在同一個位置失敗。

### 節點日誌

```
[INFO]  applying correct SELinux contexts to RKE2 files
restorecon: Could not read /var/lib/rancher/rke2/agent/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/758: No such file or directory.
[Applyinator] Command sh [-c run.sh] finished with err: <nil> and exit code: 255
error syncing 'fleet-default/custom-xxxx-machine-plan': handler secret-watch: secret received was too old, requeuing
```

### 時序

| 時間 | 發生的事 |
|---|---|
| T+0 | 第一次跑安裝腳本，「套用 SELinux 標籤」7 秒內成功 |
| T+7 秒～T+3 分 | 執行 etcd 還原、重新啟動 rke2 |
| T+3 分 | Rancher 的計畫執行 `post-restore-cleanup-pods`，刪掉一批 Pod；containerd 開始在背景刪這些 Pod 的 snapshot 目錄 |
| T+3 分 17 秒 | 計畫**沒等清理結束**就重跑安裝腳本；`restorecon -R -i /var/lib/rancher/rke2` 掃到一半，目錄消失 → 非 0 結束 → 安裝腳本在 `set -e` 下中止 |
| 之後 | 失敗回報因 plan secret 版本衝突（`secret received was too old`）遺失，system-agent 不會重試 |

`restorecon -R` 要掃約 15 萬個檔案，閒置時約 3 秒（2 vCPU），還原期間更久。`-i` 只略過「起點就不存在」的路徑，掃描**途中**消失的目錄照樣報錯。

### 是資源不夠嗎？

這是第一個直覺：機器太慢，兩件事重疊的時間就長。所以把三台控制平面暫時升到 4 vCPU／16 GiB 再測：**1 次成功、1 次失敗，原因相同**。資源多一點可能讓它比較不容易發生，但不能消除。

### 真正的原因與修正

實際執行的不是 RKE2 原始碼標籤裡的 `install.sh`，而是 Rancher 的 **`system-agent-installer-rke2` 映像檔**裡的那一份。把 v1.35.8 的映像檔取出來看：

```sh
do_restorecon_tar() {
    ...
            restorecon -R -i /opt/rke2
            ...
            if [ -n "${INSTALL_RKE2_ARTIFACT_PATH}" ]; then
                restorecon -R -i /var/lib/rancher/rke2     # set -e 下，失敗就整個中止
            fi
```

上游 [rancher/rke2#11137](https://github.com/rancher/rke2/pull/11137)（2026-09-02 合併）把這段改成在 `set +e` 的子殼層裡執行，最後加 `|| true`，出錯只警告、繼續安裝。v1.35.8 的 installer 映像檔是 2026-08-28 建置的，沒有這個修正；**v1.35.9、v1.36.5、v1.37.1** 的 installer（2026-09-30 建置）都有。

怎麼自己確認手上的版本有沒有修正（不需要執行容器）：

```bash
I=registry.rancher.com/rancher/system-agent-installer-rke2:v1.35.9-rke2r1
podman pull -q "$I" >/dev/null
c=$(podman create --entrypoint /installer.sh "$I")
podman cp "$c":/installer.sh ./installer.sh && podman rm "$c" >/dev/null
sed -n '/do_restorecon_tar()/,/^}/p' installer.sh | grep -E 'set \+e|\|\| true'   # 有輸出＝含修正
```

### 驗證

升到 v1.35.9 後，用**原規格 2 vCPU** 做三次「Only etcd」還原：**3/3 成功**，每次 387～438 秒，資料與應用都正確，沒有人工介入。日誌顯示這三次裡 restorecon **仍然撞上兩次**同樣的目錄消失，只是安裝不再中止。所以：

- 競態本身還在，跟機器規格無關；
- 決定成敗的是安裝腳本的版本；
- 「失敗回報遺失、agent 不重試」這一點上游還沒修。萬一再卡住，處置方式是重建叢集，再還原應用資料。

> 寫進文件的說法：「RKE2 需 v1.35.9 以上（含 rancher/rke2#11137），可透過 Rancher 以 etcd 快照還原叢集。」不要寫「升級前自動快照」：Rancher／RKE2 升級前**不會**自動建快照，要由管理者自己建，或用排程建。

---

## 2. 不中斷升級：健康檢查間隔決定掉幾筆

### 量法

在叢集外的一台機器上，同時跑三組模擬負載平衡器。三組只差在健康檢查，都是一次成功就放回：

| 組 | 檢查間隔 | 連續失敗幾次剔除 |
|---|---|---|
| A | 1 秒 | 1 |
| B | 5 秒 | 2 |
| C | 10 秒 | 3 |

每組每 0.2 秒送一個請求，輪流送到目前判定健康的節點（打到 Traefik，主機名稱路由到 3 副本的示範服務）。另外每秒對每台的 6443 發一次請求，量 API Server 的可用性。

### 先驗證量具

升級前，在一台節點上用 iptables 讓它的 80 埠**拒絕連線 60 秒**，確認三組都真的記到失敗、也都在各自的門檻後把那台剔除：

| 組 | 失敗筆數 | 單節點最長連續失敗 | 判定剔除的時間 |
|---|---|---|---|
| A | 1 | — | 拒絕後約 1 秒 |
| B | 14～15 | 7.9～8.5 秒 | 約 10 秒（5 秒×2） |
| C | 47～49 | 27.9～29.0 秒 | 約 30 秒（10 秒×3） |

跟設計值吻合，量具才算可信。

### 升級結果（三台控制平面，逐台 drain）

| | 第一次（v1.35.7→v1.35.8） | 第二次（v1.35.8→v1.35.9） |
|---|---|---|
| 升級耗時 | 636 秒 | 653 秒 |
| A 1 秒×1 次 | 失敗 1/3687 | 失敗 1/3742 |
| B 5 秒×2 次 | 失敗 40/3688（單節點最長連續 7.3 秒） | 失敗 32/3739（6.5 秒） |
| C 10 秒×3 次 | 失敗 75/3696（26.8 秒） | 失敗 64/3747（21.7 秒） |
| 不經健康檢查，被 drain 那台的入口中斷 | 192 秒 | 189 秒 |
| API Server 三台同時無回應 | 0 秒 | 0 秒 |

掉的請求來自 Traefik 逐台重啟、負載平衡器還沒發現那台已經不能用的那段時間。**健康檢查 1 秒、1 次失敗就剔除，幾乎不掉；5 秒或 10 秒的常見預設值都會掉。** 寫文件時，「不中斷」要附上健康檢查條件。

---

## 3. Knative 縮減至零：預先拉取要連 sidecar 一起拉

同一個 Knative Service（92 MB 的 BCI Python 映像檔）縮到零後的第一個請求，從叢集內經 Kourier 量 `curl time_total`：

| 條件 | 10 次中位數 | 範圍 |
|---|---|---|
| 映像檔已在節點 | 1.29 秒 | 1.07～1.73 秒 |
| 映像檔不在節點（三台都刪光，含以 digest 參照的那份） | 8.14 秒 | 7.16～8.45 秒 |
| **DaemonSet 預先拉取後**，Pod 輪流落在三台 | **1.29 秒** | **1.12～1.99 秒（10/10 在 3 秒內）** |

兩個陷阱：

1. **Knative 用 digest 固定映像檔。** 只用 tag 刪除，會留下 `<none>` 的 digest 副本，量到的「冷啟動」其實是熱的。要依 IMAGE ID 全部刪掉。
2. **只預拉應用映像檔不夠。** Knative 會替每個 Pod 自動注入 queue-proxy sidecar，它的映像檔第一次也要現拉。實測第一次因此花了 7.7 秒，其中現拉 5.9 秒。queue-proxy 是 distroless，沒辦法當成常駐容器，改用 Kubernetes 1.35 的 **image volume** 讓 kubelet 拉取並持續引用：

```yaml
containers:
- name: hold
  image: registry.suse.com/bci/python@sha256:<revision 的 imageDigest>
  command: ["sleep", "infinity"]
  volumeMounts: [{name: queue-proxy-image, mountPath: /prepull/queue, readOnly: true}]
volumes:
- name: queue-proxy-image
  image: {reference: "gcr.io/knative-releases/knative.dev/serving/cmd/queue@sha256:<config-deployment 的 queue-sidecar-image>", pullPolicy: IfNotPresent}
```

在 SELinux enforcing、containerd 2.2 下實測可用。完整 manifest 見 [`tools/c3-prepull-ds.yaml`](tools/c3-prepull-ds.yaml)。

---

## 4. HPA：同步週期 5 秒，反應時間減半

KEDA 2.21 的 metrics-api scaler 輪詢一個代表佇列長度的服務。「事件」是把佇列長度從 0 設成 2，量到第 2 個 Pod Ready 為止，隨機相位各 10 次：

| `--horizontal-pod-autoscaler-sync-period` | 中位數 | 範圍 | controller-manager 閒置 CPU |
|---|---|---|---|
| 15s（預設） | 7.62 秒 | 3.35～15.78 秒 | 7.0 mCPU |
| 5s | 3.93 秒 | 1.45～5.92 秒 | 6.8 mCPU |

單節點叢集、負載輕，大叢集上的 CPU 影響沒有量。設定方式要注意：

- 第一版連續 10 次的週期剛好是 60 秒，跟 15 秒的同步週期鎖在同一個相位，數字集中在 11～13 秒。每次之間要加隨機延遲。
- Rancher 管理的節點，`/etc/rancher/rke2/config.yaml.d/50-rancher.yaml` 裡已經有 `kube-controller-manager-arg`。另外加檔案時要寫成 **`kube-controller-manager-arg+:`**（附加），否則會把整組參數蓋掉。

---

## 5. NeuVector 5.6.2 的執行期阻斷：不是 100%

Protect 模式下，對一個只學到 `pause`、`python3` 的工作負載，用 `kubectl exec` 執行沒學過的指令，各 10 次：

| 指令 | 結果 |
|---|---|
| `date` | 10/10 照常完成 |
| `echo hi` | 8/10 完成 |
| `cat` 小檔 | 8/10 完成並輸出內容 |
| `ls /` | 8/10 被砍（exit 137） |
| `touch` 寫檔 | 8/10 檔案仍被建立 |
| `cat` 大檔、`/dev/zero` | 10/10 被砍，但砍之前已經輸出 64～393 KB |
| `sleep 5` | 3/3 在約 0.65 秒被砍 |

**事件一律記成 deny／execution denied。** 原因（GitHub [issue #2750](https://github.com/neuvector/neuvector/issues/2750)、PR #2862，修正目前只在 v5.6.3-rc1）：5.6.2 的第一層（fanotify，exec 之前就拒絕）幾乎沒作用，所以全部落到第二層，也就是行程啟動後才送 SIGKILL。事件又是在 kill 之前送出的，所以短命行程跑完了，事件照樣寫 deny。

驗收時看「行程與副作用有沒有真的發生」，不要只看事件。

### cosign v3 的簽章

NeuVector／SUSE Security 文件寫明只支援 cosign v2 產生的簽章。cosign v3 預設會產生 Sigstore bundle，放在 OCI 1.1 referrer，NeuVector 找不到。用 v3 簽時**同時**加上這兩個旗標，就會產生舊的 `.sig` tag 格式，實測可以驗證並放行：

```bash
cosign sign --new-bundle-format=false --use-signing-config=false --key cosign.key <image>@sha256:<digest>
```

這兩個旗標在 v3.1 已標為 deprecated，`--help` 裡看不到，v4 會移除，屬於長期風險。

---

## 6. 靜態加密與 TLS 套件：既有叢集上可以改，但 Rancher 的欄位有一個不會生效

| 設定 | 怎麼改 | 實測 |
|---|---|---|
| Secret 加密 aescbc → secretbox | RKE2 `secrets-encryption-provider: secretbox`，重啟後 `rke2 secrets-encrypt rotate-keys` | 41/41 個 Secret 前綴變成 `k8s:enc:secretbox:v1:` |
| kubelet 套件 | `kubelet-arg: tls-cipher-suites=…` | 只剩 ECDHE＋GCM／ChaCha20 |
| etcd 套件 | `etcd-arg: cipher-suites=[A,B,…]`（**要寫成陣列格式**） | 同上 |
| Traefik 套件 | rke2-traefik 的 `tlsOptions.default.cipherSuites` | 同上 |

坑：

- Rancher 叢集定義裡 `machineGlobalConfig.secrets-encryption-provider` **不會**傳到節點的 50-rancher.yaml，要在節點本機加 `config.yaml.d/60-secretbox.yaml`。
- RKE2 是把 `etcd-arg` 轉寫進 etcd 的設定檔，所以套件清單要用 `[...]` 陣列格式。這一點文件沒寫，是查原始碼才知道的。

---

## 7. SL Micro 6.1 特有的坑

| 坑 | 症狀 | 處理 |
|---|---|---|
| 預設帳號是 `ec2-user` | 照文件用 `suse` 登不進去 | — |
| `/opt/cni/bin` 標籤錯 | Cilium 複製 CNI 外掛被拒，所有 Pod ContainerCreating | 節點加入前 `mkdir -p /opt/cni/bin && restorecon -R /opt/cni` |
| `rke2-uninstall.sh` 會 `semodule -r rke2` | rke2-selinux 是 RPM、看起來還裝著，模組卻沒了；重裝後 etcd 起不來（`write /proc/self/attr/keycreate: invalid argument`） | 重裝前 `semodule -i /usr/share/selinux/packages/rke2.pp` 加 restorecon |
| **每天自動更新並重開機** | `transactional-update.timer` 有新套件就建快照，rebootmgr 在維護時段（預設 UTC 03:30 起 1.5 小時）自己重開 | 正式環境要關閉、改時段，或交給 system-upgrade-controller 的 Plan 統一管理；長時間量測前看 `rebootmgrctl status` |
| rancher-selinux 裝不上 | 0.10 要 container-selinux ≥ 2.246，SL Micro 6.1 只有 2.236 → Rancher Logging 收集器讀不到容器日誌 | SL Micro 6.1 上沒有相依符合的現行版本；要收日誌，節點改用 SLES 16 |
| gVisor 起不來 | runsc：`SELinux is not supported`，permissive 也沒用 | 只關該節點 RKE2 的 `selinux`（同節點所有容器都變成 `spc_t`），或關掉作業系統的 SELinux；要另設沙箱節點池並評估取捨 |

---

## 8. 量測方法的教訓

1. **先讓量具失敗一次。** 升級前讓一台入口拒絕連線，確認三組都記到失敗、都按門檻剔除。後來有一次流量產生器沒有真的同時在跑，這個檢查記到 0 筆失敗，自動擋下了升級。
2. **`ssh host 'cmd &'` 會等背景行程結束才返回。** 遠端用 `nohup … &` 啟動的行程，ssh 一樣會等它。改用 `ssh -f`，並等遠端的輸出檔出現之後才開始計時。
3. **輪流送請求時，「最長連續失敗」要依節點算。** 依整條請求序列算，失敗之間夾著別台的成功，結果永遠是 0 秒。
4. **量時間的項目不要跟別的測試同時跑。** 沒有 PVC 的 Prometheus 曾經讓一台控制平面的 iowait 到 49%，etcd 變慢，apiserver 重啟 4 次。
5. **「我猜是 X」要做一個只改 X 的對照組。** 「資源不夠」這個假設，靠「只換機型」和「只換版本」各做一組，結論就很清楚：換機型只是降低機率，換版本才真的修好。

---

## 工具

| 檔案 | 用途 |
|---|---|
| [`tools/d1-traffic3.py`](tools/d1-traffic3.py) | 叢集外流量產生器：三組不同健康檢查的模擬負載平衡器，加上各節點與 API Server 的可用性（`LB_NODES`、`LB_HOST` 設定目標） |
| [`tools/traffic3-summary.py`](tools/traffic3-summary.py) | 統計：每組的請求數、失敗數、p99、單節點最長連續失敗、健康檢查判定 DOWN 的區間 |
| [`tools/c3-prepull-ds.yaml`](tools/c3-prepull-ds.yaml) | Knative 縮減至零的預先拉取 DaemonSet（應用映像檔加 queue-proxy image volume） |
| [`tools/c2-keda.yaml`](tools/c2-keda.yaml)、[`tools/c-scale-measure.node.py`](tools/c-scale-measure.node.py) | KEDA 事件驅動擴縮的量測：佇列服務、worker、ScaledObject，以及在控制平面節點上以 API watch 計時的量測程式 |
| [`tools/a6-cipher-scan.node.sh`](tools/a6-cipher-scan.node.sh) | 在節點本機逐一測 kubelet、etcd、apiserver、Traefik 接受哪些 TLS 1.2 加密套件，並檢查 Secret 在 etcd 的加密前綴 |

量具驗證的做法（升級前讓一台入口拒絕連線 60 秒），在節點上：

```bash
RULE='-p tcp --dport 80 -j REJECT --reject-with tcp-reset'
RULEF='-p tcp -m conntrack --ctorigdstport 80 --ctstate NEW -j REJECT --reject-with tcp-reset'
sudo iptables -I INPUT $RULE; sudo iptables -I FORWARD $RULEF     # Traefik 以 hostPort 提供入口，要連 FORWARD 一起擋
sleep 60
sudo iptables -D INPUT $RULE; sudo iptables -D FORWARD $RULEF
```

系列文（HackMD）：
- [SL Micro 6.1 上的 hardened RKE2 實測（本文）](https://hackmd.io/@yansheng133/sl-micro-rke2-validation)
- [SLES 16 上跑 hardened RKE2：三個 SELinux 坑](https://hackmd.io/@yansheng133/rkTu14Qofe)
- [用 kubectl 建 Rancher 2.15 custom cluster 的坑](https://hackmd.io/@yansheng133/HyW3yEXjGx)
- [單節點 SUSE Private Registry：0 弱點映像檔、SBOM 與 cosign 簽章](https://hackmd.io/@yansheng133/Skt7xEXsMg)
