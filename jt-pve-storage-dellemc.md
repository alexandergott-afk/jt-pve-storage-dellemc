# jt-pve-storage-dellemc 開發規格與實作計畫

> **文件版本**：1.0
> **日期**：2026-07-26
> **作者**：Jason Cheng（節省工具箱有限公司 / Jason Tools）
> **授權**：MIT
> **目標讀者**：Claude Code（實作代理人）

---

## 0. 給 Claude Code 的前置指示

**在動工前必須先做的事：**

1. 完整閱讀本文件，特別是第 2 章（架構決策）與第 15 章（明確不要做的事）。
2. 把下列兩個既有專案 clone 到工作目錄旁邊當**參考實作**，本專案的程式碼風格、錯誤處理、taint 處理、多路徑安全機制全部沿用它們：
   ```bash
   git clone https://github.com/jasoncheng7115/jt-pve-storage-purestorage.git ref/purestorage
   git clone https://github.com/jasoncheng7115/jt-pve-storage-netapp.git      ref/netapp
   ```
3. 特別精讀這幾個檔案，它們是本專案要抽象化的來源：
   - `ref/purestorage/lib/PVE/Storage/Custom/PureStoragePlugin.pm`（3541 行，主 plugin）
   - `ref/purestorage/lib/PVE/Storage/Custom/PureStorage/Multipath.pm`（1005 行，最高重用價值）
   - `ref/purestorage/lib/PVE/Storage/Custom/PureStorage/ISCSI.pm`（646 行）
   - `ref/purestorage/lib/PVE/Storage/Custom/PureStorage/FC.pm`（403 行）
   - `ref/netapp/lib/PVE/Storage/Custom/NetAppONTAP/Multipath.pm`（1414 行，orphan reaper 較完整）
   - `ref/purestorage/debian/postinst`（405 行，multipath 危險設定檢查）

4. **不要一次寫完整個專案。** 依第 13 章的 Phase 順序逐步實作，每完成一個模組就跑 `make test`（`perl -c`）並 commit。

5. 本專案所有**使用者可見文字**（README、CHANGELOG、docs/、錯誤訊息）都要有 **English + 繁體中文（台灣）** 雙語版本，檔名慣例沿用既有專案：`README.md` / `README_zh-TW.md`。中文版一律使用**全形標點符號**。

---

## 1. 專案定位與範圍

### 1.1 專案名稱

| 項目 | 值 |
|---|---|
| Repository | `jt-pve-storage-dellemc` |
| Debian 套件名 | `jt-pve-storage-dellemc` |
| 專案首頁 | `https://jasoncheng7115.github.io/jt-pve-storage-dellemc/` |

### 1.2 範圍界定

本專案為 Dell EMC 儲存陣列提供 Proxmox VE 自訂 storage plugin。Dell EMC 產品線差異極大，**不是一支 plugin 打天下**，而是**一個 repo、一組共用底層、多個獨立 plugin type**。

| 系列 | PVE plugin type | 資料路徑 | 本專案階段 |
|---|---|---|---|
| **PowerStore** | `dellpowerstore` | iSCSI / FC（dm-multipath） | **Phase 1〜4，本文件主體** |
| PowerVault ME5 | `dellme5` | iSCSI / FC / SAS（dm-multipath） | Phase 6，開發中 |
| PowerFlex | `dellpowerflex` | SDC kernel module（`/dev/scini*`） | Phase 7，另立子規格 |
| PowerMax | `dellpowermax` | FC / iSCSI（dm-multipath） | Phase 8，另立子規格 |
| PowerScale | `dellpowerscale` | NFS（目錄語意） | 不排入（PVE 內建 NFS 已涵蓋） |
| Unity XT | `dellunity` | iSCSI / FC | 不排入，除非客戶付費 |
| ObjectScale / PowerProtect | — | — | **不做**（不適合 PVE storage plugin 模型） |

**Phase 1〜5 只做 PowerStore。** 但目錄結構、base class、共用模組從第一天就要按多系列設計，不能寫死成 PowerStore-only。

---

## 2. 架構決策紀錄（ADR）

### ADR-001：拆成多個 plugin type，不做單一 plugin + `--dell-type` 參數

**決策**：每個產品系列一個獨立的 PVE storage type。

**理由**：

1. **`plugindata()` 是 class method，無法 per-instance。** PVE 在解析 storage.cfg 參數之前就會呼叫它決定 content types 與 format。PowerStore（block，只能 `raw`，content 只有 `images,rootdir`）與 PowerScale（NAS，可 `qcow2`/`subvol`，content 可含 `iso,vztmpl,backup,snippets`）無法共用同一個回傳值。這一條就是決定性的。
2. **`properties()` / `options()` 無法表達條件必填。** PVE JSONSchema 只有 `optional => 1`，沒有「當 family=powerflex 時 X 必填」。單一 type 會被迫宣告所有系列參數的聯集，使用者填錯組合 PVE 完全不擋，錯誤延到 runtime 才爆。
3. **業界前例一致。** Dell CSM 是五個獨立 CSI driver（csi-powerstore / csi-powermax / csi-powerflex / csi-isilon / csi-unity）；OpenStack Cinder 的 `dell_emc` 底下也是各系列獨立 driver。沒有人做成一支加 type 參數。
4. **type 字串一旦發佈就是契約**，改了會讓既有 storage.cfg 失效。現在就用 `dellpowerstore` 而非 `dellemc`，把擴充空間留出來。

### ADR-002：共用 base class 與 Common 模組

**決策**：block 類系列共用 `DellEMC::Common::BlockBase`，各系列 plugin 繼承之並實作抽象方法。

**理由**：PowerStore / PowerMax / Unity / ME5 的 host 端行為幾乎相同（iSCSI/FC 登入、SCSI rescan、dm-multipath 聚合、WWID 追蹤、orphan 清理），差異只在陣列端 API。把相同的部分抽到 base，各系列 plugin 只剩 200〜400 行。

