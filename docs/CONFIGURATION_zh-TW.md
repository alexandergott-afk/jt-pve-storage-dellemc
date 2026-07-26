# 設定參數說明

English: [CONFIGURATION.md](CONFIGURATION.md)

所有 Dell EMC block 系列共通的選項使用 `dell-` 前綴，PowerStore 專屬選項使用 `pstore-`。PVE 的 storage property 註冊在同一份共用 schema，同一個名稱在所有外掛之間只能有一種定義，前綴就是為此而存在。

## 共通選項

| 選項 | 型別 | 必填 | 預設 | 說明 |
|---|---|---|---|---|
| `dell-portal` | string | 是，且不可變更 | — | 陣列的管理 IP 或 FQDN，儲存建立後不能改 |
| `dell-username` | string | 是 | — | REST API 帳號 |
| `dell-password` | string | 是 | — | REST API 密碼 |
| `dell-ssl-verify` | boolean | 否 | `0` | 是否驗證陣列的 TLS 憑證 |
| `dell-protocol` | `iscsi` \| `fc` | 否 | `iscsi` | SAN 協定 |
| `dell-host-mode` | `per-node` \| `shared` | 否 | `per-node` | 每個節點一個 host 物件，或整個叢集共用一個 |
| `dell-cluster-name` | string | 否 | `pve` | host 物件命名所使用的叢集名稱 |
| `dell-device-timeout` | 10–300 | 否 | `60` | 等待 volume 裝置出現的秒數 |
| `dell-portal-probe-timeout` | 0–30 | 否 | `2` | 每個 iSCSI portal 的 TCP 預檢秒數，0 表示停用 |
| `dell-status-timeout` | 2–60 | 否 | `5` | pvestatd 健康路徑的 REST 逾時 |
| `dell-activate-deadline` | 0–300 | 否 | `30` | portal 登入迴圈的總時間預算，0 表示停用 |
| `dell-rollback-any-snapshot` | 布林 | 否 | `0` | 允許還原到「不是最新」的快照。預設關閉：Dell 沒有說明還原之後，那些在目標快照之後才建立的快照會怎麼樣；若陣列會把它們清掉，PVE 仍會繼續列出已經不存在的還原點 |
| `dell-config-backup` | 布林 | 否 | `1` | 每次快照時，把 VM 設定另外寫進一個 1 MB 的 volume。每次對 VM 做快照都會多用掉一個 volume，因此當陣列的 volume 數量是瓶頸時請關閉它。PowerVault ME 不提供此功能，設了也不會生效 |
| `dell-config-backup-timeout` | 5–60 | 否 | `15` | 等待 config 備份卷裝置的秒數 |
| `dell-rescan-interval` | 0–3600 | 否 | `300` | 週期性 SAN 重新掃描的最小間隔，0 表示每次都掃 |

## PowerStore 專屬選項

| 選項 | 型別 | 必填 | 預設 | 說明 |
|---|---|---|---|---|
| `pstore-appliance` | string | 否 | — | 多 appliance 叢集中，新 volume 要放在哪一台。留空由 PowerStore 自行決定 |
| `pstore-volume-group` | string | 否 | — | 把所有 volume 放進指定的 volume group，該群組必須已存在 |
| `pstore-performance-policy` | `High` \| `Medium` \| `Low` | 否 | `Medium` | 新 volume 的效能原則 |
| `pstore-protection-policy` | string | 否 | — | 套用 protection policy（快照與複寫規則），必須已存在 |
| `pstore-lun-id-base` | 1–200 | 否 | `1` | 外掛配發 LUN ID 的起始值 |

## PowerVault ME 專屬選項

由 `dellpowervault` type 使用，涵蓋 ME4 與 ME5 系列。

| 選項 | 型別 | 必填 | 預設 | 說明 |
|---|---|---|---|---|
| `pvault-pool` | string | 否 | — | 新 volume 建立在哪個 pool。陣列有多個 pool 時為必填 |
| `pvault-volume-group` | string | 否 | — | 把所有 volume 放進指定的 volume group，該群組必須已存在 |
| `pvault-tier-affinity` | `no-affinity` \| `archive` \| `performance` | 否 | `no-affinity` | 新 volume 的分層親和性 |
| `pvault-lun-id-base` | 1–200 | 否 | `1` | 外掛配發 LUN ID 的起始值 |

