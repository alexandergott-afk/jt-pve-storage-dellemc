# 架構說明

> **狀態：大綱（Phase 0）。** 待 Phase 2 補上 `BlockBase` 的完整契約。English: [ARCHITECTURE.md](ARCHITECTURE.md)

## 一個 repo，多個 storage type

Dell EMC 各產品系列的差異太大，無法共用單一 PVE storage type。每個系列各自註冊一個 type，並共用主機端底層：

| 系列 | PVE type | 資料路徑 | 基底類別 |
|---|---|---|---|
| PowerStore | `dellpowerstore` | iSCSI／FC，dm-multipath | `Common::BlockBase` |
| PowerMax | `dellpowermax` | FC／iSCSI，dm-multipath | `Common::BlockBase` |
| PowerFlex | `dellpowerflex` | SDC kernel module、`/dev/scini*` | 自有基底 |
| PowerScale | `dellpowerscale` | NFS，目錄語意 | 自有基底 |

為什麼不做成單一 plugin 加 `--dell-type` 參數：

- `plugindata()` 是 class method。PVE 會在解析任何 `storage.cfg` 參數**之前**呼叫它，用來取得支援的 content type 與磁碟格式，因此 block 系列與 NAS 系列無法共用同一個回傳值。
- PVE 的 JSON schema 無法表達「當系列為 X 時此參數才必填」。單一 type 會被迫宣告所有系列參數的聯集，錯誤組合要到執行期才會爆出來。
- type 字串是永久契約，日後修改會讓既有的 `storage.cfg` 失效。

plugin type 一律由管理者在 `pvesm add` 時明確指定，絕不向陣列探測。`storage.cfg` 會被 `pvestatd`、`pvedaemon`、`pveproxy`、`qm`、`pct` 反覆解析，而且經常在陣列不可達時解析；若解析結果取決於一次 REST 呼叫，整台節點的儲存清單都會跟著失效。

## 分層

```
DellPowerStorePlugin.pm            系列專屬：type、plugindata、options
        |                          陣列操作以抽象方法表達
        v
DellEMC::Common::BlockBase         所有與陣列無關的邏輯：
                                   activate／deactivate、status、alloc／free、
                                   快照、等待裝置、orphan 清理
        |
        +-- Common::REST           HTTP 客戶端：重試、逾時、session
        +-- Common::ISCSI          initiator 與 portal 登入
        +-- Common::FC             HBA 與 WWPN 探索
        +-- Common::Multipath      SCSI 裝置生命週期、dm-multipath map
        +-- Common::Naming         PVE 物件名稱與陣列物件名稱的對應
        +-- Common::WwidState      WWID 追蹤、orphan 寬限期
        +-- Common::Health         status 失敗計數、容量告警
```

`PowerStore::API` 繼承 `Common::REST`，補上 PowerStore 的認證方式與端點；`PowerStore::Naming` 則在 `Common::Naming` 之上收斂 PowerStore 的名稱長度與字元限制。

## 新增一個系列

1. 新增 `lib/PVE/Storage/Custom/DellEMC/<Family>/API.pm`，繼承 `Common::REST`。
2. 新增 `lib/PVE/Storage/Custom/Dell<Family>Plugin.pm`；block 系列繼承 `Common::BlockBase`，資料路徑不是 dm-multipath 的系列則直接繼承 `PVE::Storage::Plugin`。
3. 實作全部抽象 `_array_*` 方法；系列專屬參數使用專屬前綴，避免與其他外掛的 schema 衝突。
4. 打包不需修改，Makefile 會自動探索新模組。
