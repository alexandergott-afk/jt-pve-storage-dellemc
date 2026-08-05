# 測試與實機驗證狀態

English: [TESTING.md](TESTING.md)

## 已經在實機上觀察到的部分

已經有一台陣列跑過這個外掛：**PowerVault ME4024，系統名稱 MIL-ME4024，韌體
`GT280R011-01`，走 Fibre Channel**。本節所有內容都是從那台陣列上讀出來的，而
不是從文件推出來的；原始回應逐字保留在 `t/fixtures/powervault/`，讓測試套件
是拿真實陣列送出的東西在驗。

| 觀察到的事實 | 造成的結果 | 修正版本 |
|---|---|---|
| `GET /show/system` 回的是 `text/*`，且內含非 ASCII 位元組 | `pvesm add` 直接失敗，訊息是 `Wide character in subroutine entry`。`decoded_content` 回傳的是字元，而 `decode_json` 要的是位元組 | 0.7.62 |
| `GET /show/host-groups` 最上層只有 `host-group`；host 巢狀在 `host`（單數）底下，initiator 再巢狀在 `initiator` 底下 | host 查詢完全落空，外掛每次輪詢都重建 host，陣列以 `-10389` 拒絕，儲存一直停在 inactive | 0.7.63 |
| `GET /show/pools` 的可用空間欄位是 `total-avail` / `total-avail-numeric`，沒有 `avail` | 每個儲存池都讀成 100% 已用，而 PVE 不會配置到已滿的儲存池裡。儲存池 B 實測 98.56% 已用，那是真實數字 | 0.7.63 |
| `-10389` 是「The specified host name is already in use」的回傳碼 | 現在把它當成「host 確實存在」的證據，只讀代碼、絕不讀訊息文字 | 0.7.63 |
| `map`／`unmap` 收的是識別碼而不是名稱：`<名稱>` 是 **initiator**、`<名稱>.*` 是 host、`<名稱>.*.*` 是 host group | 送出的是裸的 host 名稱，被當成 initiator 去查，以 `-10386` 拒絕。任何磁碟區都無法對應 | 0.7.65 |
| `show maps` 是巢狀的：最上層是 `volume-view`，每顆磁碟區一筆，各自把資料列放在底下的 `volume-view-mappings` | 對應清單讀回來是空的，每個 LUN 都看起來沒人用，第二顆對應到同一 host 的磁碟區以 `-3177` 被拒 | 0.7.65 |
| 每顆磁碟區都帶一列描述 default mapping 的佔位列 —— `lun ""`、`access "not-mapped"`、`access-numeric 0`、`identifier "all other initiators"`、`nickname ""` —— 只在 JSON 看得到 | 它被讀成一個 host，每次刪除都去解除對應，以 `-10007` 失敗 | 0.7.65 |
| 即使 `map` 指定的是 host，只要該 host 是某個群組的唯一成員，對應仍可能被記錄在**群組層級** | 群組層級的資料列會替群組內每一個 host 佔住那個 LUN | 0.7.65 |
| WWID 換算規則：`3` + `6`(NAA) + OUI `00c0ff` + `000` + 磁碟區序號第 7–12 碼 + 序號後 16 碼。序號中的 `0000` 是右補零，WWID 對應位置卻是左補零，方向相反 | 外掛算出的 WWID 與 `multipath -ll`、`/dev/mapper` 在四顆磁碟區上完全吻合 | 原本就正確 |
| `unmap volume initiator <host>.* <volume>` | 原始碼中標註為 NOT VERIFIED | 已驗證 |
| host 物件要的 WWPN 寫法：純十六進位、以逗號分隔（`100000109b643bca,100000109b643c04`） | 陣列接受 | 已驗證 |
| 路徑中經過百分號編碼的 `*`，在 CLI 看到之前就會被解碼 | 這就是 URL 跳脫不需要為 `.*` 後綴開例外的原因 | 已驗證 |

### 在該陣列上跑過的煙霧測試