**額外好處（重要）**：PVE 的 storage property 註冊在共用 schema，**不同 plugin 用同名但定義不同的 property 會衝突**。共通參數（`dell-portal`、`dell-username` 等）只在 base 定義一次，各子類 `options()` 引用，自然避開衝突。

### ADR-003：不做執行期自動偵測 plugin type

**決策**：plugin type 由使用者在 `pvesm add` 時明確指定，**絕不**靠 REST 探測決定。

**理由**：

- `storage.cfg` 會被 pvestatd、pvedaemon、pveproxy、qm、pct 反覆解析，且經常在陣列不通或無網路時解析。若 type 決定於一次 REST 呼叫，陣列離線會導致整個節點的 storage 清單解析失敗。
- `pvesm add` 的參數驗證發生在任何網路存取之前，根本沒有偵測時機。
- 會破壞既有專案 `pure-status-timeout` 所建立的「快速失敗、不拖累其他 storage」設計原則。

**允許且必須做的自動偵測**（發生在 `activate_storage` 之後，且失敗要能降級）：

- PowerStore 韌體版本 → REST API 版本（3.x / 4.x）的欄位差異
- NVMe-TCP 是否可用
- 授權與功能可用性（thin clone、metro volume）
- 陣列型號（PowerStore T / X / 500T / 1200T / 3200T…）

### ADR-004：出單一 .deb，不拆 binary package

**決策**：一個 `jt-pve-storage-dellemc` 套件安裝所有 plugin type。

**理由**：既有專案文件已明載，plugin 沒裝在**所有**叢集節點會出現 `Parameter verification failed (400) / No such storage`。拆包會製造「某節點只裝了 powerstore 沒裝 powerflex」的新故障模式。系列專屬的相依（`nfs-common`、PowerFlex SDC）放 `Recommends`，postinst 只檢查並警告，不 hard depend。

### ADR-005：Direct Volume Provisioning（1 VM disk = 1 陣列 Volume）

**決策**：沿用 Pure / NetApp plugin 的模型，不做 LVM-over-iSCSI 的大 LUN 切分。

**理由**：PowerStore 的 snapshot（redirect-on-write）與 thin clone 都作用在 volume 層級，1:1 對應才能讓陣列的資料服務（壓縮、去重、snapshot rule、replication session、Metro Volume）以「一個 VM 磁碟」為自然單位運作。

### ADR-006：參數命名規範

| 類別 | 前綴 | 定義位置 | 範例 |
|---|---|---|---|
| 跨系列共通 | `dell-` | `Common::BlockBase::properties()` | `dell-portal`、`dell-username`、`dell-password`、`dell-ssl-verify`、`dell-protocol`、`dell-cluster-name`、`dell-host-mode`、`dell-device-timeout`、`dell-status-timeout`、`dell-activate-deadline`、`dell-portal-probe-timeout` |
| PowerStore 專屬 | `pstore-` | `DellPowerStorePlugin::properties()` | `pstore-appliance`、`pstore-volume-group`、`pstore-performance-policy`、`pstore-protection-policy` |
| PowerMax 專屬 | `pmax-` | 各自 plugin | `pmax-srp`、`pmax-array-id`、`pmax-service-level` |
| PowerFlex 專屬 | `pflex-` | 各自 plugin | `pflex-protection-domain`、`pflex-storage-pool` |
| PowerScale 專屬 | `pscale-` | 各自 plugin | `pscale-access-zone`、`pscale-base-path` |

---

## 3. 目錄結構

```
jt-pve-storage-dellemc/
├── .github/workflows/build-deb.yml
├── Makefile
├── LICENSE                              # MIT
├── README.md
├── README_zh-TW.md
├── CHANGELOG.md
├── CHANGELOG_zh-TW.md
├── bin/
│   └── pve-dell-config-get              # 災難復原工具（比照 pve-pure-config-get）
├── debian/
│   ├── changelog  compat  control  copyright  docs  install  rules
│   ├── postinst                         # multipath 危險設定檢查 + 服務重啟
│   ├── prerm  postrm
├── docs/
│   ├── QUICKSTART.md            / QUICKSTART_zh-TW.md
│   ├── CONFIGURATION.md         / CONFIGURATION_zh-TW.md
│   ├── TROUBLESHOOTING.md       / TROUBLESHOOTING_zh-TW.md
│   ├── NAMING_CONVENTIONS.md    / NAMING_CONVENTIONS_zh-TW.md
│   ├── TESTING.md               / TESTING_zh-TW.md
│   ├── ARCHITECTURE.md          / ARCHITECTURE_zh-TW.md    # 新增：多系列架構說明
│   ├── index.html  style.css                                # GitHub Pages
├── lib/PVE/Storage/Custom/
│   ├── DellPowerStorePlugin.pm          # type: dellpowerstore
│   ├── DellPowerMaxPlugin.pm            # Phase 6
│   ├── DellPowerFlexPlugin.pm           # Phase 7
│   ├── DellPowerScalePlugin.pm          # Phase 8
│   └── DellEMC/
│       ├── Common/
│       │   ├── REST.pm                  # HTTP client 抽象基底
│       │   ├── ISCSI.pm                 # iSCSI initiator 管理
│       │   ├── FC.pm                    # FC HBA / WWPN
│       │   ├── Multipath.pm             # dm-multipath、SCSI device lifecycle
│       │   ├── Naming.pm                # PVE ↔ 陣列物件命名
│       │   ├── WwidState.pm             # WWID 追蹤與 orphan reaper（從 plugin 抽出）
│       │   ├── Health.pm                # status 失敗計數、容量告警冷卻
│       │   └── BlockBase.pm             # 抽象 plugin 基底（繼承 PVE::Storage::Plugin）
│       ├── PowerStore/
│       │   ├── API.pm
│       │   └── Naming.pm                # 覆寫 PowerStore 專屬命名限制
│       ├── PowerMax/API.pm              # Phase 6
│       ├── PowerFlex/API.pm             # Phase 7
│       └── PowerScale/API.pm            # Phase 8
└── t/                                   # 新增：單元測試
    ├── 01-naming.t
    ├── 02-rest-mock.t
    └── fixtures/powerstore/*.json
```

