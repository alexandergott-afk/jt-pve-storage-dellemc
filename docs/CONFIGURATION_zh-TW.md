# 設定參數說明

English: [CONFIGURATION.md](CONFIGURATION.md)

所有 Dell EMC block 系列共通的選項使用 `dell-` 前綴，PowerStore 專屬選項使用 `pstore-`。PVE 的 storage property 註冊在同一份共用 schema，同一個名稱在所有外掛之間只能有一種定義，前綴就是為此而存在。

## 共通選項

| 選項 | 型別 | 必填 | 預設 | 說明 |
|---|---|---|---|---|
| `dell-portal` | string | 是，且不可變更 | — | 管理位址（可多個）；**儲存建立後不能修改**，所以在控制器各有管理 IP、沒有浮動位址的儲存伺服器上（PowerVault ME、Unity），請一開始就把兩個控制器都列入：`192.168.1.11,192.168.1.12`。控制器 failover 時用戶端會自行換到下一個位址；資料路徑不需要任何處理，dm-multipath 會自己接手 |
| `dell-username` | string | 是 | — | REST API 帳號 |
| `dell-password` | string | 是 | — | REST API 密碼 |
| `dell-ssl-verify` | boolean | 否 | `0` | 是否驗證儲存伺服器的 TLS 憑證 |
| `dell-protocol` | `iscsi` \| `fc` | 否 | `iscsi` | SAN 協定 |
| `dell-host-mode` | `per-node` \| `shared` | 否 | `per-node` | 每個節點一個 host 物件，或整個叢集共用一個 |
| `dell-cluster-name` | string | 否 | `pve` | host 物件命名所使用的叢集名稱 |
| `dell-device-timeout` | 10–300 | 否 | `60` | 等待 volume 裝置出現的秒數 |
| `dell-portal-probe-timeout` | 0–30 | 否 | `2` | 每個 iSCSI portal 的 TCP 預檢秒數，0 表示停用 |
| `dell-status-timeout` | 2–60 | 否 | `5` | pvestatd 健康路徑的 REST 逾時 |
| `dell-activate-deadline` | 0–300 | 否 | `30` | portal 登入迴圈的總時間預算，0 表示停用 |
| `dell-rollback-any-snapshot` | 布林 | 否 | `0` | 允許還原到「不是最新」的快照。預設關閉：Dell 沒有說明還原之後，那些在目標快照之後才建立的快照會怎麼樣；若儲存伺服器會把它們清掉，PVE 仍會繼續列出已經不存在的還原點 |
| `dell-config-backup` | 布林 | 否 | `1` | 每次快照時，把 VM 設定另外寫進一個 1 MB 的 volume。每次對 VM 做快照都會多用掉一個 volume，因此當儲存伺服器的 volume 數量是瓶頸時請關閉它。PowerVault ME 不提供此功能，設了也不會生效 |
| `dell-config-backup-timeout` | 5–60 | 否 | `15` | 等待 config 備份卷裝置的秒數 |
| `dell-rescan-interval` | 0–3600 | 否 | `300` | 週期性 SAN 重新掃描的最小間隔，0 表示每次都掃 |

## 管理位址容錯：哪些儲存伺服器需要逗號

各儲存伺服器的管理介面在控制器故障時的行為不同，這決定 `dell-portal` 該怎麼填：

| 儲存伺服器 | 管理位址模型 | `dell-portal` 該填什麼 |
|---|---|---|
| **PowerVault ME4/ME5** | **每個控制器**各一個固定 IP（A、B），沒有虛擬位址。兩個管理控制器平時都會回應，但故障控制器的 IP 會**跟著它一起消失** —— 不會漂移到存活的那一邊 | **兩個控制器都填，逗號分隔**：`192.168.1.11,192.168.1.12` |
| PowerStore | 有浮動的叢集管理 IP | 填叢集 IP 即可 |
| Unity XT | **設計上就是一個浮動管理 IP** —— 它跟著主 SP 走，SP failover 後位址不變（failover 進行的那幾分鐘管理會暫停） | 填系統管理 IP 即可；逗號寫法可用但不需要 |
| PowerFlex | PowerFlex Manager / gateway 的 VIP | 填 VIP |

這等於把 NetApp 的 cluster-management LIF 或 Pure 的 `vir0` 在儲存伺服器端做的事，
搬到用戶端來做：PowerVault 根本沒有那種東西，所以由外掛負責移動。連線失敗時
它會換到下一個位址、重新認證（session 屬於簽發它的那個控制器），並停留在
答話的位址上。

三件要知道的事：

- **`dell-portal` 在儲存建立之後不能修改。** ME 請在 `pvesm add` 時就把兩個
  控制器都列入 —— 事故當下才想改就來不及了。