上述三個缺陷修好之後，`docs/FIRST_RUN` 的每一項都在那台陣列上通過：`pvesm
status`（3.2 秒，容量與 GUI 一致）、連續數顆 `pvesm alloc`（LUN 4／5／6 依序
遞增）、對應與 dm-multipath（兩條路徑，prio 50／10）、透過 `/dev/mapper` 的
`dd` 讀寫（寫 175 MB/s、讀 344 MB/s，並以雜湊驗證）、`qm snapshot`、
`qm rollback`、`qm delsnapshot`、`qm template`、秒級完成的連結複製、陣列正確
拒絕刪除仍有存活複製的範本（`-3442`），以及解除對應、刪除與本機裝置清理。

**這是本專案史上第一次端到端完整執行。** 它不代表另外兩個系列已經驗證，也不
代表 iSCSI 或 SAS 已經驗證 —— 那台陣列走的是 Fibre Channel。

以下仍未從該陣列上抓到，因此仍屬推測：

| 未解的問題 | 為什麼重要 | 目前如何因應 |
|---|---|---|
| **不屬於任何 host group** 的 host 在 JSON 中長什麼樣。CLI 會把 ungrouped host 印在另一個區塊，但對應的鍵名不明 | 單節點安裝時，host 不在任何 group 裡才是常態 | 鍵名清單已經不是決定因素。ME 回應裡的每個物件都會在 `object-name` 說出自己的型別，只要那一列寫著 `"object-name": "host"`，不論它掛在哪個鍵底下都會被收進來 |
| 位於 host group **內**的 host，究竟能不能被單獨對應。在該陣列上，一個身為群組唯一成員的 host，其對應一律被記錄在群組層級 | 若部署方式是把 host 放進群組，可能需要「群組層級」的比對，而不只是 host 層級 | 群組層級的資料列會被計為佔用該 LUN，因此不會有同一個號碼被發兩次。這種部署其餘部分是否可用，尚未測試 |
| `qm destroy` 中途失敗時應該怎麼處理 —— 陣列正確拒絕刪除仍有存活複製的範本，但 PVE 此時已經移除虛擬機設定檔，於是磁碟區失去了所有指向它的參照 | 會留下需要手動 `pvesm free` 的孤兒 | 孤兒回收機制會回報它；不會在無人看管的情況下刪除 |

## 實機驗證狀態

**本專案的任何部分都尚未在實體 PowerStore 上執行過。**

以下項目在實機執行、並把結果連同當時的 PowerStore OS 版本記錄到本文件之前，一律為 `NOT VERIFIED ON HARDWARE`。

| 項目 | 位置 | 狀態 |
|---|---|---|
| REST 端點路徑 | `PowerStore/API.pm` | NOT VERIFIED ON HARDWARE —— 但本外掛用到的每一個路徑，都能在 Dell 自己的 `python-powerstore` SDK（`PyPowerStore/utils/constants.py`）裡逐字找到；詳見下方 |
| 回應欄位名稱（`size`、`wwn`、`logical_used`、`protection_data`） | `PowerStore/API.pm` | NOT VERIFIED ON HARDWARE |
| 過濾語法（`eq.`、`ilike.`、`cs.{...}`、`->>`） | `PowerStore/API.pm` | NOT VERIFIED ON HARDWARE —— 比較運算子前置字串與 `*` 萬用字元是從開發者指南讀來的 |
| 認證流程（`login_session`、`DELL-EMC-TOKEN`、`auth_cookie`） | `PowerStore/API.pm` | NOT VERIFIED ON HARDWARE —— 標頭、cookie 與「非 GET 一律需要 token」是從開發者指南讀來的 |
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
| `pattern` 接受 shell 風格的萬用字元 —— `*`、`?`、`[]` —— 比對的是名稱中**是否含有**該字串 | show volumes |
| `show volumes` 印出的欄位為 Name、Total Size、Alloc Size、Serial Number、WWN、Pool、Class、Type、Role、Health | show volumes |
| **volumes basetype**（JSON 實際帶的屬性名稱）記載了 `volume-name`、`durable-id`、`serial-number`、`wwn`、`size`、`total-size`、`allocated-size`（各自都有以區塊計的 `-numeric` 版本）、`health`、`creation-date-time` 與 `creation-date-time-numeric`。**列印出來的欄位標題不等於屬性名稱** | volumes basetype |
| `show maps` 的每一列帶有 `nickname`（host 或 host group 名稱，未設定時為空白）、`identifier`（initiator 的 WWPN 或 IQN）、`lun`、`access`、`ports`、`parent-id` | volume-view-mappings basetype |
| initiator 的資料列帶有 `id`（WWPN 或 IQN）與 `hba-nickname` | initiator-view basetype |

