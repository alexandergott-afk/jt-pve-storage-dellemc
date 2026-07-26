# jt-pve-storage-dellemc

Dell EMC 儲存陣列的 Proxmox VE 儲存外掛。

**[English](README.md)**

一個套件、一組共用的主機端底層，Dell EMC 每個產品系列各自對應一個 PVE storage type。第一個實作的系列是 **PowerStore**（iSCSI 或 Fibre Channel），採用直接配置 volume 的模型（一顆 VM 磁碟 = 一個陣列 volume），讓陣列端的快照、精簡複製、壓縮與複寫都以「一顆 VM 磁碟」為自然單位運作。

---

## 專案狀態

> **版本 0.2.0 — 共用 Common 層（Phase 1）。**
> 本套件仍**尚未**註冊任何 storage type，目前包含建置系統、打包、安全檢查工具，以及各系列 plugin 之後要建立在其上的模組。請勿當成可用的儲存後端部署。

| 階段 | 內容 | 狀態 |
|---|---|---|
| 0 | 骨架：Makefile、`debian/`、CI、README | **已完成** |
| 1 | Common 層：Naming、REST、Multipath、ISCSI、FC、WwidState、Health | **已完成** |
| 2 | `Common::BlockBase` 抽象 plugin 基底 | 規劃中 |
| 3 | PowerStore REST API 客戶端 | 規劃中 |
| 4 | `dellpowerstore` plugin、文件、iSCSI 實機測試 | 規劃中 |
| 5 | FC 驗證、PVE 9.2 驗證、發佈 1.0.0 | 規劃中 |
| 6+ | PowerMax／PowerFlex／PowerScale（另立子規格） | 未開始 |

完整開發規格請見 [`jt-pve-storage-dellemc.md`](jt-pve-storage-dellemc.md)。

## 產品系列

Dell EMC 各產品線的差異太大，無法共用同一個 PVE storage type，因此每個系列各自對應一個 type，原因詳見 [ARCHITECTURE_zh-TW.md](docs/ARCHITECTURE_zh-TW.md)。各系列共用主機端底層，所以新增一個系列只需要一個 plugin 檔加一個 API 客戶端，不必重構。

| 系列 | PVE storage type | 資料路徑 | 狀態 |
|---|---|---|---|
| **PowerStore** | `dellpowerstore` | iSCSI／FC（dm-multipath） | **開發中** |
| PowerMax | `dellpowermax` | FC／iSCSI（dm-multipath） | 規劃中 |
| PowerFlex | `dellpowerflex` | SDC kernel module（`/dev/scini*`） | 規劃中，視需求 |
| PowerScale | `dellpowerscale` | NFS（目錄語意） | 規劃中，低優先 |
| Unity XT | `dellunity` | iSCSI／FC | 未排入 |
| PowerVault ME5 | `dellme5` | iSCSI／FC／SAS | 未排入 |
| ObjectScale、PowerProtect | — | — | 不列入範圍 |

物件儲存與備份設備類產品是刻意排除的：它們並不適合 PVE storage plugin 的模型。

---

## 重要：Multipath 安全規則

以下規則不是風格偏好。違反任何一條，都可能讓整台節點失去服務能力，包括與本外掛完全無關的其他儲存。

1. **絕對不要執行 `multipath -F`（大寫 F）。** 它會清掉節點上所有未使用的 multipath map，影響範圍是全系統。在混合儲存的節點上，這會斷開當下剛好閒置的任何 map，包含其他廠商、其他外掛建立的 map。要清除時一律只針對單一 map：`multipath -f /dev/mapper/<wwid>`（小寫 `f`）。本專案只要在任何檔案出現大寫 F 的全系統 flush，建置就會失敗，檢查方式見 `make check-multipath-flush`。

2. **請用 `systemctl restart multipathd`，不要用 `systemctl reload multipathd`。** reload 只會重讀設定檔，restart 才會真正重新套用 device-mapper 狀態。

3. **避免 `no_path_retry queue` 與 `dev_loss_tmo infinity`。** 在有殘留裝置的情況下，永遠無法完成的排隊 I/O 會讓 PVE 服務進入不可中斷睡眠（D state），任何訊號都殺不掉，只能重開機。請改用 `no_path_retry 30`、`fast_io_fail_tmo 5`、`dev_loss_tmo 60`。

4. **外掛不會改寫非它建立的 multipath 設定檔。** 它自己產生的 drop-in 檔帶有版本標記；沒有標記的檔案視為管理者自有，完全不動。

5. **叢集內每一台節點都必須安裝本套件。** 少裝的節點在操作 Dell EMC 儲存時會出現 `Parameter verification failed (400)` 或 `No such storage`，且無法遷移 VM 到該節點。

---

## 免責聲明