**與既有專案的差異**：新增 `Common/WwidState.pm`、`Common/Health.pm`、`t/`。Pure plugin 把 WWID 追蹤與健康狀態直接寫在 3541 行的 plugin 主檔裡，本專案要抽出來，因為它們是跨系列共用的。

---

## 4. 版本與相容性

```perl
use constant APIVERSION     => 13;
use constant MIN_APIVERSION => 9;
```

| 項目 | 需求 |
|---|---|
| Proxmox VE | 9.1 以上（Storage API 13）；需在 PVE 9.2 上驗證 |
| PowerStore OS | 3.0 以上（REST API v3）；以 4.x 為主要開發目標 |
| Perl 相依 | `libwww-perl`、`libjson-perl`、`liburi-perl` |
| 系統工具 | `open-iscsi`、`multipath-tools`、`sg3-utils`、`psmisc`；建議 `lsscsi` |

必須實作 `get_identity()`（PVE 9.2 起 base class 預設會 `die()`）：

```perl
sub get_identity {
    my ($class, $scfg, $storeid) = @_;
    my $portal    = $scfg->{'dell-portal'}       // '';
    my $appliance = $scfg->{'pstore-appliance'}  // '';
    return "dellpowerstore:${portal}:${appliance}";
}
```

---

## 5. 模組規格

### 5.1 `DellEMC::Common::REST`

抽象 HTTP client 基底，各系列 API 模組繼承之。

```perl
sub new                 # (%args: portal, username, password, ssl_verify, timeout, retries, logger)
sub _init_ua            # LWP::UserAgent，含 SSL 選項與 timeout
sub _auth_headers       # 抽象：子類實作
sub _login              # 抽象：子類實作
sub _request            # 核心：重試、429/503 退避、逾時、錯誤轉譯、session 過期重登
sub get / post / patch / put / delete
sub translate_error     # 抽象：把廠商錯誤碼轉成人看得懂的訊息
sub set_timeout         # 供 health path 切換成短逾時單次嘗試
```

**必須實作的行為**（照抄 Pure `API.pm` 的設計）：

- 雙客戶端模式：**resilient client**（資料路徑，有重試）與 **health client**（`activate_storage` + `status` 前景，單次嘗試、短逾時）。`dell-status-timeout` 控制後者。
- Session 快取（含 TTL），401 時自動重登一次再重試。
- 所有錯誤訊息前綴 `[dellpowerstore:<storeid>]` 便於 journal 過濾。

### 5.2 `DellEMC::PowerStore::API`

繼承 `Common::REST`。

**認證**：`GET /api/rest/login_session`，HTTP Basic Auth，回應 header 帶 `DELL-EMC-TOKEN` 與 session cookie。後續寫入類請求（POST/PATCH/DELETE）需帶 `DELL-EMC-TOKEN` header 與 cookie。

> **實作前務必用目標陣列的 Swagger UI（`https://<mgmt-ip>/swaggerui`）逐一核對下表。** 下表以 PowerStore 4.x 為基準整理，欄位名稱在 3.x 與 4.x 之間有差異。若無實機，先依 `docs/` 下的 fixture 開發，並在 `docs/TESTING.md` 標記「未於實機驗證」。

| 函式 | HTTP | 端點 | 備註 |
|---|---|---|---|
| `cluster_get` | GET | `/api/rest/cluster` | 取 cluster name、state |
| `appliance_list` | GET | `/api/rest/appliance` | 多 appliance 時的放置決策 |
| `get_managed_capacity` | GET | `/api/rest/space_metrics_by_cluster` 或 `/api/rest/metrics/generate` | 需驗證哪個在 4.x 可用；fallback 用 appliance 加總 |
| `volume_create` | POST | `/api/rest/volume` | body：`name`、`size`（bytes，需 8KiB 對齊）、`appliance_id`、`volume_group_id`、`performance_policy_id`、`protection_policy_id` |
| `volume_list` | GET | `/api/rest/volume?select=...&name=ilike.<prefix>%25` | **必須用伺服器端 filter**，不可全撈後本地過濾 |
| `volume_get` | GET | `/api/rest/volume/{id}` | |
| `volume_get_by_name` | GET | `/api/rest/volume?name=eq.<name>` | |
| `volume_delete` | DELETE | `/api/rest/volume/{id}` | |
| `volume_resize` | PATCH | `/api/rest/volume/{id}` | body：`size`；**只准放大** |
| `volume_rename` | PATCH | `/api/rest/volume/{id}` | body：`name` |
| `volume_get_wwn` | — | 由 `volume_get` 取 `wwn` 欄位 | 格式 `naa.68ccf098...` |
| `snapshot_create` | POST | `/api/rest/volume/{id}/snapshot` | body：`name`、`description` |
| `snapshot_list` | GET | `/api/rest/volume?type=eq.Snapshot&protection_data->>source_id=eq.<id>` | 需驗證 filter 語法 |
| `snapshot_delete` | DELETE | `/api/rest/volume/{snap_id}` | snapshot 也是 volume 物件 |
| `volume_restore` | POST | `/api/rest/volume/{id}/restore` | body：`from_snap_id`、`create_backup_snap` |
| `volume_clone` | POST | `/api/rest/volume/{id}/clone` | thin clone；用於 linked clone |
| `host_create` | POST | `/api/rest/host` | body：`name`、`os_type: "Linux"`、`initiators[]` |
| `host_list` / `host_get` | GET | `/api/rest/host` | |
| `host_modify` | PATCH | `/api/rest/host/{id}` | `add_initiators` / `remove_initiators` |
| `host_delete` | DELETE | `/api/rest/host/{id}` | |
| `host_group_*` | — | `/api/rest/host_group` | `shared` host mode 用 |
| `volume_attach` | POST | `/api/rest/volume/{id}/attach` | body：`host_id` 或 `host_group_id`、可選 `logical_unit_number` |
| `volume_detach` | POST | `/api/rest/volume/{id}/detach` | |
| `mapping_list` | GET | `/api/rest/host_volume_mapping` | 查詢既有映射，避免重複 attach |
| `iscsi_portals` | GET | `/api/rest/ip_pool_address?purposes=cs.{Storage_Iscsi_Target}` | 需驗證；取 iSCSI target IP |
| `iscsi_targets` | GET | `/api/rest/ip_port` | 取 target IQN |
| `fc_ports` | GET | `/api/rest/fc_port` | 取 target WWPN |
| `job_get` | GET | `/api/rest/job/{id}` | 非同步作業輪詢（HTTP 202 時） |