### 之後已對照 Dell CLI Reference 查證

以下這些原本是推測的，現在已從 ME4／ME5 CLI Guide 讀出來。其中兩個推測是錯的，而且都落在「儲存第一次啟用」的路徑上：

| 指令 | 文件記載 | 原本寫的 |
|---|---|---|
| 建立 host | `create host initiators <清單> <名稱>` | `create host id <清單> <名稱>` |
| 把 initiator 加入既有 host | `add host-members initiators <清單> <host>` | `set initiator host <host> <initiator>` —— 那是另一個指令，只是為 initiator 命名，不會把它掛到任何 host 上 |
| 刪除 volume | `delete volumes <清單>` | 不變；已確認只有在互動式主控台模式才會出現確認提示 |
| 重新命名 volume | `set volume name <新名稱> <volume>` | 不變 |
| 解除對應 | `unmap volume initiator <hosts> <volumes>` | 不變；若省略 initiator，刪掉的會是**預設對應** |
| 還原 | `rollback volume [prompt yes\|no] snapshot <快照> <volume>` | 現在會回答那個確認提示 |
| 列出 volume | `show volumes [details] [pattern <s>] [pool <p>] [type ...]` | 參數順序已與指南一致 |
| 對應 | 見下方 —— ME4 與 ME5 記載的順序**不同** | 先送 ME5 形式，並保留退回機制 |

`map volume` 是唯一一個「兩個系列記載的參數順序不同」的指令：

```
ME5：map volume [access ...] initiator <initiators> [lun <LUN>] <volumes>
ME4：map volume <volumes> [access ...] initiator <initiators> [lun <LUN>]
```

外掛會先送 ME5 的形式，若陣列拒絕就退回 ME4 的形式，因此兩者都能運作；在
ME4 上，journal 會記錄它最後採用了哪一種順序。**第一次上實機時請檢查那一
行** —— 那是確認對應路徑行為符合文件最省力的方式。

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


## 欄位名稱：哪些已經查證、哪些還沒

在第一次上實機之前找到的缺陷中，最嚴重的兩個都是「欄位名稱根本不存在」：PowerVault 的儲存池容量讀的是 `avail-size`，而 pools basetype 記載的是 `total-avail`，於是每個儲存池看起來都是滿的；而對應狀態的檢查，是拿 host 名稱去比對一份根本沒有 host 名稱欄位的清單。這兩者除了「行為說不通」之外都不會有任何徵兆。

因此以下列出 API 客戶端讀取的每一個欄位。第一次上機時，請拿它跟陣列實際回傳的內容比對 —— PowerStore 用 `https://<mgmt-ip>/swaggerui` 的 Swagger UI，PowerVault 用 SSH 直接下指令，PowerFlex 直接打 API。

### PowerVault ME（出自 ME4／ME5 CLI Reference）

