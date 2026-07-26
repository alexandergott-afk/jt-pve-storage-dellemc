# 變更紀錄

本專案所有值得記錄的變更都寫在這裡。
English version: [CHANGELOG.md](CHANGELOG.md)

## [0.6.0~beta1] - 2026-07-26

新增 PowerVault ME4／ME5 系列的 `dellpowervault` storage type。

仍是 beta，也仍未經實機驗證。這次不同的是：面向陣列的細節是實際讀取《Dell PowerVault ME5 Series CLI Reference Guide》而來，不是憑記憶撰寫；[docs/TESTING_zh-TW.md](docs/TESTING_zh-TW.md) 也把「來自官方文件」與「尚未查證」分開列出。

### 新增
- `PowerVault/API.pm`、`PowerVault/Naming.pm` 與 `DellPowerVaultPlugin.pm`。
- 新增 154 個單元測試，總計 867 個。

### 這個系列的不同之處，以及為什麼重要
- **HTTP 200 不代表成功。** ME 是把 CLI 透過 HTTPS 開放出來；被拒絕的指令一樣回 200，判斷結果放在 `status` 物件裡。若以 HTTP 狀態碼為準，建立失敗的 volume 看起來會像成功，PVE 就會記錄一顆並不存在的磁碟。
- **`expand volume` 收的是增量，不是總量。** PVE 給的是新的絕對容量。直接傳過去，會把使用者要求擴充到 33 GiB 的 32 GiB volume 變成 64 GiB。
- **容量在這裡要向上取整。** 陣列以 4 MiB 對齊且**向下**取整，所以客戶端必須先向上取整，否則實際 volume 會小於 PVE 以為的大小。
- **名稱上限 32 bytes 且不可含句點。** 因此這個系列有自己的命名模組：較短的物件名稱、以 `-s-` 而非句點作為快照分隔符號，以及 storeid 的 10 字元額度。放不下的名稱會直接報錯，而不是被截斷成可能與其他 VM 撞名的名稱。
- **連結複製就是快照。** ME 的快照可寫入也可對應，所以複製即是「取一個 volume 形狀名稱的快照」—— 瞬間完成，且不複製資料。

### 變更
- 路線圖：PowerStore → PowerVault ME → PowerFlex → PowerMax；PowerScale 未排入。
- type 字串為 `dellpowervault` 而非 `dellme5`：其他系列都以產品線而非型號命名，而且 ME4 與 ME5 共用同一套 API。

## [0.5.0~beta1] - 2026-07-26

Phase 2 至 4。`dellpowerstore` storage type 已經存在。

> 它**尚未**在任何 PowerStore 陣列上執行過。所有面向陣列的細節在 [docs/TESTING_zh-TW.md](docs/TESTING_zh-TW.md) 中仍標記為未驗證。1.0.0 的門檻是實機測試通過，而不是再寫更多程式。

### 新增
- `Common/BlockBase.pm`：抽象的 PVE plugin 基底。SAN 啟用、配置、裝置探索與拆除、快照、範本、複製、multipath drop-in，以及背景 orphan 清理 —— 全部與「背後是哪一台陣列」無關。系列 plugin 只需實作 `_array_*` 方法，其餘全部繼承。
- `PowerStore/API.pm`：涵蓋 volume、快照、精簡複製、host、對應關係與傳輸端點的 REST 客戶端，附 fixture 與 96 項請求格式測試。
- `PowerStore/Naming.pm`：PowerStore 較寬鬆的名稱限制。
- `DellPowerStorePlugin.pm`：storage type 本身，以及 PVE 要註冊的 schema。
- `bin/pve-dell-config-get`：把每次快照旁邊那個設定備份卷裡的 VM 設定讀回來。復原模式下它會自己解析 `storage.cfg`，或直接由命令列取得陣列資訊，完全不經過 pvesm —— 因為這個工具存在的情境，正是 `/etc/pve` 已經不在、或 pvedaemon 起不來的時候。
- 文件：快速上手、設定參數說明、架構說明、疑難排解、命名慣例與實機測試矩陣，皆有英文與繁體中文版本，另有 `docs/` 底下的專案頁面。

### 值得知道的行為
- Volume 在建立時就會對應到所有節點，讓線上遷移不必先重新對應；而解除對應一律在刪除之前 —— 相反的順序會讓任何節點上正在進行的重新掃描把該 LUN 重新匯入，在刪除的背後又把裝置建回來。
- LUN ID 由外掛自行配發，從 `pstore-lun-id-base` 往上補空號。PowerStore 自己的 REST 端序列從 200 開始且不重用 ID，因此不斷掛載卸載的叢集，最終會把它推到超過主機掃描範圍，新磁碟就再也不會出現。
- Volume 容量會向上對齊 PowerStore 要求的 8 KiB 粒度。向下取整會交回一個比 PVE 要求還小的 volume。
- `make syntax` 對需要 Proxmox VE 的模組會回報為「已跳過」而不是失敗，讓一般 CI runner 上的結果是誠實的，而不是碰巧變綠。

