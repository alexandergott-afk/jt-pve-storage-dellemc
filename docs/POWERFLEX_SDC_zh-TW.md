# PowerFlex 的主機端存取：SDC 與 NVMe/TCP

English: [POWERFLEX_SDC.md](POWERFLEX_SDC.md)

PowerFlex 的 volume 不是以 SCSI LUN 的形式出現。Proxmox VE 節點有兩種方式看到它們，而這個選擇的影響會比這個外掛活得更久。

| | SDC | NVMe/TCP |
|---|---|---|
| 主機端元件 | Dell 的 `scini` kernel module | kernel 內建的 `nvme_tcp` |
| PowerFlex 版本 | 3.x 與 4.x | 4.0 以上（需要 SDT） |
| 裝置 | `/dev/scini*`、`/dev/disk/by-id/emc-vol-*` | `/dev/nvme*n*` |
| 多路徑 | SDC 自己處理 | NVMe 原生（ANA） |
| kernel 升級後仍可用 | 只有在模組成功重建時 | 是 |
| 由本外掛安裝 | **否** | 無需安裝 |

`dell-protocol nvme` 之所以是預設值，單就最後一列的差別就足夠。

## 為什麼預設是 NVMe/TCP

SDC 是專有的 kernel module，必須與執行中的 kernel 相符。Dell 並未為 Proxmox VE 的 kernel 提供預先編譯好的 `scini`，因此必須在節點上編譯 —— 這代表一次 kernel 升級就可能讓某台節點在模組重建完成之前完全沒有儲存。

Dell 對 Proxmox VE 的說法有兩種，而兩者之間的落差，比其中任何一種說法本身更重要。

**Dell 有提供套件，也有寫操作步驟。** KB 000462918 說明如何在「Debian 與 Ubuntu 作業系統，包含 Proxmox Virtual Environment」上安裝 SDC，並直接點名 Debian 12（bookworm）／Proxmox VE 8.x；而 SDC 的 tarball 裡也包含 `Debian13_SDC` 這個變體 —— Debian 13 正是 Proxmox VE 9 的基底。PowerFlex 5.1.x 的文件也已經發布。

**但 Proxmox VE 並不在官方的作業系統支援矩陣裡。** KB 000272738 列出的是 Ubuntu LTS、RHEL、Oracle Linux、SLES、CentOS 與 AIX。Debian 不在其中，Proxmox VE 也不在，任何 PowerFlex 版本皆然。

換句話說：在 Proxmox VE 上使用 SDC，是 Dell 有發布安裝說明、也有提供套件的事，但**不是**它的支援矩陣所承諾的事。這對一張支援案件單究竟代表什麼，是要問您的 Dell 業務窗口的問題，而答案不在任何從這裡連得到的文件裡 —— 這才是這一頁原本那段文字的誠實版本。

查證日期 2026-07-27。兩份 KB 都會變動，請以它們為準，不要相信這一頁。

NVMe/TCP 沒有這些問題：initiator 就在 Proxmox 已經提供的 kernel 裡，升級不會讓它壞掉。

## Dell 官方資料

請把這些加入書籤；它們才是權威，而且內容會變動。