| 欄位 | 用途 | 狀態 |
|---|---|---|
| `total-size-numeric` | 儲存池容量，單位為 512 位元組區塊 | 文件記載為 **Total Size** |
| `total-avail-numeric` | 儲存池可用空間 | pools basetype 記載的是 `total-avail`；**Avail** 是 `show pools` 印出來的欄位標題。已在 ME4024 上確認：該陣列沒有標題那個拼法的欄位，於是每個儲存池都讀成 100% 已用 |
| `avail-numeric`、`avail-size-numeric`、`available-size-numeric` | 在 `total-avail` 之後才嘗試 | 舊拼法，都不是文件記載的那一個 |
| `size-numeric`（volume） | volume 大小 | volumes basetype 記載 `size` 就是該 volume 的容量 |
| `allocated-size-numeric` | volume 已使用空間 | volumes basetype 記載為 `allocated-size` |
| `total-size-numeric`、`alloc-size-numeric` | 排在上面兩者之後；**Total Size** 與 **Alloc Size** 是列印出來的欄位標題，與屬性名稱並不是同一回事 | — |
| `wwn`、`volume-wwn`、`serial-number` | 主機將看到的 WWID | volumes basetype 記載 `wwn` 為該 volume 的 World Wide Name、`serial-number` 為序號；主機的 WWID 究竟由哪一個推導出來，仍**未驗證** |
| `volume-name`、`name` | 物件名稱 | 文件記載為 **Name** |
| `nickname` | 一列對應屬於哪個 host 或 host group | `volume-view-mappings` 記載為 host 或 host group 名稱，**未設定時為空白** 。已在 ME4024 上確認它會帶上識別碼語法的後綴：host 是 `pve-pve-host15.*`，host group 是 `pvegroup01.*.*`。比對時若不去掉後綴，永遠不會命中 |
| `identifier` | 一列對應屬於哪個 initiator（WWPN 或 IQN） | `volume-view-mappings`，已記載 |
| `lun`、`access`、`ports` | 對應的 LUN、存取模式與連接埠 | `volume-view-mappings`，已記載 |
| `access-numeric` | 用來分辨真實對應與 default mapping 的佔位列 | 已在 ME4024 上確認：`3` 為 read-write、`1` 為 read-only，**佔位列是 `0`**。即使沒有設定 default mapping，每顆磁碟區都會帶一列這種佔位列，其 `identifier` 是顯示字串 `all other initiators`、`nickname` 為空。CLI 的表格輸出不會顯示它，只有 JSON 有 |
| `volume-view`、`volume-group-view` | `show maps` 回應的最上層，每顆磁碟區一筆 | 已在 ME4024 上確認：對應資料列巢狀在其底下的 `volume-view-mappings`，最上層沒有任何對應陣列。巢狀列的 `object-name` 自稱 `host-view`，所以這份清單是依鍵名走訪，而不是依資料列自稱的型別 |
| `volume-name`、`volume-serial` | 巢狀的對應資料列屬於哪顆磁碟區 | 已在 ME4024 上確認。資料列本身只以 `durable-id` 指向父物件，因此identity 由外層的 view 帶下來 —— 並用來檢查 `show maps <volume>` 是否真的照要求過濾了 |
| `media` | `iSCSI`、`FC(P)`、`FC(L)`、`SAS` | 文件記載為 **Media** |
| `target-id` | iSCSI 連接埠的 IQN | 文件記載為 **Target ID** |
| `ip-address` | iSCSI portal 位址 | 已記載 |
| `status`、`health` | 連接埠是否可用 | 已記載 |
| `creation-date-time-numeric` | 快照時間 | volumes basetype 記載為未格式化的 epoch 時間 |
| `name-numeric`、`status-numeric` | 主要欄位不存在時嘗試的替代拼法 | — |
| `port-type`、`primary-ip-address` | Media 與 IP Address 的舊拼法 | — |
| `host-id`、`host`、`name` | 對應資料列可能用來表示「屬於誰」的其他拼法 | — |
| `host`（巢狀）、`hosts`、`host-view` | `show host-groups` 回應中放置 host 資料列的鍵 | 回應是一棵樹：host group 在最上層，host **巢狀**在其中，initiator 再巢狀一層。已在 ME4024 上確認：只讀最上層的 `hosts` 陣列會什麼都找不到，外掛因此看不見自己剛建立的 host |
| `name`、`host-name` | host 自己的名稱 | host basetype 記載為 `name`；`host-name` 是 host-view 的拼法 |
| `durable-id` | 在樹中重複走到同一列時用來辨識是同一個 host | 文件記載 |
| `return-code` | 指令是否被拒絕，以及原因 | 各指令頁面均有記載；`-10389` 是「host 名稱已被使用」。判斷只讀這個代碼，絕不讀訊息文字 |

