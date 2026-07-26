# 變更紀錄

本專案所有值得記錄的變更都寫在這裡。
English version: [CHANGELOG.md](CHANGELOG.md)

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
