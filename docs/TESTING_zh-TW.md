# 測試與實機驗證狀態

English: [TESTING.md](TESTING.md)

## 實機驗證狀態

**本專案的任何部分都尚未在實體 PowerStore 上執行過。**

以下項目在實機執行、並把結果連同當時的 PowerStore OS 版本記錄到本文件之前，一律為 `NOT VERIFIED ON HARDWARE`。

| 項目 | 位置 | 狀態 |
|---|---|---|
| REST 端點路徑 | `PowerStore/API.pm` | NOT VERIFIED ON HARDWARE |
| 回應欄位名稱（`size`、`wwn`、`logical_used`、`protection_data`） | `PowerStore/API.pm` | NOT VERIFIED ON HARDWARE |
| 過濾語法（`eq.`、`ilike.`、`cs.{...}`、`->>`） | `PowerStore/API.pm` | NOT VERIFIED ON HARDWARE |
| 認證流程（`login_session`、`DELL-EMC-TOKEN`） | `PowerStore/API.pm` | NOT VERIFIED ON HARDWARE |
| 容量來源（`space_metrics_by_cluster`） | `PowerStore/API.pm` | NOT VERIFIED ON HARDWARE |
| multipath 比對用的 SCSI vendor／product 字串 | `DellPowerStorePlugin.pm` | NOT VERIFIED ON HARDWARE |
| WWN 轉 multipath WWID | `PowerStore/API.pm` | NOT VERIFIED ON HARDWARE |
| Volume 名稱長度與字元限制 | `PowerStore/Naming.pm` | NOT VERIFIED ON HARDWARE |
| LUN ID 配發行為 | `PowerStore/API.pm` | NOT VERIFIED ON HARDWARE |
| multipath device 參數 | `DellPowerStorePlugin.pm` | NOT VERIFIED ON HARDWARE |
| Fibre Channel 資料路徑 | 全部 | NOT VERIFIED ON HARDWARE |
| 還原之後，比還原點更新的快照會怎麼樣 | `DellPowerStorePlugin.pm`、`DellPowerVaultPlugin.pm`、`DellPowerFlexPlugin.pm` | NOT VERIFIED ON HARDWARE |
| host 物件中 WWPN 的寫法（純十六進位或冒號分隔） | `DellPowerStorePlugin.pm`、`DellPowerVaultPlugin.pm` | NOT VERIFIED ON HARDWARE |
| 用來辨識連結複製來源的欄位（`protection_data.source_id`、`ancestorVolumeId`） | `DellPowerStorePlugin.pm`、`DellPowerFlexPlugin.pm` | NOT VERIFIED ON HARDWARE |
| NVMe-TCP | — | 不在 1.0 範圍 |

### 該去哪裡確認

陣列本身就會提供自己的 API 參考。PowerStore 是 `https://<mgmt-ip>/swaggerui` 的 Swagger UI，本外掛用到的每一個路徑都列在那裡，而且會直接產生對應的 `curl` 指令；請在信任任何端點之前先逐一比對。Dell 已公開的文件中，對於有文件的物件型別顯示的是相同的形狀 —— `POST /volume_group/{id}/clone`、`POST /file_system/{id}/snapshot` —— 與這裡使用的 `/volume/{id}/clone`、`/volume/{id}/snapshot` 一致，但「與同類物件的寫法一致」並不等於已驗證。

PowerVault 的參考則是 ME4／ME5 Series CLI Reference Guide，而且可以先透過 SSH 逐條試跑指令，再交給外掛以 HTTPS 送出。

### 最該優先驗證的四項

只要把本外掛指向任何一台陣列，請先做這四件事。每一項都很便宜，而每一項一旦錯了都是無聲的失敗。

