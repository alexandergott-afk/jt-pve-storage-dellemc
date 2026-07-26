# 架構說明

English: [ARCHITECTURE.md](ARCHITECTURE.md)

## 一個 repo，每個系列各自一個 storage type

Dell EMC 各產品線的差異太大，無法共用同一個 PVE storage type，因此每個系列各自對應一個，並共用主機端底層。

| 順序 | 系列 | PVE type | 資料路徑 | 基底類別 |
|---|---|---|---|---|
| 1 | PowerStore | `dellpowerstore` | iSCSI／FC、dm-multipath | `Common::BlockBase` |
| 2 | PowerVault ME5 | `dellpowervault` | iSCSI／FC／SAS、dm-multipath | `Common::BlockBase` |
| 3 | PowerFlex | `dellpowerflex` | SDC kernel module、`/dev/scini*` | 自有 |
| 4 | PowerMax | `dellpowermax` | FC／iSCSI（dm-multipath）、NVMe/FC 與 NVMe/TCP | `Common::BlockBase` 加上 NVMe 路徑 |

PowerScale 與 Unity XT 未排入。PowerScale 是 NAS，而 Proxmox VE 內建的 NFS 儲存已經涵蓋專用外掛能提供的大部分功能。

為什麼不做成單一 plugin 加 `--dell-type` 參數：

- **`plugindata()` 是 class method。** PVE 會在解析任何 `storage.cfg` 參數**之前**呼叫它，取得支援的 content type 與磁碟格式。PowerStore 是 block 儲存、只能放 `raw`；像 PowerScale 這類 NAS 則可以放 `qcow2`、`subvol`、ISO 與備份。沒有任何一組回傳值能同時描述兩者；PowerFlex 也一樣，它的 volume 是透過 kernel module 呈現，而不是經由 SAN 登入。
- **schema 無法表達「在某條件下才必填」。** PVE 的 JSON schema 只有 `optional`，沒有別的。單一 type 會被迫宣告所有系列參數的聯集，錯誤的組合只會在執行期、在陣列上、在操作進行到一半時才失敗。
- **type 字串是永久契約。** 日後修改會讓所有既有的 `storage.cfg` 失效。

type 一律在 `pvesm add` 時明確指定，絕不向陣列探測。`storage.cfg` 會被 pvestatd、pvedaemon、pveproxy、`qm`、`pct` 反覆解析，其中也包含陣列不可達的時候；一旦解析結果取決於一次 REST 呼叫，整台節點的儲存清單都會跟著失效。

在 `activate_storage` **之後**做探測則沒有問題，因為那裡的失敗可以優雅降級：韌體版本、是否支援 NVMe-TCP、授權功能、appliance 型號。

## 分層

```
DellPowerStorePlugin.pm          系列專屬：type、schema，以及以 REST 呼叫
        |                        實作的 _array_* 方法
        v
DellEMC::Common::BlockBase       所有與陣列無關的邏輯：
                                 啟用、配置、裝置探索與拆除、快照、範本、
                                 複製、multipath drop-in、orphan 清理
        |
        +-- Common::REST         HTTP 傳輸層：重試、逾時、session
        +-- Common::ISCSI        initiator、portal 預檢、session rescan
        +-- Common::FC           HBA 探索、WWN 正規化
        +-- Common::Multipath    SCSI 裝置生命週期、dm-multipath map
        +-- Common::Naming       PVE 名稱與陣列物件名稱的對應
        +-- Common::WwidState    WWID 追蹤、orphan 寬限期
        +-- Common::Health       status 失敗計數、容量告警
```

`PowerStore::API` 繼承 `Common::REST`，補上 PowerStore 的認證方式與端點；`PowerStore::Naming` 繼承 `Common::Naming`，補上 PowerStore 的名稱限制。

## BlockBase 的契約

block 系列只需要實作以下方法，其餘全部繼承。每個未實作的方法都會以「哪個類別沒有實作它」的訊息中止，`t/08` 也會檢查沒有任何一個仍停留在抽象狀態。