| 內容 | 連結 |
|---|---|
| **在 Proxmox VE 上設定 SDC** —— PVE 專屬的操作步驟 | [KB 000466868](https://www.dell.com/support/kbdoc/zh-tw/000466868/powerflex-%E5%A6%82%E4%BD%95%E5%9C%A8-proxmox-ve-%E4%B8%8A%E8%A8%AD%E5%AE%9A-powerflex-sdc) |
| **支援矩陣** —— 支援的作業系統與 kernel | [E-Lab Navigator：PowerFlex_OS.pdf](https://elabnavigator.dell.com/vault/pdf/PowerFlex_OS.pdf) |
| **我的 kernel 有支援嗎？** | [KB 000332118](https://www.dell.com/support/kbdoc/en-us/000332118/powerflex-sdc-how-to-determine-kernel-version-is-supported) |
| **在 Debian 系統上安裝 SDC** —— 直接點名 Proxmox VE，且內含 `Debian13_SDC` 變體 | [KB 000462918](https://www.dell.com/support/kbdoc/en-us/000462918/powerflex-how-to-install-sdc-on-debian-based-server) |
| **作業系統支援矩陣** —— Proxmox VE **不在**這份清單上 | [KB 000272738](https://www.dell.com/support/kbdoc/en-us/000272738/powerflex-operating-system-os-support-matrix) |
| **驅動程式的隨選編譯** | [KB 000224134](https://www.dell.com/support/kbdoc/en-us/000224134/how-to-on-demand-compilation-of-the-powerflex-sdc-driver) |
| 預先編譯的 `.ko` 檔，依 OS 與 PowerFlex 版本分類 | [mft.dell.com](https://mft.dell.com/) |
| NVMe/TCP 概觀 | [PowerFlex 4.5.x Technical Overview](https://www.dell.com/support/manuals/en-us/scaleio/flex-software-to-45x/nvme-over-tcp-overview) |

Dell 自己也說明，E-Lab 的矩陣不一定涵蓋各發行版釋出的每一個 kernel，並給了一條前綴規則：只要版本前綴與清單中的相符即視為支援 —— 例如 `4.18.0-553` 涵蓋 `4.18.0-553.51.1.el8_10.x86_64`。

## 本外掛在兩種路徑下的做法

**一顆 VM 磁碟 = 一個 PowerFlex volume**，全部透過 REST API 建立。中間沒有 LVM 層、沒有「切一顆大 volume 再在本地分割」、主機上也沒有 volume group：儲存伺服器自身的快照、複製與精簡配置都以「一顆 VM 磁碟」為自然單位運作，而 SDC（或 NVMe initiator）只負責把那個 volume 呈現成區塊裝置。

之所以要特別說明，是因為 Dell 的 Proxmox VE KB 裡有一個 LVM 步驟。那是給「要在 scini 裝置上疊 LVM」的人用的，本外掛並不這麼做。在我們的情境下，真正需要注意的 LVM 設定剛好相反，而且和 SAN 系列遇到的是同一個問題：主機端的 LVM 掃描器可能會自動啟用位於**客體磁碟內部**的 volume group，導致該 volume 無法刪除。詳見 [TROUBLESHOOTING_zh-TW.md](TROUBLESHOOTING_zh-TW.md) 的 LVM 段落。

## 如果您仍然選擇 SDC

本外掛不會安裝、設定或修復 SDC，它只會檢查模組是否已載入，並在未載入時明確說明。請依照 [KB 000466868](https://www.dell.com/support/kbdoc/zh-tw/000466868/powerflex-%E5%A6%82%E4%BD%95%E5%9C%A8-proxmox-ve-%E4%B8%8A%E8%A8%AD%E5%AE%9A-powerflex-sdc) 操作，流程大致如下：

```bash
# 編譯工具與對應的 headers。請保留 proxmox-default-headers，
# 它正是讓驅動程式在 kernel 更新後能自行重建的關鍵。
apt install gcc make proxmox-default-headers

# 開啟隨選編譯
mkdir -p /etc/emc/scaleio/scini_sync
touch /etc/emc/scaleio/scini_sync/.build_scini

# 安裝 SDC，並指向 MDM
MDM_IP=<mdm1>,<mdm2> dpkg -i EMC-ScaleIO-sdc-*.Debian*.x86_64.deb
```

Dell 針對 Proxmox VE 特別提醒的注意事項：

- **必須關閉 Secure Boot**，因為現場編譯出來的模組未經簽章。
- 在啟用隨選編譯之前，第一次安裝會失敗。
- 需要自行安排服務啟動順序，確保 `scini` 在儲存被使用之前就已就緒。
- 若您打算在這些裝置上跑 LVM，需要在 LVM 設定中加入 `scini` 裝置類型。本外掛不這麼做，因此在我們的情境下真正該設定的是 `global_filter`，避免主機啟用客體磁碟內部的 volume group。
- 在 Proxmox VE 8.x 上，容器與 VM 的遷移可能因 device-mapper 問題而失敗。

### 在節點上檢查狀態

```bash
lsmod | grep scini                       # 模組是否已載入？
systemctl status scini                   # 服務狀態？
/bin/emc/scaleio/drv_cfg --query_guid    # 本節點的 SDC GUID
/bin/emc/scaleio/drv_cfg --query_vols    # SDC 目前看得到的 volume
uname -r                                 # 拿去對照支援矩陣的 kernel 版本
```

若 kernel 升級後模組不見了，可以從驅動程式快取與建置腳本著手：

```bash
ls /bin/emc/scaleio/scini_sync/driver_cache/
/bin/emc/scaleio/scini_sync/driver_sync.sh
```

## 如果您選擇 NVMe/TCP

需要 PowerFlex 4.0 以上，且儲存端已設定 SDT。

```bash
apt install nvme-cli
modprobe nvme_tcp

# 本節點的 NQN。儲存伺服器必須先知道它，才會對應任何 volume。
cat /etc/nvme/hostnqn

nvme list-subsys        # 與 SDT 之間的連線
nvme list               # 目前掛載的 namespace
```

外掛會在 `activate_storage` 時連線到儲存伺服器公布的各個 SDT，若本節點的 NQN 尚未註冊則自動註冊為 host，並在對應 volume 之後等待 namespace 出現。

## NVMe/TCP 的多路徑

路徑由 NVMe 原生多路徑（ANA）處理，不是 dm-multipath。有三件事決定它是否真的有作用。

**1. 原生多路徑必須開啟。** 否則每一條路徑都會變成獨立的區塊裝置，而且可能同時從兩條路徑寫入。

```bash
cat /sys/module/nvme_core/parameters/multipath     # 必須是 Y
```

若顯示 N，請在 kernel 命令列加上 `nvme_core.multipath=Y` 並重開機。外掛在啟用時若偵測到它被停用會提出警告。

**2. 要連到每一個 SDT。** 只有一條連線不叫多路徑。外掛會在 `activate_storage` 時連線到儲存伺服器公布的每一個 target，若只連上部分會提出警告。

```bash
nvme list-subsys        # 一個 subsystem、多條路徑，並顯示 ANA 狀態
```

正常的輸出會有多條路徑，ANA 狀態為 `optimized` 或 `non-optimized`。狀態為 `inaccessible` 的路徑，就相當於失效路徑。

**3. 逾時必須是有限值。** 這與 SAN 系列的 `no_path_retry queue` 是同一個陷阱：所有路徑失效時，無限重試的 I/O 會讓行程進入不可中斷睡眠，該節點只能斷電重開。

| 設定 | Kernel 預設 | 本外掛 | 對應於 |
|---|---|---|---|
| `ctrl-loss-tmo` | 600 秒 | **60 秒**（`pflex-nvme-ctrl-loss-tmo`） | `no_path_retry` |
| `reconnect-delay` | 10 秒 | 10 秒 | — |
| `keep-alive-tmo` | 5 秒 | 5 秒 | path checker 間隔 |

外掛在每一次 `nvme connect` 都會帶上這些參數。只有在「預期會發生短暫的全路徑中斷，且排隊確實優於 I/O 錯誤」時，才需要調高 `pflex-nvme-ctrl-loss-tmo`。

```bash
# 查看控制器實際採用的值
cat /sys/class/nvme/nvme0/ctrl_loss_tmo
cat /sys/class/nvme/nvme0/reconnect_delay
```


最後重申 Dell 的一條規則：**同一個 volume 不能同時提供給 SDC 主機與 NVMe 主機。** 一個叢集可以同時使用兩種方式，但不能用在同一個 volume 上 —— 因此請不要讓兩個 `dell-protocol` 不同的儲存指向同一批 volume。
