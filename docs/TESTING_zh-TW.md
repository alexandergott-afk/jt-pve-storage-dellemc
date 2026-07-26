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
| NVMe-TCP | — | 不在 1.0 範圍 |

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

## 自動化檢查

```bash
make syntax                  # 對每個模組與腳本執行 perl -c
make unit                    # t/*.t
make check-multipath-flush   # 出現全系統 multipath flush 即失敗
make test                    # 以上全部
```

目前有 713 個單元測試，不需要陣列或實體裝置即可執行，涵蓋命名與歸屬檢查、REST 重試策略、orphan 清理防護、對照 fixture 的請求格式，以及外掛的 PVE schema。需要 `PVE::Storage::Plugin` 的測試在沒有 Proxmox VE 的機器上會自行跳過。

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
| 14 | 設定備份與 `pve-dell-config-get` | — | 設定可以讀回來 | — |
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