```
type                    PVE storage type 字串
multipath_vendor        SCSI vendor 字串，決定外掛「會去碰哪些裝置」
multipath_product
multipath_defaults      該系列的 multipath device 參數

_array_ping             健康路徑用的輕量連通性檢查
_array_get_capacity     回傳位元組的 ($total, $used, $avail)

_array_get_volume       _array_list_volumes    _array_create_volume
_array_delete_volume    _array_resize_volume   _array_rename_volume
_array_get_wwid

_array_snapshot_create  _array_snapshot_get    _array_snapshot_delete
_array_snapshot_list    _array_snapshot_rollback
_array_clone

_array_ensure_host      _array_list_hosts
_array_map_to_host      _array_unmap_from_host
_array_is_mapped        _array_mapped_hosts

_array_get_portals      iSCSI portal，格式為 [{ portal, iqn }]
```

可選擇覆寫：`naming`、`family_properties`、`family_options`、`identity_suffix`、`capacity_scope`、`multipath_config_version`、`_array_list_base_snapshots`。

## Property 宣告

PVE 會把所有已註冊外掛的 `properties()` 合併成同一份 schema，若兩個外掛宣告了相同名稱就會以 `duplicate property` **中止** —— 見 `PVE::SectionConfig::init`。這個失敗的影響範圍不限於出問題的外掛：它發生在 PVE 建立 storage schema 的過程中，因此該節點上的每一個儲存都會停止運作。

因此共用的 `dell-*` 選項由「PVE 最先詢問到的那個系列類別」宣告，其他系列只宣告自己的。新增系列不需要更動這個機制，`t/06` 也涵蓋了它。

### 關於 PowerMax，在動工之前先記下

PowerMaxOS 10 的 PowerMax 2500／8500 支援的主機協定是**四種**而非兩種：SCSI 上的 FC 與 iSCSI，加上 NVMe/FC 與 NVMe/TCP。SCSI 那一對可以像 PowerStore 與 PowerVault 一樣套用 `BlockBase` 與 dm-multipath；NVMe 那一對不行 —— 那些路徑是 NVMe namespace，走 ANA 多路徑，也就是 `PowerFlex::Host` 已經實作的東西。

因此在動工 PowerMax 時，NVMe 的基礎功能（連線、host NQN、路徑列舉、ctrl-loss-tmo 策略）應該從 `PowerFlex::Host` 移到共用模組，而 `BlockBase` 的裝置層應該可以由參數指定，而不是預設 dm-multipath。這個重構刻意先不做：目前 NVMe 只有 PowerFlex 一個使用者，第二個使用者才會顯示出接縫真正該切在哪裡。


## 新增一個系列

1. `lib/PVE/Storage/Custom/DellEMC/<Family>/API.pm`，繼承 `Common::REST`。
2. `lib/PVE/Storage/Custom/Dell<Family>Plugin.pm`；block 系列繼承 `Common::BlockBase`，資料路徑不是 dm-multipath 的系列則直接繼承 `PVE::Storage::Plugin`。
3. 實作上述抽象方法，並以專屬前綴宣告系列選項。
4. 沒有其他事情要做。Makefile 會自動探索新模組，打包也會跟著涵蓋。

ME5 與 PowerMax 會繼承 `BlockBase` —— 它們正是這個基底當初設想的對象。PowerFlex 不會：它的資料路徑是 kernel module 呈現的 `/dev/scini*`，沒有 SAN 登入也不走 dm-multipath，只有 REST 傳輸層可以重用。

## 為什麼外掛在主機端如此謹慎

以下三種故障模式決定了大部分的設計，而且三者都是從 Pure Storage 與 NetApp 外掛承接下來的實戰教訓，不是理論：

1. **不可中斷睡眠。** 讀取沒有回應的裝置會讓行程進入 D state，任何訊號都無法清除。本專案的每一次 sysfs 存取都在有逾時限制的子行程中進行，每一個外部指令都有 alarm 保護。
2. **影響範圍。** 全系統的 `multipath -F` 絕不使用 —— 它會清掉節點上所有未使用的 map；LIP 也不使用，它會干擾某個 HBA port 後面的所有 LUN。具破壞性的操作都有 vendor 過濾，而且一次只處理一個物件。
3. **依序輪詢。** PVE 是一個接一個輪詢儲存的，因此一台慢的陣列會餓死它的鄰居。健康路徑採用短逾時且只嘗試一次，昂貴的週期性工作則加上頻率限制並丟到獨立的背景流程執行。
