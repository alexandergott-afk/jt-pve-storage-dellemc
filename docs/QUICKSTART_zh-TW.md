# 快速上手

English: [QUICKSTART.md](QUICKSTART.md)

> **請先讀這段。** 截至 0.5.0，本外掛的任何部分都尚未在實體 PowerStore 上執行過。請使用非正式環境的叢集與陣列，並在開始之前先看過 [TESTING_zh-TW.md](TESTING_zh-TW.md)。

## 1. 前置需求

每一台 PVE 節點：

- Proxmox VE 9.1 以上
- 已安裝 `open-iscsi`、`multipath-tools`、`sg3-utils`、`psmisc`
- 可連到陣列的管理位址；使用 iSCSI 時還要能連到 target portal，使用 FC 則要完成 fabric 分區

陣列端：

- PowerStore OS 3.0 以上
- 一組至少具備 Storage Operator 角色的 REST API 帳號
- 已公布 iSCSI target 位址，或已完成 FC 分區

## 2. 在每一台節點安裝

```bash
apt install ./jt-pve-storage-dellemc_<version>_all.deb
```

請使用 `apt install ./file.deb` 而非 `dpkg -i`：`dpkg -i` 不會安裝相依套件，缺少的執行檔要等到很後面才會以外掛內部的錯誤形式浮現。

沒有安裝套件的節點，操作此儲存時會回應 `Parameter verification failed (400)` 或 `No such storage`，也無法成為線上遷移的目的地。

## 3. 檢查 multipath 設定

安裝程式會印出安全規則，並對偵測到的危險設定提出警告。其中兩項值得親自確認：

```bash
grep -rE 'no_path_retry|dev_loss_tmo|queue_if_no_path' \
    /etc/multipath.conf /etc/multipath/conf.d/ 2>/dev/null
```

`no_path_retry queue` 與 `dev_loss_tmo infinity` 不可套用到這些裝置。當所有路徑都失效時，永遠無法完成的排隊 I/O 會讓行程進入不可中斷睡眠，該節點只能斷電重開。

外掛會在第一次啟用時寫入自己的 drop-in 檔 `/etc/multipath/conf.d/dellpowerstore.conf`。該檔帶有版本標記；沒有標記的檔案會被視為您自己的檔案，永遠不會被更動。

## 4. 新增儲存

```bash
pvesm add dellpowerstore ps1 \
    --dell-portal 192.168.1.50 \
    --dell-username pveadmin \
    --dell-password 'SecurePassword' \
    --dell-protocol iscsi \
    --content images,rootdir \
    --shared 1
```

在任一台節點執行一次即可 —— `/etc/pve/storage.cfg` 是整個叢集共用的。

使用 Fibre Channel 請改為 `--dell-protocol fc`。若只有部分節點接上 fabric，請加上 `--nodes node1,node2`。

完整參數說明：[CONFIGURATION_zh-TW.md](CONFIGURATION_zh-TW.md)。

## 5. 驗證

```bash
pvesm status
```

該儲存應顯示為 `active` 並帶有陣列容量。陣列上此時應該已為每台節點建立一個 host 物件，名稱為 `pve-{cluster}-{node}`。

若顯示 `inactive`，原因會在 journal 中：

```bash
journalctl -t pvestatd -n 50 | grep dellpowerstore
```

## 6. 建立磁碟並確認路徑

```bash
qm create 999 --name dell-test --memory 1024
qm set 999 --scsi0 ps1:8            # 8 GB
```

接著檢查兩端：

```bash
# 節點端：應出現一個具有多條路徑的 multipath 裝置
multipath -ll | grep -A5 DellEMC

# 陣列端：應出現名為 pve-ps1-999-disk0 的 volume
```

`pvesm list ps1` 應會列出 `ps1:vm-999-disk-0`。

## 7. 試做一次快照

```bash
qm snapshot 999 before-change
pve-dell-config-get -l ps1 999      # 一併建立的設定備份
qm delsnapshot 999 before-change
```

每次快照都會另外把 VM 設定寫進一個 1 MB 的 volume，因為儲存快照只還原磁碟，不含設定。`pve-dell-config-get` 可以把那些設定讀回來，即使 `/etc/pve` 已經不存在也可以 —— 詳見 [TROUBLESHOOTING_zh-TW.md](TROUBLESHOOTING_zh-TW.md)。

## 8. 清掉測試用的資源

```bash
qm destroy 999
```

確認陣列上的 volume 已消失，且節點端沒有殘留裝置：

```bash
multipath -ll | grep -c DellEMC
```

## 後續閱讀

- [CONFIGURATION_zh-TW.md](CONFIGURATION_zh-TW.md) — 所有選項，以及高負載時真正有影響的三個
- [TROUBLESHOOTING_zh-TW.md](TROUBLESHOOTING_zh-TW.md) — 症狀與處理方式
- [TESTING_zh-TW.md](TESTING_zh-TW.md) — 哪些已驗證、哪些還沒