**WWN → multipath WWID 換算**：

```perl
# PowerStore volume.wwn = "naa.68ccf09800a1b2c3d4e5f60718293a4b"
# Linux /lib/udev/scsi_id -g -u 回傳 "368ccf09800a1b2c3d4e5f60718293a4b"
sub wwn_to_wwid {
    my ($wwn) = @_;
    $wwn =~ s/^naa\.//i;
    return '3' . lc($wwn);
}
```

**這一段務必在實機上用 `/lib/udev/scsi_id -g -u /dev/sdX` 實測驗證後才能定案。**

**LUN ID 陷阱（已知 Dell 缺陷，必須處理）**：PowerStore 對 UI 與 REST/PSTCLI 分別維護自動 LUN ID 序列，REST 自動配發從 200 起遞增，反覆 attach/detach 會讓 LUN ID 持續攀升，直到超過 host OS 的掃描上限而導致新磁碟掃不到。

> 對策：`volume_attach` **明確帶入 `logical_unit_number`**，由 plugin 自行管理配發（查 `host_volume_mapping` 找該 host 最小可用 ID，範圍 1〜255）。這一點與 Pure / NetApp 的作法不同，是 PowerStore 專屬的必要處理，要寫進 `docs/TROUBLESHOOTING.md`。

### 5.3 `DellEMC::Common::BlockBase`

繼承 `PVE::Storage::Plugin`。實作所有與陣列無關的邏輯，並定義子類必須覆寫的抽象方法。

**BlockBase 已實作（子類不需重寫）**：

```
api  plugindata  options（共通部分）
activate_storage      # SAN 登入、multipath conf 確保、健康檢查、activate deadline
deactivate_storage
status                # 前景健康檢查 + 背景 orphan reaper（backgrounded grandchild）
activate_volume       # attach → rescan → 等待 multipath device → 回傳路徑
deactivate_volume
path  filesystem_path
volume_size_info
volume_has_feature
parse_volname  _parse_volname  find_free_diskname  _find_free_diskid
_udev_refresh  _get_initiators  _get_host_name
_ensure_multipath_config     # 含版本標記機制
_cleanup_orphaned_devices    # WWID 追蹤 + grace period + miss threshold
```

**子類必須實作的抽象方法**：

```perl
sub _api                 # 回傳該系列的 API client（含快取）
sub _vendor_id           # 'DellEMC'
sub _product_family      # 'PowerStore'
sub _multipath_vendor    # ('DellEMC', 'PowerStore')，供產生 multipath device 區段
sub _multipath_defaults  # 該系列建議的 multipath 參數 hashref
sub _array_create_volume     # ($storeid,$scfg,$name,$size_bytes) -> $volume_id
sub _array_delete_volume
sub _array_resize_volume
sub _array_rename_volume
sub _array_list_volumes      # 依 prefix filter，回傳 arrayref
sub _array_get_wwid          # ($volume_id) -> multipath WWID
sub _array_snapshot_create / _delete / _list / _rollback
sub _array_clone
sub _array_map_to_host / _unmap_from_host / _is_mapped
sub _array_ensure_host       # 建立/更新 host 物件與 initiator
sub _array_get_portals       # iSCSI portal 清單
sub _array_get_capacity      # (total, used) bytes
```

### 5.4 `DellEMC::Common::Multipath`

**直接以 `ref/netapp/.../Multipath.pm` 為藍本移植**（1414 行版本較完整），把 vendor 字串參數化。

必須保留的函式與安全語意：

```
sysfs_write_with_timeout / sysfs_read_with_timeout   # 防 D state 卡死
rescan_scsi_hosts  rescan_scsi_device  remove_scsi_device
multipath_reload  multipath_resize_map  multipath_flush
get_multipath_device  get_device_by_wwid  wait_for_multipath_device
get_multipath_slaves  cleanup_lun_devices
list_vendor_multipath_devices    # 原 list_pure_multipath_devices，參數化
get_device_usage_details  is_device_in_use
_untaint_device_name / _untaint_device_path / _untaint_path
```

**絕對禁止**：任何程式碼路徑都不得產生 `multipath -F`（大寫 F）。只能用 `multipath -f /dev/mapper/<wwid>`。這條要在 code review checklist 與 CI grep 中把關。

### 5.5 `DellEMC::Common::WwidState`

從 Pure plugin 主檔抽出的 WWID 追蹤機制。

```
狀態檔：/var/lib/pve-storage-dellemc/<storeid>-wwids.json
鎖檔：  /var/run/pve-storage-dellemc/<storeid>.lock
```


```perl
sub state_dir / lock_dir / state_file / lock_file / safe_storeid
sub with_lock            # flock 包裝
sub read_state / write_state
sub track_wwid / untrack_wwid / sibling_tracked_wwids
use constant ORPHAN_GRACE_SECONDS  => 600;
use constant ORPHAN_MISS_THRESHOLD => 3;
```

### 5.6 `DellEMC::Common::Health`

```perl
use constant STATUS_FAIL_THRESHOLD  => 3;
use constant OUTAGE_REEMIT_SECONDS  => 30;
use constant CAPACITY_WARN_PCT      => 90;
use constant CAPACITY_CRIT_PCT      => 95;
use constant CAPACITY_COOLDOWN_SEC  => 3600;
sub read_health_state / write_health_state / record_status_failure / record_status_ok
```

### 5.7 `DellEMC::Common::Naming` 與 `PowerStore::Naming`