- **資料路徑完全不需要這些。** FC 與 iSCSI 隨時同時通到兩個控制器，
  dm-multipath 與 ALUA 自己處理控制器容錯，執行中的 guest 毫無感覺。本節
  只關於管理：狀態、配置、快照、刪除。
- **代價有上界。** 所有位址都死掉時，`pvesm status` 每個位址付一次短逾時
  （實測：`dell-status-timeout 2`、兩個位址共 4.0 秒），其他儲存不受拖累。

想在儲存伺服器上確認 ME 的兩個位址：`show network-parameters`。

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
| `pvault-pool` | string | 否 | — | 新 volume 建立在哪個 pool。儲存伺服器有多個 pool 時為必填 |
| `pvault-volume-group` | string | 否 | — | 把所有 volume 放進指定的 volume group，該群組必須已存在 |
| `pvault-tier-affinity` | `no-affinity` \| `archive` \| `performance` | 否 | `no-affinity` | 新 volume 的分層親和性 |
| `pvault-lun-id-base` | 1–200 | 否 | `1` | 外掛配發 LUN ID 的起始值 |

### 命名限制是這個系列最主要的約束

PowerVault 的 volume 與 snapshot 名稱**上限為 32 bytes**，而且 volume 名稱不允許出現句點 —— 這兩點都記載於 ME5 CLI Reference Guide。因此外掛在這個系列使用較短的名稱（`pve-me5-100-d0`），並把 storeid 的額度限制在 **10 個字元**。

若 storeid 長到放不下，外掛會在建立時直接報錯，而不是產生一個被截斷、可能與其他 VM 的 volume 撞名的名稱。在這個系列請使用簡短的 storage id。


## Unity XT（`dellunity`）

| 選項 | 型別 | 必填 | 預設 | 說明 |
|---|---|---|---|---|
| `unity-pool` | string | 否 | — | 新 LUN 建立在哪個儲存池。儲存伺服器有多個儲存池時為必填 |
| `unity-thin` | boolean | 否 | `1` | 建立精簡佈建的 LUN。儲存伺服器必須已授權精簡佈建 |

```bash
pvesm add dellunity unity480 \
    --dell-portal 10.0.0.10 \
    --dell-username admin --dell-password '...' \
    --dell-protocol fc \
    --unity-pool pool_1 \
    --content images,rootdir
```

### 這個系列有什麼不一樣

**這裡沒有任何一項在 Unity 儲存伺服器上執行過。** 逐項的說明請見
[TESTING_zh-TW.md](TESTING_zh-TW.md)。

- **以名稱直接向儲存伺服器詢問 LUN**，端點是 `/instances/lun/name:<名稱>`，而不是送
  server-side filter。其他每個系列都得用 filter，而一個未驗證的 filter 回傳空
  集合，跟「根本沒有這個東西」無法區分。
- **主機存取是取代而不是附加。** Unity 的 `hostAccess` 是「允許看到這顆 LUN 的
  完整主機清單」，所以對應本節點時會先讀出現況再送出聯集。這就是為什麼一次對應
  operations 會有兩趟往返而不是一趟。
- **連結複製是快照的精簡複製**，因此範本的標記快照必須比它的複製活得久，而儲存伺服器
  會拒絕刪除仍有存活複製的範本。
- **`unity-thin` 需要授權。** 如果儲存伺服器沒有精簡佈建的授權，請設為 `0`，否則儲存伺服器
  會拒絕建立。

## PowerFlex 專屬選項

由 `dellpowerflex` 型別使用。PowerFlex 的 volume 不是以 SCSI LUN 的形式送到主機，因此這裡完全用不到 multipath 相關選項；`dell-protocol` 在這個系列接受的是 `nvme`（預設）或 `sdc`，而不是 `iscsi` 或 `fc`。

| 選項 | 型別 | 必填 | 預設 | 說明 |
|---|---|---|---|---|
| `pflex-storage-pool` | 字串 | **是** | — | 建立新 volume 的儲存池。PowerFlex 沒有預設儲存池 |
| `pflex-protection-domain` | 字串 | 否 | — | 該儲存池所屬的保護網域。只有在多個網域中存在同名儲存池時才需要 |
| `pflex-nvme-ctrl-loss-tmo` | 0–600 | 否 | `60` | 失去 NVMe 控制器之後，kernel 持續重試多久才讓 I/O 失敗。這是 NVMe 版的 `no_path_retry`；kernel 自己的預設值 600 秒長到跟當機難以分辨 |
| `pflex-nvme-io-queues` | 1–128 | 否 | — | 每個控制器的 NVMe/TCP I/O 佇列數。不設定就交給 kernel 決定，通常是每個 CPU 一條 |
| `pflex-thick` | 布林 | 否 | `0` | 建立厚配置的 volume。預設為精簡配置，而精簡配置正是讓快照與複製足夠便宜的原因 |

