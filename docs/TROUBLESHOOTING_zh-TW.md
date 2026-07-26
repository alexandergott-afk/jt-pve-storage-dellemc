# 疑難排解

English: [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

本外掛的每一則訊息都以 `[dellpowerstore:<storeid>]` 為前綴，所以請從這裡開始查：

```bash
journalctl -t pvestatd -t pvedaemon | grep dellpowerstore
```

---

## 出現 `Parameter verification failed (400)` 或 `No such storage`

該節點沒有安裝套件。叢集內**每一台**節點都要安裝；`/etc/pve/storage.cfg` 是全叢集共用的，但外掛程式碼不是。

```bash
# 在出錯的那台節點上
dpkg -l jt-pve-storage-dellemc
```

升級之後，也請在每台節點執行 `systemctl restart pvestatd`：reload 無法可靠地替換已經載入記憶體的 Perl 模組。

---

## 儲存顯示 `inactive`

`inactive` 表示健康檢查輪詢失敗，它**不會**影響執行中的 VM：那些 VM 的裝置仍然對應著，I/O 也不受影響。

```bash
journalctl -t pvestatd -n 50 | grep dellpowerstore
```

依值得檢查的順序，常見成因如下：

1. **帳號密碼。** journal 中會看到 `HTTP 401`。請確認 `dell-username` 與 `dell-password`，以及該帳號在 PowerStore Manager 中沒有被鎖定。
2. **管理網路。** 出現的是逾時而不是 401。請從「該台節點」確認連線是否可達。
3. **陣列回應慢。** 健康路徑只給 `dell-status-timeout` 秒（預設 5 秒）且只嘗試一次。負載很重的陣列可能讓儲存在某一次輪詢變成 `inactive`，下一次就恢復；若持續發生再調高逾時。
4. **沒有可用路徑。** iSCSI 情況下，若沒有任何 portal 可達，`activate_storage` 會直接失敗，訊息中會列出它嘗試過哪些。

如果**其他**儲存也在同一時間變成 `inactive`，請懷疑是這個儲存太慢：PVE 是依序輪詢儲存的，一個慢的會拖累其他。`dell-status-timeout` 存在的目的就是限制這件事。

---

## 過一段時間之後，新磁碟就掃不到了

症狀是：陣列上有建立 volume、對應也存在，但主機端始終沒有出現裝置；舊的 volume 仍然正常。

PowerStore 對 UI 與 REST／PSTCLI **各自維護一組自動 LUN ID 序列**。REST 那一組從 200 開始，而且只會往上加，ID 不會重用。PVE 叢集會不斷地掛載與卸載，於是那個計數器一路往上爬，直到超過主機 SCSI 層會掃描的範圍，之後的每一顆新磁碟都看不到。

本外掛就是為此改為自行配發 LUN ID，從 `pstore-lun-id-base`（預設 1）往上找空號填補，因此不應該再發生。要確認某台 host 目前的狀況：

```
在 PowerStore Manager 中開啟 Compute > Host Information > <host> > Mapped Volumes，
檢視 LUN 欄位
```

若發現有本外掛啟用之前留下的高 ID，請把那些 volume 卸載後重新掛載，讓它們取得較低的 ID。

---

## `Cannot delete volume ... device is still in use`

外掛會拒絕刪除「已掛載、有 holder、或被行程開啟」的 volume，訊息中會列出它找到什麼。

最常見的成因**不是**執行中的 VM，而是主機端的 LVM 自動啟用了位於客體磁碟**內部**的 volume group；這在從舊版 PVE 升級上來的節點上很常見：

```bash
lsblk /dev/mapper/<wwid>
vgs -o vg_name,vg_uuid,pv_name
```

停用該客體 VG 之後再重試：

```bash
vgchange -an <guest_vg_name>
```

要避免再次發生，請在 `/etc/lvm/lvm.conf` 的 `devices` 區段加入過濾規則：

```
global_filter = [ "r|/dev/mapper/36.*|", "r|/dev/dm-.*|", "a|.*|" ]
```

全新安裝的 PVE 9 已經有過濾規則，升級上來的節點通常沒有。

---

## 所有路徑都失效的殘留 multipath 裝置

從其他節點刪掉的 volume，會在本節點留下一個指向已不存在儲存的 map。外掛的 orphan 清理機制會自動移除，但必須同時滿足：該 WWID 已追蹤超過寬限期（10 分鐘）**且**連續三次輪詢都沒在陣列上出現，而且裝置處於閒置狀態。這些防護存在的理由是：清掉一個實際仍在使用的裝置，等於毀掉一台執行中 VM 的磁碟。

外掛不認得的裝置只會被回報，不會被移除：

```
orphan cleanup: /dev/mapper/36... is not on this storage's array and is not
tracked by any Dell storage on this node
```

要手動移除，一次處理一個 map：

```bash
multipathd disablequeueing map <wwid>
dmsetup message <wwid> 0 fail_if_no_path
multipath -f /dev/mapper/<wwid>
# 只有在上一步失敗時才用：
dmsetup remove --force --retry <wwid>
```

**絕對不要用 `multipath -F`**（大寫 F）。它會清掉節點上所有未使用的 map，包含不屬於本外掛管理的儲存。

---

## 行程卡在 D state、節點失去回應

不可中斷睡眠無法被任何訊號清除，包括 SIGKILL。一旦 PVE 服務進入這個狀態，該節點只能重開機。

成因幾乎都是「對沒有可用路徑的裝置持續排隊 I/O」，也就是這些裝置套用到了 `no_path_retry queue` 或 `queue_if_no_path`：

```bash
grep -rE 'no_path_retry|queue_if_no_path|dev_loss_tmo' \
    /etc/multipath.conf /etc/multipath/conf.d/
multipath -ll     # 找出所有路徑都失效的 map
```

把設定改成 `no_path_retry 30`、`fast_io_fail_tmo 5`、`dev_loss_tmo 60`，然後：

```bash
systemctl restart multipathd     # 是 restart，不是 reload
```

`reload` 只會重讀檔案，`restart` 才會重新套用 device-mapper 狀態。

---

## 某個 volume 的裝置始終沒有出現

錯誤訊息本身已經帶上失敗當下的主機端狀態：multipathd 的視角、該 WWID 是否已有 map、udev 是否建立了節點，以及 iSCSI session 的狀態。請先讀那段訊息，再考慮重現問題。

有一種情況特別值得注意：`rescan` 只會對核心回報為 `LOGGED_IN` 的 session 發出。停在 `FAILED` 或 `REOPEN` 的 session 會被跳過，因此只能經由那條路徑到達的 volume，等再久也不可能被探索到。符合這個情況時，診斷訊息會明講。

```bash
iscsiadm -m session
cat /sys/class/iscsi_session/session*/state
```

FC 環境：

```bash
cat /sys/class/fc_host/host*/port_state
cat /sys/class/fc_remote_ports/rport-*/port_state
```

---

## 復原 VM 設定

儲存快照還原的是磁碟。VM 的設定放在 `/etc/pve`，不在快照範圍內，因此每次快照都會另外把設定寫進磁碟旁邊的一個 1 MB volume。

```bash
# 看看有哪些可用
pve-dell-config-get -l ps1 100

# 還原其中一個
pve-dell-config-get ps1 100 before-upgrade > /etc/pve/qemu-server/100.conf
```

當 `/etc/pve` 本身已經不存在，或 pvedaemon 起不來時，這個工具可以直接跟陣列溝通：

```bash
pve-dell-config-get -r --portal 10.0.0.5 --username pveadmin \
    --password secret ps1 100 before-upgrade
```

過程中該 volume 會以唯讀方式掛載，結束後自動卸載並解除對應，即使失敗或按下 Ctrl-C 也一樣。

---

## 完整複製（Full Clone）很慢

這是預期行為，也無法從外掛這端解決。PVE 對完整複製的實作是 `alloc_image` 加上 `qemu-img` 逐區塊複製，完全不會呼叫外掛的 `clone_image`。想要陣列端的即時精簡複製，請使用**連結複製（Linked Clone）**。

---

## 刪除範本失敗

範本的標記快照是所有由它衍生的連結複製的來源。只要那些複製還存在，陣列就會拒絕刪除，外掛會把相依物件列出來。請先刪掉那些複製。

---

## 回報問題時要收集的資訊

```bash
pveversion -v | head -5
dpkg -l jt-pve-storage-dellemc
journalctl -t pvestatd -t pvedaemon --since '30 min ago' | grep -i dell
multipath -ll
iscsiadm -m session          # 或上面的 FC 指令
cat /etc/pve/storage.cfg     # 請先把密碼移除
```
