# jt-pve-storage-dellemc

Dell EMC 儲存伺服器的 Proxmox VE 儲存外掛。

**[專案文件網站](https://jasoncheng7115.github.io/jt-pve-storage-dellemc/)** &middot; **[English](README.md)**

> ## ⚠️ BETA 版軟體 —— 安裝前請務必閱讀
>
> **這是 beta 版（0.8.12~beta1），而且只有一台儲存伺服器跑過它**：一台韌體為 `GT280R011-01`、走 Fibre Channel 的 PowerVault ME4024，自 0.7.65 起完整通過首次執行測試，並在 0.7.66 通過其後的生命週期項目 —— 客體作業系統從儲存伺服器 volume 開機、擴充磁碟、`vzdump --mode snapshot` 與還原、LXC 容器，以及節點重開機。**其餘的一切都尚未經過實機驗證** —— PowerStore 與 PowerFlex 完全沒有，PowerVault 這邊的 iSCSI 與 SAS 路徑也沒有，因為那台儲存伺服器走的是 FC。[docs/TESTING_zh-TW.md](docs/TESTING_zh-TW.md) 逐項列出了哪些是哪些；在信任這裡任何一項之前，請先讀它。
>
> **請不要安裝在正式環境的叢集，也不要指向存有重要資料的儲存伺服器。** 儲存外掛是以 root 權限執行的，它會在儲存伺服器上建立與刪除 volume，並在每一台節點上操作區塊裝置。這裡的缺陷可能毀掉虛擬機資料、讓儲存離線，或讓節點進入只能重開機才能恢復的狀態；而且因為 multipath 與 SCSI 狀態是全節點共用的，受害範圍不一定只限於本外掛自己的儲存。
>
> 請使用測試用叢集、測試用儲存伺服器，並對放上去的任何資料保留獨立備份。詳見下方的[免責聲明與風險](#免責聲明與風險)，以及 [docs/TESTING_zh-TW.md](docs/TESTING_zh-TW.md) 中「哪些已驗證、哪些還沒」的完整清單。

一個套件、一組共用的主機端底層，Dell EMC 每個產品系列各自對應一個 PVE storage type。最早實作的系列是 **PowerStore**（iSCSI 或 Fibre Channel），而已經在實機上驗證過的是 **PowerVault ME**。所有系列都採用直接配置 volume 的模型（一顆 VM 磁碟 = 一個儲存伺服器 volume），讓儲存伺服器端的快照、精簡複製、壓縮與複寫都以「一顆 VM 磁碟」為自然單位運作。

---

## 專案狀態

> **版本 0.8.12~beta1 — 三個 storage type 程式碼皆已完成，其中一個已在實機上完整跑過：PowerVault ME，走 Fibre Channel，機型 ME4024。**
> PowerStore 與 PowerFlex 從未在任何儲存伺服器上執行過，PowerVault 這邊的 iSCSI 與 SAS 路徑也沒有 —— 對這些而言，所有面向儲存伺服器的細節（REST 路徑與欄位名稱、SCSI vendor／product 字串、WWN 轉 WWID 換算）都還沒驗證。因此這仍然是一個「拿來測試」的版本，請只在非正式環境的叢集與儲存伺服器上使用。1.0.0 的門檻是**每一個**產品系列都通過實機測試，而不是再寫更多程式。

| 階段 | 內容 | 狀態 |
|---|---|---|
| 0 | 骨架：Makefile、`debian/`、CI、README | **已完成** |
| 1 | Common 層：Naming、REST、Multipath、ISCSI、FC、WwidState、Health | **已完成** |
| 2 | `Common::BlockBase` 抽象 plugin 基底 | **已完成** |
| 3 | PowerStore REST API 客戶端 | **已完成** |
| 4 | `dellpowerstore` plugin、災難復原工具、文件 | **程式碼已完成**，實機測試未進行 |
| 5 | FC 驗證、PVE 9.2 驗證、1.0.0 發行 | FC 已在一台 PowerVault ME4024 上**驗證通過**；1.0.0 仍待另外兩個系列 |
| 6 | `dellpowervault` 外掛，支援 PowerVault ME4／ME5 | **已在一台 ME4024 上以 FC 通過實機測試**（0.7.65）；iSCSI 與 SAS 仍待驗證 |
| 7 | `dellpowerflex` plugin，NVMe/TCP 與 SDC | **程式碼已完成**，實機測試未進行 |
| 8 | Unity XT 的 `dellunity` 外掛 | **程式碼已完成**，實機測試未進行 |
| 9+ | PowerMax | 未開始 |

## 產品系列

Dell EMC 各產品線的差異太大，無法共用同一個 PVE storage type，因此每個系列各自對應一個 type，原因詳見 [ARCHITECTURE_zh-TW.md](docs/ARCHITECTURE_zh-TW.md)。各系列共用主機端底層，所以新增一個系列只需要一個 plugin 檔加一個 API 客戶端，不必重構。

| 順序 | 系列 | PVE storage type | 資料路徑 | 狀態 |
|---|---|---|---|---|
| 1 | **PowerStore** | `dellpowerstore` | iSCSI／FC（dm-multipath） | **開發中** |
| 2 | **PowerVault ME4／ME5** | `dellpowervault` | iSCSI／FC／SAS（dm-multipath） | **開發中** |
| 3 | **PowerFlex** | `dellpowerflex` | NVMe/TCP 或 SDC | **開發中** |
| 4 | **Unity XT** | `dellunity` | iSCSI / FC（dm-multipath） | **開發中** |
| 5 | PowerMax | `dellpowermax` | FC／iSCSI（dm-multipath）、NVMe/FC 與 NVMe/TCP（NVMe-oF） | 規劃中 |
| — | PowerScale | `dellpowerscale` | NFS（目錄語意） | 未排入 |
| — | ObjectScale、PowerProtect | — | — | 不列入範圍 |

PowerStore、PowerVault ME 與 PowerMax 共用 block 基底類別；PowerFlex 不是，它的 volume 是透過 SDC kernel module 或 NVMe/TCP namespace 出現，沒有 SAN 登入，也不走 dm-multipath。

PowerScale 未排入。它是 NAS，需要自己的目錄語意與 content type，而不是這裡其他系列共用的 block 層；而且 Proxmox VE 內建的 NFS 儲存已經涵蓋它大部分的功能。

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

## 免責聲明與風險

### 開發狀態

這是**測試版（beta）軟體**，公開的目的就是為了被測試。至今只有一台儲存伺服器、以一種通訊協定跑過它。在 [docs/TESTING_zh-TW.md](docs/TESTING_zh-TW.md) 中仍標記為 `NOT VERIFIED ON HARDWARE` 的項目，都有可能根本就是錯的 —— 而那次實機測試翻出來的三個缺陷，一個藏在另一個後面，正是這句警告的意思。

### 可能發生什麼問題

Proxmox VE 的儲存外掛在每一台節點上都是以 root 權限執行。本外掛會在儲存伺服器上建立與刪除 volume、把 volume 對應到 host，並操作 SCSI 與 device-mapper 狀態。實際可能發生的故障包括：

- **資料遺失。** 被刪除的 volume、被還原覆蓋的內容，或因容量計算錯誤而被截斷的 volume，都會連同虛擬機的資料一起消失。
- **儲存中斷。** 啟用或狀態路徑上的缺陷可能讓儲存停在 `inactive`；而且因為 Proxmox VE 是依序輪詢儲存的，一個緩慢或卡住的儲存會拖累該節點上的其他所有儲存。
- **節點卡死。** 對沒有可用路徑的裝置持續 I/O，會讓行程進入不可中斷睡眠，任何訊號都無法清除，只能重開機。
- **波及其他儲存。** multipath 與 SCSI 狀態是整台節點共用的。裝置清理若出錯，可能影響到不屬於本外掛管理的儲存，包括其他廠商或其他外掛的儲存。

本專案的設計把這些都當一回事 —— 上面的安全規則、vendor 過濾、有逾時限制的裝置存取、以及名稱前置字串的歸屬邊界，都是為此而存在 —— 但「設計上是安全的」不等於「已被證明是安全的」。要取得那個證明，正是 1.0.0 的門檻。

### 不提供任何保固

本軟體以 [MIT 授權](LICENSE)提供，**依現狀（as is）提供，不附帶任何明示或默示的保固**，包括但不限於適售性、特定用途適用性與未侵權之保證。在任何情況下，作者均不對任何主張、損害或其他責任負責，包括資料遺失與營運中斷。

是否適用於您的硬體、韌體版本與工作負載，以及是否投入正式環境，完全由您自行評估與負責。

### 安裝之前

- 請使用**非正式環境**的 Proxmox VE 叢集與**非正式環境**的儲存伺服器。
- 對放在本儲存上的任何資料保留**獨立備份**。儲存快照不是備份。
- 閱讀 [docs/TESTING_zh-TW.md](docs/TESTING_zh-TW.md)，並針對您的儲存伺服器與韌體至少驗證其中列出的四個項目。
- 歡迎回報結果：[issues](https://github.com/jasoncheng7115/jt-pve-storage-dellemc/issues)。

### 商標與隸屬關係

本專案為**獨立的社群專案**，與 Dell Technologies 沒有隸屬關係，亦未經其背書、贊助或提供支援。「Dell」、「Dell EMC」、「PowerStore」、「PowerMax」、「PowerFlex」、「PowerScale」、「Unity」、「PowerVault」為各自所有權人之商標，此處僅用於指稱本軟體所連接的硬體。Proxmox 與 Proxmox VE 為 Proxmox Server Solutions GmbH 之商標。

---

## 系統需求

| 項目 | 需求 |
|---|---|
| Proxmox VE | 9.1 以上（Storage API 13） |
| PowerStore OS | 3.0 以上（REST API v3），以 4.x 為主要開發目標 |
| Perl 模組 | `libwww-perl`、`liblwp-protocol-https-perl`、`libjson-perl`、`liburi-perl` |
| 系統工具 | `open-iscsi`、`multipath-tools`、`sg3-utils`、`psmisc`（建議加裝 `lsscsi`） |

---

## 安裝

請從 [release 頁面](https://github.com/jasoncheng7115/jt-pve-storage-dellemc/releases) 安裝套件。那一份就是該版本測試時所用的建置；從原始碼建置是給要修改這個外掛的人用的，不是安裝用的。

### 1. 下載

每一版都會附一份檔名固定不變的副本，因此下面這道指令永遠會抓到最新的建置，也永遠不必修改：

```bash
curl -LO https://github.com/jasoncheng7115/jt-pve-storage-dellemc/releases/latest/download/jt-pve-storage-dellemc_all.deb
```

版本在套件裡面，不在檔名上 —— `apt` 與 `dpkg` 讀的是控制檔。想確認抓到的是哪一版：

```bash
dpkg-deb -f jt-pve-storage-dellemc_all.deb Version
```

### 2. 驗證

```bash
curl -LO https://github.com/jasoncheng7115/jt-pve-storage-dellemc/releases/latest/download/SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing    # 顯示 OK 之後才安裝
```

加上 `--ignore-missing` 是因為 `SHA256SUMS` 同時也列出同一個套件那份帶版號的副本，而你沒有下載它。release 頁面兩份都有：回報問題時請引用**帶版號**的那個檔名，腳本與說明文件則使用**固定**的那個。

帶版號的檔名，版本是用點分隔的 —— `jt-pve-storage-dellemc_0.7.66.beta1-1_all.deb` —— 因為 GitHub 不會提供檔名含 `~` 的附件。套件內部的版本不變。

請確實核對雜湊值。這個套件會寫入 `/etc/multipath/conf.d`，也會與你的儲存伺服器通訊。

### 3. 在每一台節點上安裝

```bash
apt install ./jt-pve-storage-dellemc_all.deb
```

叢集內**每一台**節點都要裝。少裝的節點會回應「Parameter verification failed (400)」或「No such storage」，也無法成為線上遷移的目的地。

請使用 `apt install ./file.deb`，不要用 `dpkg -i`：`dpkg -i` 不會自動安裝相依套件，缺少的執行檔會等到外掛實際操作時才以難以解讀的錯誤浮現。

### 4. 升級之後

```bash
systemctl restart pvestatd
```

每一台節點都要執行 —— reload 無法可靠地替換已載入記憶體的 Perl 模組。

### 從原始碼建置

只有在要修改這個外掛、或想針對你自己的 PVE 版本跑測試套件時才需要。

```bash
make test            # 對每個模組跑 perl -c，並執行 multipath 安全檢查
make deb             # 產出 ../jt-pve-storage-dellemc_<version>_all.deb
```

---

## 設定

### PowerStore

```bash
pvesm add dellpowerstore ps1 \
    --dell-portal 192.168.1.50 \
    --dell-username pveadmin \
    --dell-password 'SecurePassword' \
    --dell-protocol iscsi \
    --content images,rootdir \
    --shared 1
```

多 appliance 的叢集請加 `--pstore-appliance`；要把所有 volume 放進同一個群組請加 `--pstore-volume-group`；使用 Fibre Channel 請改 `--dell-protocol fc`。

### PowerVault ME4／ME5

```bash
pvesm add dellpowervault me5 \
    --dell-portal 192.168.1.60,192.168.1.61 \
    --dell-username manage \
    --dell-password 'SecurePassword' \
    --pvault-pool A \
    --content images,rootdir \
    --shared 1
```

**請以逗號把兩個控制器的管理 IP 都列入。** ME 每個控制器各有一個固定 IP、沒有浮動管理位址 —— 控制器故障時它的 IP 會跟著消失 —— 而 `dell-portal` 在儲存建立後不能修改，所以兩個一開始就要都填進去。外掛會在其間自動容錯；資料路徑不需要任何處理，dm-multipath 會自己接手。兩個位址可在儲存伺服器上以 `show network-parameters` 查得。

儲存伺服器有多個 pool 時 `--pvault-pool` 為必填。storage id 請取短一點：這個系列的名稱上限是 32 bytes，放不下的名稱會被拒絕而不是截斷。

### PowerFlex

```bash
pvesm add dellpowerflex pflex1 \
    --dell-portal 192.168.1.70 \
    --dell-username admin \
    --dell-password 'SecurePassword' \
    --dell-protocol nvme \
    --pflex-storage-pool pool1 \
    --content images,rootdir \
    --shared 1
```

`--pflex-storage-pool` 為必填。`--dell-protocol nvme`（預設）使用 kernel 內建的 NVMe/TCP initiator；`sdc` 使用 Dell 的 kernel module，必須由您自行安裝 —— 選用前請先閱讀 [docs/POWERFLEX_SDC_zh-TW.md](docs/POWERFLEX_SDC_zh-TW.md)。

參數說明：[`docs/CONFIGURATION_zh-TW.md`](docs/CONFIGURATION_zh-TW.md)。
初次設定：[`docs/QUICKSTART_zh-TW.md`](docs/QUICKSTART_zh-TW.md)。

---

### Unity XT

```bash
pvesm add dellunity u480 \
    --dell-portal 192.168.1.80 \
    --dell-username admin \
    --dell-password 'SecurePassword' \
    --dell-protocol fc \
    --unity-pool pool_1 \
    --content images,rootdir \
    --shared 1
```

Unity 的管理 IP 會跟著主 SP 走，填一個位址即可。儲存伺服器有多個儲存池時 `--unity-pool` 為必填。**這個系列從未在儲存伺服器上執行過** —— 第一次執行前請先讀 [docs/TESTING_zh-TW.md](docs/TESTING_zh-TW.md) 與 [docs/FIRST_RUN_zh-TW.md](docs/FIRST_RUN_zh-TW.md) 的 Unity 節。


## 已知限制

- **完整複製（Full Clone）不會使用儲存伺服器端的複製功能。** PVE 對完整複製的實作是 `alloc_image` 加上 `qemu-img` 逐區塊複製，根本不會呼叫外掛的 `clone_image`。這是 PVE 的架構決策，不是外掛缺陷。想用儲存伺服器的精簡複製，請改用連結複製（Linked Clone）。
- **只能還原到最新的快照。** Dell 的手冊說明了「從快照還原 volume」對該 volume 的影響，卻沒有說明那些在目標快照之後才建立的快照會怎麼樣。若儲存伺服器會把它們清掉，PVE 仍會繼續列出已經不存在的還原點，而這件事往往要到真正需要用它的那天才會被發現。因此本外掛會拒絕「不是還原到最新快照」的操作，並把擋住它的快照清單交給 PVE 顯示。請先刪掉那些較新的快照；若你已在自己的儲存伺服器上驗證過行為，也可以設定 `dell-rollback-any-snapshot 1`。
- **不支援縮小 volume。** 只允許擴充；縮小的請求會被擋下，而不是默默截斷客體的檔案系統。
- **PowerVault ME 系列不提供 VM 設定備份卷。** 在 PowerStore 上，每次對 VM 做快照時，也會把該 VM 的設定寫進一個 1 MB 的 volume，讓 `pve-dell-config-get` 在 `/etc/pve` 已經不存在時仍能把設定讀回來。代價是每個快照要多花一個 volume，而 ME 儲存伺服器的 volume 與快照上限比 PowerStore 少了大約一個數量級 —— 少到這個代價足以決定 volume 會不會用完。因此 `dellpowervault` 直接不提供這個功能；快照與還原完全不受影響，設定也仍然可以從 PVE 備份、或從叢集中其他節點的 `/etc/pve` 取回。在 PowerStore 上此功能預設開啟，可用 `dell-config-backup 0` 關閉。
- **外掛只會碰自己管理的物件。** 所有列舉、刪除與清理路徑都會先過濾名稱前置字串 `pve-<storeid>-`，儲存伺服器上其他物件一律不讀也不改。

---

## 文件

| 文件 | 說明 |
|---|---|
| [`docs/FIRST_RUN_zh-TW.md`](docs/FIRST_RUN_zh-TW.md) | **第一次上實機**：該用什麼順序做、每一步之後要看什麼、每種失敗代表什麼 |
| [`docs/QUICKSTART_zh-TW.md`](docs/QUICKSTART_zh-TW.md) | 幾分鐘內建立第一個儲存 |
| [`docs/CONFIGURATION_zh-TW.md`](docs/CONFIGURATION_zh-TW.md) | 所有 `storage.cfg` 參數 |
| [`docs/ARCHITECTURE_zh-TW.md`](docs/ARCHITECTURE_zh-TW.md) | 多系列架構與擴充方式 |
| [`docs/NAMING_CONVENTIONS_zh-TW.md`](docs/NAMING_CONVENTIONS_zh-TW.md) | PVE 物件與儲存伺服器物件的命名對照 |
| [`docs/TROUBLESHOOTING_zh-TW.md`](docs/TROUBLESHOOTING_zh-TW.md) | 症狀、成因與復原方式 |
| [`docs/TESTING_zh-TW.md`](docs/TESTING_zh-TW.md) | 測試矩陣與實機驗證狀態 |
| [`docs/RELEASE_TESTING_zh-TW.md`](docs/RELEASE_TESTING_zh-TW.md) | 每次發布前要做完的測試 |
| [`docs/POWERFLEX_SDC_zh-TW.md`](docs/POWERFLEX_SDC_zh-TW.md) | PowerFlex 主機端存取：SDC 與 NVMe/TCP，以及 Dell 支援矩陣 |

---

## 相關專案

- [jt-pve-storage-purestorage](https://github.com/jasoncheng7115/jt-pve-storage-purestorage)
- [jt-pve-storage-netapp](https://github.com/jasoncheng7115/jt-pve-storage-netapp)

## 授權

MIT，詳見 [LICENSE](LICENSE)。

## 作者

Jason Cheng（節省工具箱有限公司 / Jason Tools）&lt;jason@jason.tools&gt;