`-numeric` 欄位以 512 位元組區塊計；不帶後綴的欄位是像 `1996.7GB` 這樣的格式化字串，只有在數值欄位不存在時才會被解析。

### Unity XT（出自 Dell 自己的 `gounity` 客戶端）

以下每一個 URI、請求內容與欄位名稱，都是從 `github.com/dell/gounity` 讀出來的
—— 那是 Dell 的 CSI driver 實際用來打 Unity 的客戶端 —— 而不是文件敘述。兩者
不一致時，以程式碼為準。**沒有任何一項在 Unity 陣列上執行過。**

| 欄位 | 讀來做什麼 | 狀態 |
|---|---|---|
| `id` | 每個物件的識別碼；LUN 與它的 `storageResource` 共用同一個 | 文件記載 |
| `name` | 物件名稱，也是 `name:` 查詢的鍵 | 文件記載 |
| `wwn` | 主機會看到的 WWID，`'3'` + 純十六進位 | 換算本身**未驗證**；第一次上機時請與 `multipath -ll` 對照 |
| `sizeTotal`、`sizeUsed`、`sizeAllocated` | 磁碟區大小與已用空間，單位是**位元組** —— 不是 PowerVault 的 512 位元組區塊 | Dell 自己的 `LunDisplayFields` |
| `hostAccess` | 哪些主機可以看到這顆 LUN。是一組 `{host: {id}, accessMask}`，而且寫入時是**取代**整份清單 | Dell 自己的欄位清單；Dell 客戶端同時有 `ExportVolume` 與 `ModifyVolumeExport`，正是取代語意的證據 |
| `accessMask` | `'1'` production、`'2'` snapshot、`'3'` 兩者 —— 是**字串**不是數字 | Dell 客戶端寫死 `'1'` |
| `pool`、`storagePool` | **不可互換**：建立時的鍵是 `storagePool`，`pool` 是 LUN 回報時用的 | Dell 自己的 `CreateLun` 內容 |
| `sizeFree`、`sizeTotal`、`sizeUsed`、`sizeSubscribed`（儲存池） | 儲存池容量，單位位元組 | Dell 自己的 `StoragePoolFields` |
| `isThinEnabled` | 精簡佈建，送出時是**字串** `'true'` | Dell 客戶端使用 `strconv.FormatBool` |
| `creationTime` | 快照時間，ISO 8601 且帶時區位移 | 文件記載；位移會被讀取並套用 —— 忽略它曾讓另一個系列付出一個版本 |
| `storageResource`（快照上） | 快照屬於哪一顆 LUN | Dell 自己的 `SnapshotDisplayFields` |
| `fcHostInitiators`、`iscsiHostInitiators` | 已註冊到某個 host 的 initiator | Dell 自己的 `HostDisplayFields` |
| `initiatorId`、`parentHost` | initiator 的 WWPN／IQN，以及它所屬的 host | Dell 自己的 `HostInitiatorsDisplayFields` |
| `initiatorType` | `'1'` 是 FC、`'2'` 是 iSCSI —— **字串** | Dell 自己的常數 |
| `entries[].content`、`content` | 兩種回應形狀 | 文件記載 |

欄位是 **opt-in**：不帶 `?fields=` 的請求，回來幾乎什麼都沒有。所以第一個要預期
的失敗模式是「物件看起來是**空的**」而不是「**不存在**」，而那是兩個不同的答案。