### 命名限制是這個系列最主要的約束

PowerVault 的 volume 與 snapshot 名稱**上限為 32 bytes**，而且 volume 名稱不允許出現句點 —— 這兩點都記載於 ME5 CLI Reference Guide。因此外掛在這個系列使用較短的名稱（`pve-me5-100-d0`），並把 storeid 的額度限制在 **10 個字元**。

若 storeid 長到放不下，外掛會在建立時直接報錯，而不是產生一個被截斷、可能與其他 VM 的 volume 撞名的名稱。在這個系列請使用簡短的 storage id。

## PVE 標準選項

`nodes`、`disable`、`content`、`shared` 全部為選填。要放 VM 磁碟與容器根檔案系統請設 `content images,rootdir`；叢集環境請設 `shared 1`。

## 範例

`/etc/pve/storage.cfg`：

```
dellpowerstore: ps1
    dell-portal 192.168.1.50
    dell-username pveadmin
    dell-password SecurePassword
    dell-protocol iscsi
    dell-host-mode per-node
    dell-cluster-name mycluster
    pstore-volume-group pve-vg
    content images,rootdir
    shared 1
```

Fibre Channel，並限定在有接上 fabric 的節點：

```
dellpowerstore: ps-fc
    dell-portal 192.168.1.50
    dell-username pveadmin
    dell-password SecurePassword
    dell-protocol fc
    nodes node1,node2
    content images
    shared 1
```

## 高負載時真正會影響結果的幾個選項

多數預設值不需要動。以下三個是在儲存出狀況之前值得先理解的。

### `dell-status-timeout`

PVE 大約每十秒輪詢一次所有儲存，而且是**依序**進行。一個要三十秒才回應的儲存，拖到的不只是自己，還包括排在它後面的每一個儲存 —— 那些儲存會在 GUI 顯示 `inactive`，儘管它們本身完全正常。

因此健康路徑使用較短的逾時，而且**只嘗試一次**。少了重試沒有任何損失：下一次輪詢本身就是重試。只有在陣列的管理網路確實很慢時才調高它，並且要預期整個輪詢週期會跟著變慢。

### `dell-activate-deadline`

每個 portal 各自有逾時限制，但整個迴圈沒有。一台公布八個 portal、其中三個可以建立 TCP 連線卻不再回應的陣列，可以讓 `activate_storage` 卡上好幾分鐘。

當預算用盡**且至少已有一條路徑可用**時，剩下的 portal 會延後到下一次啟用，並以警告列出是哪幾個。零路徑時絕不套用這個預算：一條路徑都沒有的情況下，儲存應該誠實地失敗，而不是回報成功。

### `dell-rescan-interval`

`activate_storage` 每次輪詢都會執行。若無條件重新掃描 SAN，等於每台節點每分鐘要做六次全主機的 `multipathd reconfigure` 與 `udevadm trigger`，而那段時間往往正好有 VM 啟動或備份在嘗試探索裝置，device-mapper 會一直處於變動狀態。

只要本節點登入了新的 portal，仍然會**立即**重新掃描，所以新對應的 volume 不會被延遲。這個間隔只用來限制「為了其他管道對應進來的 volume」而做的週期性保險掃描。

## Host 模式

`per-node`（預設）為每個 PVE 節點註冊一個 host 物件，名稱為 `pve-{cluster}-{node}`。每個 volume 都會對應到所有節點，讓線上遷移不必先重新對應，陣列也能回報各節點的連線狀態。

`shared` 則為整個叢集註冊一個 host group。陣列上的物件較少，但陣列就無法分辨某條路徑屬於哪一台節點。

## 驗證設定

```bash
pvesm status                     # 容量與是否為 active
pvesm list ps1                   # PVE 認得的 volume
journalctl -t pvestatd | grep dellpowerstore    # 外掛輸出的訊息
```