### 這個系列的容量與名稱限制

PowerFlex 以 **8 GiB** 為配置單位，比這更小的請求會被進位到一個單位。Volume 與快照名稱上限為 **31 個字元** —— 比 PowerVault 還少一個 —— 因此 storage id 的可用長度是 **9 個字元**。

### 該選哪一條資料路徑

`dell-protocol nvme` 使用 kernel 內建的 NVMe/TCP initiator 連到儲存伺服器的 SDT 元件，主機端不需要安裝任何專有軟體。`dell-protocol sdc` 則使用 Dell 的 SDC kernel module，它必須與執行中的 kernel 相符；而 Proxmox VE 的 kernel 並不在 Dell 的支援矩陣上，因此一次 kernel 升級就可能讓某個節點失去儲存。詳見 [POWERFLEX_SDC_zh-TW.md](POWERFLEX_SDC_zh-TW.md)。

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

因此健康路徑使用較短的逾時，而且**只嘗試一次**。少了重試沒有任何損失：下一次輪詢本身就是重試。只有在儲存伺服器的管理網路確實很慢時才調高它，並且要預期整個輪詢週期會跟著變慢。

### `dell-activate-deadline`

每個 portal 各自有逾時限制，但整個迴圈沒有。一台公布八個 portal、其中三個可以建立 TCP 連線卻不再回應的儲存伺服器，可以讓 `activate_storage` 卡上好幾分鐘。

當預算用盡**且至少已有一條路徑可用**時，剩下的 portal 會延後到下一次啟用，並以警告列出是哪幾個。零路徑時絕不套用這個預算：一條路徑都沒有的情況下，儲存應該誠實地失敗，而不是回報成功。

### `dell-rescan-interval`

`activate_storage` 每次輪詢都會執行。若無條件重新掃描 SAN，等於每台節點每分鐘要做六次全主機的 `multipathd reconfigure` 與 `udevadm trigger`，而那段時間往往正好有 VM 啟動或備份在嘗試探索裝置，device-mapper 會一直處於變動狀態。

只要本節點登入了新的 portal，仍然會**立即**重新掃描，所以新對應的 volume 不會被延遲。這個間隔只用來限制「為了其他管道對應進來的 volume」而做的週期性保險掃描。

## Host 模式

`per-node`（預設）為每個 PVE 節點註冊一個 host 物件，名稱為 `pve-{cluster}-{node}`。每個 volume 都會對應到所有節點，讓線上遷移不必先重新對應，儲存伺服器也能回報各節點的連線狀態。

`shared` 則為整個叢集註冊一個 host group。儲存伺服器上的物件較少，但儲存伺服器就無法分辨某條路徑屬於哪一台節點。

## 驗證設定

```bash
pvesm status                     # 容量與是否為 active
pvesm list ps1                   # PVE 認得的 volume
journalctl -t pvestatd | grep dellpowerstore    # 外掛輸出的訊息
```

## 儲存伺服器上原本就有的 host 物件

在這個外掛跑起來之前，儲存伺服器上通常每個節點都已經有一個 host 物件 —— 由當初做 fabric
分區的人建立 —— 以它自己的命名，持有該節點的 WWPN 或 IQN。而一個 initiator 只能屬於
一個 host 物件，所以外掛沒辦法在旁邊再建一個自己的。

它也不需要。在 PowerStore 上，當外掛使用的名稱（`pve-<叢集>-<節點>`）底下沒有 host
時，它會去找一個**已經持有本節點 initiator** 的 host，改用那一個，並把名稱記在本機，
之後每一次對應都指向同一個物件。不改名、不刪除、也不搬動任何 initiator。

它只會採用 initiator 是**本節點的子集**的 host。若那個 host 同時持有別人的埠，那就是
共用或外部的物件，對應到它的磁碟區會被其他東西看見 —— 外掛會拒絕，並指出是哪一個埠讓
它拒絕的。本節點的埠散在兩個 host 物件上也一樣拒絕：一個節點就是一個 host 物件。

有一件連帶的事值得知道。磁碟區要預先對應到其他節點的 host，是以 `pve-<叢集>-` 前置
字串搜尋的，所以某個節點若採用了不同名稱的 host，就不會被別處預先對應。它會在自己啟用
儲存時完成對應 —— 而那正是遷移完成前會發生的事，所以不會出問題，只是時間點稍晚一點。