PowerStore 名稱限制（**需以實機驗證**，暫定）：volume 名稱最長 128 字元，允許英數與 `_ - .`；snapshot 名稱同規則。

| PVE 物件 | PowerStore 物件 | 命名樣式 |
|---|---|---|
| VM 磁碟 | Volume | `pve-{storeid}-{vmid}-disk{n}` |
| Container rootfs | Volume | `pve-{storeid}-{vmid}-disk{n}` |
| Cloud-init | Volume | `pve-{storeid}-{vmid}-cloudinit` |
| EFI disk | Volume | `pve-{storeid}-{vmid}-efidisk{n}` |
| TPM state | Volume | `pve-{storeid}-{vmid}-tpmstate{n}` |
| RAM state（vmstate） | Volume | `pve-{storeid}-{vmid}-state-{snapname}` |
| VM config 備份 | Volume（1 MB, ext4） | `pve-{storeid}-{vmid}-vmconf-{snapname}` |
| Snapshot | Volume Snapshot | `{volume}.pve-snap-{snapname}` |
| Template 標記 | Volume Snapshot | `{volume}.pve-base` |
| PVE 節點 | Host | `pve-{cluster}-{node}` |
| 共享 host | Host Group | `pve-{cluster}-shared` |

**Prefix 隔離原則**：plugin **只讀寫**名稱以 `pve-{storeid}-` 開頭的物件。陣列上其他物件永不觸碰。這是最基本的安全邊界，所有 list / delete / cleanup 路徑都必須先過 `is_pve_managed_volume()`。

---

## 6. storage.cfg 參數規格

### 6.1 共通參數（`Common::BlockBase::properties()`）

| 參數 | 型別 | 必填 | 預設 | 說明 |
|---|---|---|---|---|
| `dell-portal` | string | 是（fixed） | — | 陣列管理 IP 或 FQDN |
| `dell-username` | string | 是 | — | REST API 帳號 |
| `dell-password` | string | 是 | — | REST API 密碼 |
| `dell-ssl-verify` | boolean | 否 | `0` | 驗證 SSL 憑證 |
| `dell-protocol` | enum | 否 | `iscsi` | `iscsi` \| `fc` |
| `dell-host-mode` | enum | 否 | `per-node` | `per-node` \| `shared` |
| `dell-cluster-name` | string | 否 | `pve` | host 命名用叢集名 |
| `dell-device-timeout` | int 10..300 | 否 | `60` | 裝置出現等待逾時 |
| `dell-portal-probe-timeout` | int 0..30 | 否 | `2` | iSCSI portal TCP 預檢逾時，0 = 停用 |
| `dell-status-timeout` | int 2..60 | 否 | `5` | pvestatd 健康路徑 REST 逾時（單次嘗試） |
| `dell-activate-deadline` | int 0..300 | 否 | `30` | `activate_storage` 中 portal 登入迴圈的累計預算 |
| `dell-config-backup-timeout` | int 5..60 | 否 | `15` | config 備份卷裝置等待逾時 |

### 6.2 PowerStore 專屬參數

| 參數 | 型別 | 必填 | 預設 | 說明 |
|---|---|---|---|---|
| `pstore-appliance` | string | 否 | — | 指定 appliance（多 appliance cluster）。留空由 PowerStore 自動放置 |
| `pstore-volume-group` | string | 否 | — | 將所有 volume 放入指定 volume group，做為命名空間與一致性群組 |
| `pstore-performance-policy` | enum | 否 | `Medium` | `High` \| `Medium` \| `Low` |
| `pstore-protection-policy` | string | 否 | — | 套用 protection policy（snapshot rule / replication rule） |
| `pstore-lun-id-base` | int 1..200 | 否 | `1` | 自管 LUN ID 的起始值（見 5.2 LUN ID 陷阱） |

### 6.3 標準 PVE 參數

`nodes`、`disable`、`content`、`shared` 全部 `{ optional => 1 }`。

### 6.4 範例

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

---

## 7. PVE Storage API 方法對照

| PVE 方法 | PowerStore 動作 | 備註 |
|---|---|---|
| `alloc_image` | `volume_create` → `volume_attach`（全節點）→ 等待裝置 | 失敗要 rollback 已建立的 volume |
| `free_image` | in-use 檢查 → `cleanup_lun_devices` → `volume_detach` → `volume_delete` | 有 clone 子代時要擋並給明確訊息 |
| `list_images` | `volume_list`（伺服器端 prefix filter） | 過濾 snapshot type 與 config 卷 |
| `volume_size_info` | `volume_get` | |
| `volume_resize` | `volume_resize` → SCSI rescan → `multipath_resize_map` | **只准放大**，縮小要 die 並說明會資料遺失 |
| `activate_volume` | 確保已 attach → rescan → `wait_for_multipath_device` | |
| `deactivate_volume` | 通常 no-op（保持全節點映射以支援 live migration） | |
| `path` | `/dev/mapper/<wwid>` | 裝置未出現時回傳合成路徑，不要 die |
| `volume_snapshot` | `snapshot_create` + VM config 備份卷 | |
| `volume_snapshot_delete` | `snapshot_delete` + 刪對應 config 卷 | |
| `volume_snapshot_rollback` | `volume_restore` | VM 必須停機 |
| `volume_snapshot_list` | 列出 `{volume}.pve-snap-*` | |
| `clone_image` | `volume_clone`（thin clone） | linked clone |
| `create_base` | 建立 `{volume}.pve-base` snapshot | template 轉換 |
| `rename_volume` | `volume_rename` | |
| `volume_has_feature` | 回報 snapshot / clone / template / copy / sparseinit | 對照 Pure plugin 的實作 |
| `get_identity` | `dellpowerstore:{portal}:{appliance}` | PVE 9.2 必須 |

**已知 PVE 限制**（要寫進 README「Known Limitations」）：Full Clone 由 PVE 走 `alloc_image` + `qemu-img` 逐塊複製，不會呼叫 plugin 的 `clone_image`。這是 PVE 架構決策，非 plugin 缺陷。建議使用者用 Linked Clone。