## [0.2.0] - 2026-07-26

Phase 1 — 共用的 Common 層。尚未註冊任何 storage type，這些是各系列 plugin 之後要建立在其上的模組。

### 新增
- `Common/Naming.pm`：物件命名、PVE volume 名稱轉換，以及 `is_pve_managed_volume` 這道 `pve-<storeid>-` 歸屬檢查 —— 所有列舉、刪除與清理路徑都必須先通過它。全部採用 class method，讓各系列以繼承方式放寬名稱長度限制，不需引入共用的可變狀態；因為單一 PVE 行程會同時載入所有 Dell plugin。
- `Common/REST.pm`：HTTP 傳輸層。POST 遇到 5xx 一律不重試，因為請求可能已經在陣列上生效，重試會多建立一個 volume。401 會清掉 session 並重新登入重試一次。429／503 採退避策略，遵守 `Retry-After` 但上限 30 秒。session 記錄建立它的行程編號，讓 fork 出來的 PVE worker 重新認證，而不是沿用不屬於自己的 session。以 `retries => 1` 搭配短逾時建構，即為 `activate_storage` 與 `status()` 所需的健康檢查用戶端。
- `Common/Multipath.pm`：裝置生命週期處理，自 NetApp 與 Pure plugin 移植並將 vendor 判斷參數化。程式中絕不會產生 `multipath -F`：`multipath_flush` 一定要有裝置參數。所有 sysfs 存取都在有逾時限制的子行程中進行，因為直接讀取已失效的 LUN 會陷入任何訊號都無法中斷的睡眠狀態。
- `Common/ISCSI.pm`：initiator 身分、portal 預檢、session 生命週期，以及會跳過非 `LOGGED_IN` session 的逐一 rescan。
- `Common/FC.pm`：HBA 探索與 WWN 正規化（同一個 WWN 會以三種寫法出現）。預設不發出 LIP。
- `Common/WwidState.pm`：節點端的 WWID 追蹤，包含 orphan 清理前必須同時通過的寬限期與連續未命中門檻，以及同節點其他 Dell 儲存的辨識，避免把別的儲存正在使用的裝置誤報為殘留。
- `Common/Health.pm`：`status()` 用的中斷偵測與容量告警，並加上頻率限制，避免約 10 秒一次的輪詢灌爆 journal。
- 342 個單元測試（`t/01-naming.t` 至 `t/05-state.t`），在不需要陣列與實體裝置的前提下涵蓋重試策略、清理防護、歸屬檢查與 taint 處理。

### 修正
- 有頻率限制的健康訊息改為明確判斷「從未發送過」，並把未來的時間戳記視為應該發送。先前兩者都依賴與 0 相比的 epoch 運算，因此時鐘往回校正一次，就可能在時差消失前一直把真正的中斷事件靜音。

## [0.1.0] - 2026-07-26

Phase 0 — 專案骨架。本版本尚未註冊任何 storage type。

### 新增
- MIT 授權、雙語 README 骨架（含 multipath 安全規則與實機驗證免責聲明）。
- `Makefile`，提供 `install`、`uninstall`、`test`、`syntax`、`unit`、`check-multipath-flush`、`deb`、`clean` 等目標。模組清單改由 `lib/**/*.pm` 自動探索，不需手動維護，後續各階段新增模組時打包設定不必跟著改。
- Debian 打包檔：`control`、`rules`、`compat`、`changelog`、`copyright`、`docs`、`postinst`、`prerm`、`postrm`。安裝動作透過 `override_dh_auto_install` 交由 Makefile 執行。
- `postinst` 檢查項目：必要執行檔是否存在（可攔截以 `dpkg -i` 安裝而未解相依的情況）、`/etc/multipath.conf` 與 `/etc/multipath/conf.d/*.conf` 中的危險設定、所有路徑皆失效的 Dell 殘留 map、缺少 LVM `global_filter`、進行中的儲存操作，以及叢集全節點安裝提醒。
- GitHub Actions 工作流程：安全檢查、`perl -c` 與單元測試通過後才建置 `.deb`。
- CI 檢查 `make check-multipath-flush`：只要程式碼或文件出現全系統 flush 的大寫 F 指令，建置即失敗；明確禁止該指令的敘述文字則放行。
- 多系列架構的目錄骨架（`lib/PVE/Storage/Custom/`、`DellEMC/Common/`、各系列子目錄、`t/`、`docs/`、`bin/`）。