| 未解的問題 | 為什麼重要 |
|---|---|
| SCSI 的 vendor 與 product 字串。`DGC` / `VRAID` 是承襲自 CLARiiON 的寫法，也是本外掛用來過濾的依據；若是錯的，任何裝置都不會被辨識 | 這道閘門決定外掛會去碰哪些裝置 —— 請以 `sg_inq /dev/sdX` 確認 |
| WWN 轉 WWID 的換算 | 這一項錯了，裝置探索會完全無法運作 |
| `POST /instances/snap/<id>/action/restore` | 唯一**不在** Dell 客戶端裡的破壞性呼叫，因為 CSI driver 從來不需要倒回 |
| 陣列對 LUN 大小是無條件進位還是捨去 | 本外掛會先向上對齊到 8 KiB，因此無論哪一種都不會出問題 |
| Unisphere 接受的最小 LUN 容量 | 假設為 1 GiB，比查到的任何參考值都再向上取；極小的磁碟區（EFI disk 與 TPM state，各 4 MiB）會被向上補到這個值 —— 取太大只是浪費空間，取太小則會讓 `qm create` 整個失敗 |
| 一個 base resource 支援多少個精簡複製、一個 LUN family 能帶多少快照 | Dell 白皮書顯示兩者都有上限；連結複製數超過上限的範本會被陣列拒絕。用戶端不做強制 —— 陣列的拒絕才是權威 |
| 快照 restore 的 `copyName` 是否真的為自動備份快照命名 | Dell 白皮書記載每次 restore 都會產生一個備份快照；若 `copyName` 被忽略，備份會拿到陣列自取的名稱，快照清理認不得它，磁碟區從此刪不掉。**第一次 `qm rollback` 之後，請檢查有沒有名為 `<磁碟區>.pve-snap-rollback*` 的快照** |
| HLU 能不能指定 | 沒有任何東西依賴它；Unity 自行配發 |

### 沒有 Unity 也能測 Unity

`github.com/mackayd/Unity-API-Emulator` 是一個單一 Python 檔，它會說 Unity 的
REST 信封格式：`entries`／`content` 兩種形狀、`?fields=`、篩選、分頁、`name:`
查詢，以及兩條認證規則 —— 缺少 `X-EMC-REST-CLIENT` 時回 **302**，寫入時缺少
`EMC-CSRF-TOKEN` 則回 **403**。

```bash
git clone https://github.com/mackayd/Unity-API-Emulator
python3 Unity_RestAPI_Emulator.py --port 18443 \
    --username admin --password 'Password123!' \
    --strict-auth --require-csrf --quiet
```

然後把儲存指向 `127.0.0.1:18443`，並設定 `dell-ssl-verify 0`。

**它不是 Dell 的產品，也不會模擬儲存行為。** 它無法告訴你刪除是否真的刪掉了、
WWID 是否對得上一顆裝置、對應是否真的送達主機。它能做的是在**真實 HTTP** 上
驗證傳輸層、認證、回應形狀與請求內容 —— 而在有硬體之前，這裡沒有其他東西做得到。

它已經證明了自己的價值：這個模擬器對 `createLun` 回的是 204 且沒有內容，而那讓
`volume_create` 靜靜回傳了 `undef`。某些韌體的真實陣列可能也是如此，或以非同步
job 回應。現在每一個建立動作都會退回「用剛才那個名稱查一次」，而如果連那樣都無法
回答，就會大聲失敗。

### PowerStore（出自 4.x REST 文件）

請求的形狀有一部分**確實是**從《Dell PowerStore REST API Developers Guide》讀出來的。為了讓第一位實測者能把它與其餘推測區分開來，列在這裡：