---

## 8. Multipath 安全規範

`_ensure_multipath_config()` 寫入 `/etc/multipath/conf.d/dellemc-powerstore.conf`，內含版本標記：

```
# dellemc-multipath-config-version: 1
devices {
    device {
        vendor               "DellEMC"
        product              "PowerStore"
        path_selector        "queue-length 0"
        path_grouping_policy group_by_prio
        prio                 alua
        hardware_handler     "1 alua"
        failback             immediate
        no_path_retry        30
        fast_io_fail_tmo     5
        dev_loss_tmo         60
        detect_prio          yes
        rr_min_io_rq         1
        max_sectors_kb       1024
    }
}
```

> `vendor` / `product` 字串**必須用實機的 `sg_inq /dev/sdX` 或 `multipathd show config` 確認**後才能定案。Dell 官方 Linux Host Connectivity Guide 建議值也要對照。

**版本標記語意**（沿用 Pure plugin）：

- 檔案不存在 → plugin 建立
- 檔案存在且標記版本較舊 → plugin 自動升級改寫
- 檔案存在但**無標記**（使用者手改或第三方建立）→ **完全不動**，postinst 印警告要求人工比對

**postinst 必須檢查並警告的危險設定**：

| 設定 | 風險 | 建議 |
|---|---|---|
| `no_path_retry queue` | I/O 永久排隊，節點卡死 | 改 `30` |
| `queue_if_no_path`（在 features） | 同上 | 從 features 移除 |
| `dev_loss_tmo infinity` | 失效裝置永不移除 | 改 `60` |

README 開頭必須有與既有兩專案同等級的「CRITICAL: Multipath Safety Rules」區塊。

---

## 9. 錯誤訊息規範

所有 die 訊息必須是「可行動的」，格式沿用 NetApp plugin：

```
Cannot shrink volume: current size 32.00GB, requested 16.00GB. Shrinking would cause data loss.

Cannot delete volume 'vm-100-disk-0': device /dev/mapper/36xxx is still in use
(mounted, has holders, or open by process). Please stop the VM and unmount first.

Volume 'pve-ps1-100-disk0' already exists on PowerStore. This may indicate a
naming conflict or an orphaned volume from a previous failed operation.

Cannot delete volume 'vm-100-disk-0': it has thin clone children depending on it.
Dependent volumes: pve-ps1-101-disk0, pve-ps1-102-disk0.
Please delete the clones first.

PowerStore API error 401: authentication failed. Verify dell-username /
dell-password, and that the account is not locked out.

No iSCSI target portals returned by PowerStore. Verify that iSCSI is configured
on the appliance and that at least one Storage_Iscsi_Target IP pool address exists.
```

---

## 10. 打包

### `debian/control`

```
Source: jt-pve-storage-dellemc
Section: admin
Priority: optional
Maintainer: Jason Cheng (Jason Tools) <jason@jason.tools>
Build-Depends: debhelper (>= 12)
Standards-Version: 4.5.0
Homepage: https://github.com/jasoncheng7115/jt-pve-storage-dellemc

Package: jt-pve-storage-dellemc
Architecture: all
Depends: ${misc:Depends},
         proxmox-ve (>= 9.1) | pve-manager (>= 9.1),
         libwww-perl, libjson-perl, liburi-perl,
         open-iscsi, multipath-tools, sg3-utils, psmisc
Recommends: lsscsi, nfs-common
Description: Dell EMC Storage Plugins for Proxmox VE
 ...
```

### postinst 必做

1. 檢查必要 binary（`iscsiadm`、`multipath`、`sg_inq`、`fuser`）存在，缺少則 `exit 1` 並明確說明用 `apt install ./xxx.deb` 而非 `dpkg -i`。
2. 掃描 `/etc/multipath.conf` 危險設定並印警告。
3. 檢查是否有殘留的 Dell 裝置。
4. `systemctl restart pvedaemon pveproxy`。
5. 提醒「叢集內所有節點都必須安裝」。

---

## 11. 無實機時的開發策略

若手上沒有 PowerStore 測試機，Phase 1〜3 仍可進行：

1. 從 `https://developer.dell.com` 取得 PowerStore OpenAPI/Swagger 規格，存到 `t/fixtures/powerstore/openapi.json`。
2. 用 `Plack` 或簡單的 Python `http.server` 起一個 mock REST server，依 fixture 回應。
3. `t/02-rest-mock.t` 針對 mock server 測 API.pm 的所有函式。
4. 所有**未在實機驗證**的行為，在 `docs/TESTING.md` 明確標記 `NOT VERIFIED ON HARDWARE`，README 的 Disclaimer 也要寫清楚（比照 NetApp plugin 對 FC 的處理方式）。
5. 主機端（multipath、iSCSI、SCSI）的邏輯可以用任何 iSCSI target（例如 LIO / TrueNAS）先驗證，與陣列 API 無關。

**取得測試環境的建議**：既有兩個專案分別由 MetaAge（邁達特）與 NetApp 原廠提供測試設備。PowerStore 可循同樣模式，向 Dell 台灣或代理商（如精誠、聯強）洽詢 POC 設備或遠端 Demo Center 存取。

---

## 12. 測試計畫

`docs/TESTING.md` 需涵蓋以下項目（比照 NetApp plugin 的 22 項全測套件）：