```bash
# 1. 端點與欄位名稱：陣列自己就有文件
#    https://<mgmt-ip>/swaggerui

# 2. SCSI vendor 與 product 字串，它們決定外掛「會去碰哪些裝置」
sg_inq /dev/sdX | head -5
multipathd show config | grep -A3 -i dell

# 3. WWN 轉 WWID。陣列回報的是 naa.68ccf098...，兩者必須對得起來。
/lib/udev/scsi_id -g -u /dev/sdX

# 4. LUN ID 長期下來是否維持在低位
#    PowerStore Manager > Compute > Host Information > <host> > Mapped Volumes
```

## PowerVault ME（dellpowervault）

ME4 與 ME5 系列不是 REST 物件模型，而是把 CLI 透過 HTTPS 開放出來。以下依「資料來源」分成兩類，因為這個區分決定了出問題時該先查哪裡。

### 來自 Dell 官方文件

開發過程中實際讀取自《Dell PowerVault ME5 Series Storage System CLI Reference Guide》。仍未經實機驗證，但不是憑空推測：

| 項目 | 出處 |
|---|---|
| `GET /api/login/<sha256("user_password")>`，小寫十六進位 | Using a script to access the CLI |
| 另一種方式是 `GET /api/login` 搭配 HTTP Basic；SHA-256 不適用於 LDAP 帳號 | 同上 |
| 標頭 `sessionKey` 與 `dataType: json` | 同上 |
| session 閒置 30 分鐘逾時 | 同上 |
| 指令 URL 形式 `https://<ip>/api/<verb>/<object>/<args>` | 同上 |
| 回應帶有 `status` 陣列，含 `response-type`、`response`、`return-code` | Using JSON API output |
| `create volume [pool] [volume-group] size <n>[B\|GiB\|…] <name>` | create volume |
| Volume 名稱上限 32 bytes，不可含 `" , . < \` | create volume |
| 容量對齊 4 MiB，且由陣列**向下**取整 | create volume、expand volume |
| `expand volume size <amount> <volume>` —— 這個數值是**增量** | expand volume |
| 不支援縮小 | expand volume |
| `map volume [access rw] initiator <hosts> [lun <n>] <volumes>`；指定 initiator 時必須給 LUN | map volume |
| `show volumes [details] [pattern <string>] [pool <pool>] [type …]` | show volumes |
| `create snapshots volumes <volumes> <snap-names>`；快照名稱上限 32 bytes 且全系統唯一 | create snapshots |

### 尚未查證 —— 請優先確認這些

開發期間 Dell 文件網站多次拒絕存取，因此以下項目雖然遵循同一套 CLI 語法，但並非直接讀自官方指南。它們在 `PowerVault/API.pm` 中都標記為 `NOT VERIFIED`：

| 項目 | 位置 |
|---|---|
| `delete volumes <name>` | `volume_delete` |
| `delete snapshot <name>` | `snapshot_delete` |
| `set volume name <new> <volume>` | `volume_rename` |
| `rollback volume <volume> snapshot <snapshot>` | `snapshot_rollback` |
| `unmap volume initiator <host> <volume>` | `volume_unmap` |
| `create host id <ids> <name>` 與 `set initiator host <name> <id>` | `host_create`、`host_add_initiators` |
| `show pools`、`show maps`、`show ports`、`show snapshots` 的欄位名稱 | 容量、對應關係、portal |
| SCSI vendor 與 product 字串（`DellEMC` / `ME[45]…`） | `DellPowerVaultPlugin` |
| WWN 轉 WWID | `wwn_to_wwid` |

在陣列上用一個指令就能確認語法：

```bash
# 透過 SSH 連到陣列自己的 CLI
help delete volumes
help unmap volume
help create host
```


## 自動化檢查

```bash
make syntax                  # 對每個模組與腳本執行 perl -c
make unit                    # t/*.t
make check-multipath-flush   # 出現全系統 multipath flush 即失敗
make test                    # 以上全部
```

目前有 867 個單元測試，不需要陣列或實體裝置即可執行，涵蓋命名與歸屬檢查、REST 重試策略、orphan 清理防護、對照 fixture 的請求格式，以及外掛的 PVE schema。需要 `PVE::Storage::Plugin` 的測試在沒有 Proxmox VE 的機器上會自行跳過。

單元測試無法告訴你的是：端點是否存在、欄位名稱是否正確、裝置到底會不會出現。那是下面這份矩陣的工作。

## 人工測試矩陣

請在至少三台節點的叢集搭配實體陣列上執行，並把結果與 PowerStore OS 版本填入結果欄。

| # | 測試項 | 前置條件 | 通過標準 | 結果 |
|---|---|---|---|---|
| 1 | 套件安裝 | 乾淨節點 | `apt install ./deb` 能解相依，postinst 無錯誤 | — |
| 2 | 叢集全節點安裝 | 3 節點 | 每台節點的 `pvesm status` 結果一致 | — |
| 3 | `pvesm add` 參數驗證 | — | 缺少必填選項會被擋下 | — |
| 4 | 容量回報 | — | 與 PowerStore Manager 誤差在 1% 以內 | — |
| 5 | 陣列離線 | 拔掉管理網路 | 儲存在約 5 秒內轉為 `inactive`，其他儲存不受影響 | — |
| 6 | 建立 VM 磁碟 | — | 陣列上出現 volume，節點上出現 multipath 裝置 | — |
| 7 | 線上擴充 | VM 執行中 | 重新掃描後客體看得到新容量 | — |
| 8 | 縮小 | — | 被擋下，並同時列出兩個容量 | — |
| 9 | 刪除磁碟 | VM 已停止 | volume 消失，且沒有殘留裝置或 map | — |
| 10 | 刪除使用中的磁碟 | VM 執行中 | 被擋下並說明原因 | — |
| 11 | 快照建立／列出／刪除 | — | 與陣列上的快照一致 | — |
| 12 | 快照還原 | VM 已停止 | 資料正確還原，無殘留快取 | — |
| 13 | 含記憶體的快照（vmstate） | VM 執行中 | state 卷建立成功，VM 能正確恢復 | — |
| 14 | 設定備份與 `pve-dell-config-get` | PowerStore | 設定可以讀回來；在 PowerVault ME 上不會產生設定卷 | — |
| 15 | 範本與連結複製 | — | 複製瞬間完成 | — |
| 16 | 刪除有複製的範本 | — | 被擋下並列出相依物件 | — |
| 17 | 完整複製 | — | 可透過 qemu-img 完成 | — |
| 18 | LXC 容器 rootfs | — | 能建立並啟動 | — |
| 19 | EFI disk、TPM state、cloud-init | — | 各自都能建立 | — |
| 20 | 線上遷移 | 2 節點 | 完成且 I/O 無中斷 | — |
| 21 | 單一路徑故障 | 拔掉一條 iSCSI 線 | I/O 持續，multipath 顯示失效路徑 | — |
| 22 | 節點重開機 | — | 自動登入且裝置自動出現 | — |
| 23 | Orphan 清理 | 從其他節點刪除一個 volume | 寬限期過後殘留裝置被清除，其他裝置不受影響 | — |
| 24 | LUN ID 攀升 | 反覆掛載卸載 300 次 | ID 維持在低位且密集 | — |
| 25 | Fibre Channel | FC fabric | 重跑第 1〜24 項 | — |
| 26 | PVE 9.1 升級到 9.2 | — | 外掛仍正常，`get_identity` 正常回傳 | — |

## 1.0.0 的長時間測試門檻

除了上述矩陣之外：

- 連續 72 小時的 pvestatd 輪詢，沒有誤報 `inactive`，journal 也沒有錯誤累積
- 管理網路中斷 10 分鐘後恢復：儲存自行回到 `active`，執行中的 VM 全程沒有 I/O 中斷
- 完成第 24 項之後，LUN ID 仍維持在低位