| 從指南讀到的 | 內容 |
|---|---|
| session | `GET /login_session` 搭配 HTTP Basic，會回傳 `DELL-EMC-TOKEN` 標頭與 `auth_cookie`；兩者共同構成後續請求的憑證 |
| CSRF | 「Requests other than GET require the DELL-EMC-TOKEN header」—— token 取自某次 GET 的回應，因此本外掛也會採用任何回應給出的最新一份 |
| 過濾寫法 | `?<attribute>=[not.]<operator>.<value>` |
| 運算子 | `eq` `neq` `gt` `gte` `lt` `lte` `ilike` `in` `is` `cs` `cd` |
| `ilike` 萬用字元 | 指南裡每一個範例都寫成 `*`（`?name=ilike.User*`），本外掛送出的也是這一種 |
| 參數 | `select`（以逗號分隔的屬性）、`order`、`async` |
| 端點 | 本外掛用到的每一個路徑，都能在 Dell 的 `python-powerstore` SDK 裡逐字找到：`/login_session`、`/logout`、`/cluster`、`/appliance`、`/volume`、`/volume/{id}`、`/volume/{id}/attach`、`/detach`、`/restore`、`/snapshot`、`/clone`、`/host`、`/host/{id}`、`/host_group`、`/host_volume_mapping`、`/ip_pool_address`、`/ip_port/{id}`、`/job/{id}` |
| 請求內容 | 同一份 SDK 的 `provisioning.py` 送出的就是這些：建立 volume `{name, size, appliance_id, volume_group_id, performance_policy_id, protection_policy_id, description}`；attach／detach `{host_id 或 host_group_id, logical_unit_number}`；restore `{from_snap_id, create_backup_snap}`；clone `{name}`；snapshot `{name}`；建立 host `{name, os_type, initiators}`；新增 initiator 用 PATCH `{add_initiators}` |
| Initiator | `[{port_name, port_type}]`，`port_type` 為 `iSCSI`、`FC`、`NVMe` 之一，`os_type` 為 `Windows`、`Linux`、`ESXi`、`AIX`、`HP-UX`、`Solaris` 之一 —— 這是 `ansible-powerstore` 記載的列舉值 |
| 效能與容量指標 | `POST /metrics/generate`，帶 `{entity, entity_id, interval}`。`space_metrics_by_cluster` 是**那個呼叫的 entity 名稱**，不是一個 REST 集合 —— 而把它當成集合來讀，正是本外掛原本的做法 |
| 分頁 | URL 參數 `limit`（1～2000，預設 100）與 `offset`，或用 `Range` 請求標頭 |
| 部分結果 | 集合超過 limit 時回應 `206 Partial Content`，並帶 `Content-Range: 0-99/1000` —— 斜線之後的數字是總筆數 |
| offset 超過結尾 | `416 Range Not Satisfiable`。分頁過程中若集合在兩頁之間變短，是有可能正常遇到的，因此它會結束分頁而不是失敗 |

如果陣列對萬用字元的解讀不同，過濾就會一筆都對不上：陣列上明明還在的 volume，會整批從 PVE 消失。因此以名稱前置字串列舉時若回傳空集合，會再查一次不帶過濾條件的版本、改在本地比對，並印出一行指出原因的警告。看到那行警告請回報。

以下是仍未確定的**回應**欄位名稱 —— 也就是陣列實際放進每一列的內容，這部分在 3.x 與 4.x 之間有差異。其中數項現在已由 Dell `ansible-powerstore` collection 裡的範例回應佐證，逐列註明；其餘仍屬推測。

| 欄位 | 用途 | 狀態 |
|---|---|---|
| `id`、`name`、`size`、`logical_used` | volume | 四者都出現在 Dell `ansible-powerstore` 的 volume 範例中；`size` 的單位是位元組 |
| `wwn` | 主機將看到的 WWID | 範例中是 `naa.68ccf09800ac8ab0e2506d99bee29e40` —— 正是本外掛會轉換的 `naa.` 形式。但仍**未與主機自己的 `scsi_id` 比對過**，那才是該確認的事 |
| `state`、`type` | 是否可用、Primary 或 Snapshot | 範例中是 `Ready` 與 `Primary`，正是本外掛送出的過濾值 |
| `protection_data.source_id` | 精簡複製是從哪個快照來的 | 範例的 `protection_data` 帶有 `source_id`、`parent_id`、`family_id` |
| `creation_timestamp` | 快照時間 | 範例是 `2022-01-06T05:41:59.381459+00:00` —— 小數秒與明確的時區位移，兩者都已處理 |
| `appliance_id` | volume 位於哪一台 appliance | 範例中有 |
| `physical_total`、`physical_used`、`total_physical`、`total_used` | 容量，取自指標記錄 | **未驗證** |
| `host_id`、`host_group_id`、`logical_unit_number`、`volume_id` | 對應資料列 | 與 attach／detach 請求內容所用的名稱相同，Dell 的 SDK 已確認 |
| `address`、`target_iqn` | iSCSI portal | **未驗證** |
| `purposes` | 哪些位址對外提供 iSCSI target —— 是一個清單，但單一字串也一併接受 | **未驗證** |
| `messages[].message_l10n`、`messages[].code` | 陣列自己的錯誤文字 | **未驗證** |