| # | 測試項 | 前置 | 判定 |
|---|---|---|---|
| 1 | 套件安裝（apt install ./deb） | 乾淨節點 | 相依自動解析、postinst 無錯 |
| 2 | 叢集全節點安裝 | 3 節點 | 各節點 `pvesm status` 一致 |
| 3 | `pvesm add` 參數驗證 | — | 缺必填參數要被擋 |
| 4 | `pvesm status` 容量正確 | — | 與 PowerStore Manager 顯示一致（±1%） |
| 5 | 陣列離線時 status 行為 | 拔管理網路 | `inactive`，其他 storage 不受影響，5 秒內返回 |
| 6 | 建立 VM 磁碟 | — | 陣列出現 volume、host 端出現 multipath 裝置 |
| 7 | 磁碟線上擴充 | VM running | 客體看得到新容量 |
| 8 | 磁碟縮小 | — | 被擋並顯示明確訊息 |
| 9 | 刪除磁碟 | VM stopped | volume 消失、SCSI 裝置清乾淨、無殘留 multipath map |
| 10 | 刪除使用中磁碟 | VM running | 被擋 |
| 11 | Snapshot 建立/列出/刪除 | — | 陣列 snapshot 對應正確 |
| 12 | Snapshot rollback | VM stopped | 資料還原正確 |
| 13 | RAM snapshot（vmstate） | VM running | state 卷建立、還原後 VM 記憶體狀態正確 |
| 14 | VM config 備份與 `pve-dell-config-get` | — | 能取回 conf |
| 15 | Template + Linked Clone | — | thin clone 瞬間完成 |
| 16 | 刪除有 clone 子代的 template | — | 被擋並列出相依 volume |
| 17 | Full Clone | — | 可完成（走 qemu-img） |
| 18 | LXC container rootdir | — | 可建立、啟動 |
| 19 | EFI disk / TPM state / cloud-init | — | 各自建立成功 |
| 20 | Live migration | 2 節點 | 線上遷移成功、無 I/O 中斷 |
| 21 | 單一路徑故障 | 拔一條 iSCSI 網路 | I/O 不中斷、multipath 顯示 failed path |
| 22 | 節點重開機後恢復 | — | 開機後自動登入、裝置自動出現 |
| 23 | Orphan reaper | 手動製造殘留 WWID | grace period 後自動清除，不影響其他儲存 |
| 24 | LUN ID 遞增測試 | 反覆 attach/detach 300 次 | LUN ID 不會失控攀升（驗證 5.2 對策） |
| 25 | FC 協定全套重測 | FC fabric | 同上述各項 |
| 26 | PVE 9.1 → 9.2 升級 | — | plugin 仍正常，`get_identity` 無錯誤 |

---

## 13. 待辦清單

### Phase 0：專案骨架（0.1.0）

- [ ] 建立 repo `jt-pve-storage-dellemc`，MIT LICENSE
- [ ] 建立完整目錄結構（第 3 章）
- [ ] `Makefile`：`install` / `uninstall` / `test`（`perl -c` 全模組）/ `deb` / `clean`
- [ ] `debian/` 全套（control、rules、install、compat、changelog、copyright、docs）
- [ ] `.github/workflows/build-deb.yml`（比照 Pure 專案）
- [ ] `README.md` / `README_zh-TW.md` 骨架，含 Disclaimer 與 Multipath Safety Rules
- [ ] CI 加一條 grep 規則：任何 `.pm` / `.sh` 出現 `multipath -F` 即失敗

### Phase 1：Common 層（0.2.0）

- [ ] `Common/Naming.pm`：命名編解碼 + `is_pve_managed_volume`
- [ ] `t/01-naming.t`：命名往返測試（encode → decode 一致）
- [ ] `Common/REST.pm`：雙客戶端、重試、逾時、session 管理
- [ ] `Common/Multipath.pm`：從 NetApp 版移植並參數化 vendor
- [ ] `Common/ISCSI.pm`：從 Pure 版移植
- [ ] `Common/FC.pm`：從 Pure 版移植
- [ ] `Common/WwidState.pm`：從 Pure plugin 主檔抽出
- [ ] `Common/Health.pm`：從 Pure plugin 主檔抽出
- [ ] 每個模組完成後 `perl -c` 通過並單獨 commit

### Phase 2：BlockBase（0.3.0）

- [ ] `Common/BlockBase.pm`：實作 5.3 列出的共用方法
- [ ] 定義並文件化所有抽象方法（未實作時 `die "abstract method"`）
- [ ] `_ensure_multipath_config()` 含版本標記機制
- [ ] `_cleanup_orphaned_devices()` 背景執行（backgrounded grandchild，不阻塞 pvestatd）
- [ ] `docs/ARCHITECTURE.md` / `_zh-TW.md`：說明多系列架構與擴充方式

### Phase 3：PowerStore API（0.4.0）

- [ ] 取得 PowerStore OpenAPI 規格，存 `t/fixtures/powerstore/`
- [ ] `PowerStore/API.pm`：認證（`login_session` + `DELL-EMC-TOKEN`）
- [ ] volume CRUD + 伺服器端 filter 查詢
- [ ] snapshot / restore / clone
- [ ] host / host_group / initiator 管理
- [ ] attach / detach + **自管 LUN ID**（第 5.2 節陷阱）
- [ ] iSCSI portal / FC port 查詢
- [ ] 容量查詢（cluster + appliance fallback）
- [ ] `translate_error`：PowerStore 錯誤碼對照表
- [ ] mock server + `t/02-rest-mock.t`
- [ ] `PowerStore/Naming.pm`：名稱長度與字元限制

### Phase 4：PowerStore Plugin（0.5.0 → 1.0.0）

- [ ] `DellPowerStorePlugin.pm`：`type` / `plugindata` / `properties` / `options` / `get_identity`
- [ ] 實作全部抽象方法
- [ ] `activate_storage` / `deactivate_storage` / `status`
- [ ] `alloc_image` / `free_image` / `list_images`（含失敗 rollback）
- [ ] `volume_resize`（含 shrink 防護）
- [ ] `activate_volume` / `deactivate_volume` / `path`
- [ ] snapshot 全套 + VM config 備份卷
- [ ] `create_base` / `clone_image` / `rename_volume` / `volume_has_feature`
- [ ] `bin/pve-dell-config-get`（含 `-r` 災難復原模式）
- [ ] `debian/postinst` 全套檢查
- [ ] iSCSI 全套實機測試（第 12 章 1〜24 項）
- [ ] `docs/` 全部文件（雙語）
- [ ] `docs/index.html` + `style.css`（GitHub Pages）