- 本專案為**獨立的社群專案**，與 Dell Technologies 無隸屬關係，亦未經其背書或提供支援。「Dell」、「Dell EMC」、「PowerStore」、「PowerMax」、「PowerFlex」、「PowerScale」為各自所有權人之商標。
- 以 MIT 授權提供，**不附帶任何形式的保固**。是否適用於您的硬體、韌體版本與工作負載，需由您自行驗證後再投入正式環境。
- **尚未於實機驗證**的項目，會在 `docs/TESTING.md` 標記 `NOT VERIFIED ON HARDWARE`。截至 0.1.0，所有面向陣列的行為都屬於此類：REST 端點與欄位名稱、multipath 比對用的 SCSI vendor／product 字串，以及 WWN 轉 WWID 的換算方式。
- 請務必先在非正式環境的叢集與陣列上測試，並對放在本儲存上的資料另行保留獨立備份。

---

## 系統需求

| 項目 | 需求 |
|---|---|
| Proxmox VE | 9.1 以上（Storage API 13） |
| PowerStore OS | 3.0 以上（REST API v3），以 4.x 為主要開發目標 |
| Perl 模組 | `libwww-perl`、`libjson-perl`、`liburi-perl` |
| 系統工具 | `open-iscsi`、`multipath-tools`、`sg3-utils`、`psmisc`（建議加裝 `lsscsi`） |

---

## 安裝

從原始碼建置：

```bash
make test            # 對每個模組跑 perl -c，並執行 multipath 安全檢查
make deb             # 產出 ../jt-pve-storage-dellemc_<version>_all.deb
```

在**每一台**節點上安裝：

```bash
apt install ./jt-pve-storage-dellemc_<version>_all.deb
```

請使用 `apt install ./file.deb`，不要用 `dpkg -i`：`dpkg -i` 不會自動安裝相依套件，缺少的執行檔會等到外掛實際操作時才以難以解讀的錯誤浮現。

升級後請在每一台節點執行 `systemctl restart pvestatd`；reload 無法可靠地替換已載入記憶體的 Perl 模組。

---

## 設定

Phase 4 完成後，新增 PowerStore 儲存的方式如下：

```bash
pvesm add dellpowerstore ps1 \
    --dell-portal 192.168.1.50 \
    --dell-username pveadmin \
    --dell-password 'SecurePassword' \
    --dell-protocol iscsi \
    --pstore-volume-group pve-vg \
    --content images,rootdir \
    --shared 1
```

參數說明：[`docs/CONFIGURATION_zh-TW.md`](docs/CONFIGURATION_zh-TW.md)。
初次設定：[`docs/QUICKSTART_zh-TW.md`](docs/QUICKSTART_zh-TW.md)。

---

## 已知限制

- **完整複製（Full Clone）不會使用陣列端的複製功能。** PVE 對完整複製的實作是 `alloc_image` 加上 `qemu-img` 逐區塊複製，根本不會呼叫外掛的 `clone_image`。這是 PVE 的架構決策，不是外掛缺陷。想用陣列的精簡複製，請改用連結複製（Linked Clone）。
- **不支援縮小 volume。** 只允許擴充；縮小的請求會被擋下，而不是默默截斷客體的檔案系統。
- **外掛只會碰自己管理的物件。** 所有列舉、刪除與清理路徑都會先過濾名稱前綴 `pve-<storeid>-`，陣列上其他物件一律不讀也不改。

---

## 文件

| 文件 | 說明 |
|---|---|
| [`docs/QUICKSTART_zh-TW.md`](docs/QUICKSTART_zh-TW.md) | 幾分鐘內建立第一個儲存 |
| [`docs/CONFIGURATION_zh-TW.md`](docs/CONFIGURATION_zh-TW.md) | 所有 `storage.cfg` 參數 |
| [`docs/ARCHITECTURE_zh-TW.md`](docs/ARCHITECTURE_zh-TW.md) | 多系列架構與擴充方式 |
| [`docs/NAMING_CONVENTIONS_zh-TW.md`](docs/NAMING_CONVENTIONS_zh-TW.md) | PVE 物件與陣列物件的命名對照 |
| [`docs/TROUBLESHOOTING_zh-TW.md`](docs/TROUBLESHOOTING_zh-TW.md) | 症狀、成因與復原方式 |
| [`docs/TESTING_zh-TW.md`](docs/TESTING_zh-TW.md) | 測試矩陣與實機驗證狀態 |

---

## 相關專案

- [jt-pve-storage-purestorage](https://github.com/jasoncheng7115/jt-pve-storage-purestorage)
- [jt-pve-storage-netapp](https://github.com/jasoncheng7115/jt-pve-storage-netapp)

## 授權

MIT，詳見 [LICENSE](LICENSE)。

## 作者

Jason Cheng（節省工具箱有限公司 / Jason Tools）&lt;jason@jason.tools&gt;