### PowerFlex（出自 REST 文件）

| 欄位 | 用途 | 狀態 |
|---|---|---|
| `id`、`name`、`sizeInKb`、`volumeSizeInKb` | volume | 已旁證 |
| `ancestorVolumeId` | 快照是從哪個 volume 來的 | Dell 自己的 `ansible-powerflex` volume 模組有記載，出現在快照物件上 |
| `creationTime` | 快照時間 | 同一來源，volume 物件上的 epoch 時間 |
| `mappedSdcInfo`、`sdcId` | 對應 | 同一來源：`mappedSdcInfo` 帶有 `sdcId`、`sdcName`、`sdcIp`、`accessMode`、`limitIops` |
| `hostId` | NVMe host 的對應，與 `sdcId` 一併讀取 | **未驗證** —— SDC 時代的文件並沒有這個欄位，而讀取一個不存在的欄位不會有任何代價 |
| `mappedHostInfo` | NVMe host 的對應，與 `mappedSdcInfo` 一併讀取 —— 因為這裡回答「空的」等於「再對映一次」 | **未驗證** |
| `sdcGuid`、`sdcIp` | 找出本節點的 SDC | **未驗證** |
| `maxCapacityInKb`、`capacityInUseInKb`、`thinCapacityInUseInKb` | 儲存池容量 | **未驗證** |
| `protectionDomainId`、`protectionDomainName` | 解析有歧義的儲存池名稱 | 兩者都出現在 `ansible-powerflex` 的 volume 物件上 |
| `capacityAvailableForVolumeAllocationInKb` | 儲存池容量，備援欄位 | **未驗證** |
| `access_token`、`refresh_token` | 4.x 的登入回應 | **未驗證** |
| `errorCode`、`message` | 陣列自己的錯誤文字 | **未驗證** |
| `volumeIdList` | 快照請求建立出來的 id | **未驗證** |
| `ipList`（每一筆帶 `ip` 與 `role`） | host 可以連線的 SDT 位址 | Dell 的 `ansible-powerflex` sdt 模組兩者都有列出，role 為 `StorageOnly`／`HostOnly`／`StorageAndHost` |
| `nvmePort` | host 連線用的連接埠，Dell 範例中為 4420 | 同一來源。**不是 `storagePort`** —— 那是 12200，走的是 SDS 與 SDT 之間的流量 |
| `discoveryPort` | 探索 subsystem NQN 的連接埠，Dell 範例中為 8009 | 同一來源 |
| `systemNqn`、`nqn` | 萬一某個 SDT 真的帶有 subsystem NQN | **未驗證，而且 Dell 列出的 SDT 欄位裡兩者都沒有** —— 因此改用 `nvme discover` 取得 |


欄位不存在時不會大聲失敗。容量會讀成 0、WWID 讀成 undef、可用空間讀成滿的。本外掛對其中幾種情況會拒絕動作 —— 例如一次完全讀不到 WWID 的清理，會直接放棄而不是當成「所有 volume 都被刪了」—— 但真正的解法只有一個：拿這張表跟一份真實回應比對。

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
| 24 | LUN ID 攀升 | 反覆對應與解除對應 300 次 | ID 維持在低位且密集 | — |
| 25 | Fibre Channel | FC fabric | 重跑第 1〜24 項 | — |
| 26 | PVE 9.1 升級到 9.2 | — | 外掛仍正常，`get_identity` 正常回傳 | — |

## 1.0.0 的長時間測試門檻

除了上述矩陣之外：

- 連續 72 小時的 pvestatd 輪詢，沒有誤報 `inactive`，journal 也沒有錯誤累積
- 管理網路中斷 10 分鐘後恢復：儲存自行回到 `active`，執行中的 VM 全程沒有 I/O 中斷
- 完成第 24 項之後，LUN ID 仍維持在低位