### Phase 5：強化與發佈（1.0.x）

- [ ] FC 協定實機驗證（第 12 章第 25 項）
- [ ] PVE 9.2 相容性驗證
- [ ] 效能調校：`list_images` 大量 volume（>500）時的回應時間
- [ ] NVMe-TCP 支援評估（**注意：走 NVMe native ANA multipath，不是 dm-multipath，屬重大分歧，需獨立評估**）
- [ ] 發佈 1.0.0 + GitHub Release + .deb

### Phase 6 以後（另立子規格，本文件不展開）

> **順序更新（2026-07-26）**：改為 PowerStore → PowerVault ME5 → PowerFlex → PowerMax。PowerScale 因為是 NFS、且 PVE 內建 NFS 儲存已涵蓋，改為不排入。

- [ ] PowerVault ME5（`dellme5`）：SMC REST API、iSCSI／FC／SAS、**繼承 BlockBase** ← 開發中
- [ ] PowerFlex（`dellpowerflex`）：SDC kernel module、`/dev/scini*`、**不繼承 BlockBase**
- [ ] PowerMax（`dellpowermax`）：Unisphere for PowerMax REST、storage group／masking view 模型、**繼承 BlockBase**

---

## 14. 驗收條件（Definition of Done）

Phase 4 完成、可標記 1.0.0 的條件：

1. `make test` 全數通過（所有 `.pm` 與 `bin/` 的 `perl -c`）。
2. CI 的 `multipath -F` 檢查通過。
3. 在 3 節點 PVE 9.1 叢集 + 實體 PowerStore 上，第 12 章第 1〜24 項全部通過並記錄於 `docs/TESTING.md`。
4. 連續 72 小時 pvestatd 輪詢無 `inactive` 誤報、無 journal 錯誤堆積。
5. 陣列管理網路中斷 10 分鐘再恢復：storage 自動恢復 active，執行中 VM 全程無 I/O 中斷。
6. 反覆 attach/detach 300 次後 LUN ID 未失控。
7. README / docs 雙語齊備，中文版使用全形標點。
8. 未驗證項目（FC、NVMe-TCP）在 Disclaimer 中明確標示。

---

## 15. 明確不要做的事

1. **不要**做單一 plugin 加 `--dell-type` 參數（見 ADR-001）。
2. **不要**在 `storage.cfg` 解析階段做任何網路存取。
3. **不要**產生任何 `multipath -F`（大寫）的呼叫，文件範例中也不行。
4. **不要**用 `systemctl reload multipathd`，一律 `restart`。
5. **不要**在 `list_images` 全撈陣列 volume 再本地過濾，必須用伺服器端 filter。
6. **不要**觸碰名稱不以 `pve-{storeid}-` 開頭的陣列物件，任何路徑都不行。
7. **不要**在 `status` 的前景路徑做有重試的 REST 呼叫（會拖垮 pvestatd 整輪）。
8. **不要**支援 volume 縮小。
9. **不要**把 PowerFlex 或 PowerScale 硬塞進 `BlockBase`。
10. **不要**在沒有實機驗證的情況下，把 `vendor`/`product` 字串、WWN→WWID 換算、REST 端點當成已確認事實寫進文件；一律標記待驗證。
11. **不要**改寫使用者手動建立、無版本標記的 multipath 設定檔。
12. **不要**在 Phase 4 之前開任何其他系列的分支。

---

## 16. 開發工作流程建議

```bash
# 每個模組完成後
make test
git add -A && git commit -m "feat(common): add Multipath.pm ported from netapp plugin"

# 每個 Phase 完成後
make deb
# 在測試節點上
apt install ./jt-pve-storage-dellemc_0.x.y-1_all.deb
```

**commit message 慣例**：`<type>(<scope>): <subject>`
type：`feat` / `fix` / `docs` / `refactor` / `test` / `chore`
scope：`common` / `powerstore` / `packaging` / `docs`

**CHANGELOG**：每個 Phase 結束時同步更新 `CHANGELOG.md` 與 `CHANGELOG_zh-TW.md`，格式沿用既有專案。

---

## 附錄 A：既有專案模組行數對照（規模估算基準）

| 模組 | Pure | NetApp | Dell 預估 |
|---|---|---|---|
| 主 Plugin | 3541 | 3175 | BlockBase 2200 + PowerStorePlugin 900 |
| API | 2083 | 1200 | 1600 |
| Multipath | 1005 | 1414 | 1300（共用） |
| ISCSI | 646 | 546 | 650（共用） |
| FC | 403 | 356 | 420（共用） |
| Naming | 418 | 314 | Common 350 + PowerStore 120 |
| WwidState | （在主檔） | （在主檔） | 320 |
| Health | （在主檔） | （在主檔） | 200 |
| bin/ 工具 | 659 | — | 680 |
| **合計** | **~8755** | **~7005** | **~8740** |

Phase 1〜4 預估總工作量與既有兩專案相當。

## 附錄 B：參考連結

- Proxmox VE Storage Plugin Development — https://pve.proxmox.com/wiki/Storage_Plugin_Development
- Dell PowerStore REST API Developer's Guide — https://dl.dell.com/content/manual55475248-dell-emc-powerstore-rest-api-developers-guide.pdf
- Dell Developer Portal（PowerStore API） — https://developer.dell.com
- OpenStack Cinder PowerStore driver（參考實作） — https://docs.openstack.org/cinder/latest/configuration/block-storage/drivers/dell-emc-powerstore-driver.html
- Dell CSM csi-powerstore（參考實作） — https://github.com/dell/csi-powerstore
- 本團隊 Pure Storage plugin — https://github.com/jasoncheng7115/jt-pve-storage-purestorage
- 本團隊 NetApp ONTAP plugin — https://github.com/jasoncheng7115/jt-pve-storage-netapp

---

## 附錄 C：本機參考專案路徑

除第 0 章的 clone 方式外，兩個參考專案在本機已存在，可直接讀取：

- `/root/jt-pve-storage-netapp`
- `/root/jt-pve-storage-purestorage`
