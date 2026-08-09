# 第一次上實機

English: [FIRST_RUN.md](FIRST_RUN.md)

本外掛的任何一部分都還沒有在真正的 Dell EMC 儲存伺服器上跑過。所有面向儲存伺服器的行為都是依據 Dell 公開文件寫出來的；文件讀不到的部分則是推測 —— 而光是 PowerVault，這些推測就已經被證實錯了四次，每一次都是回頭去讀指南才發現的。

因此第一次上機不是走個形式。這份文件寫的是「該用什麼順序做」、「每一步之後要看什麼」，以及「失敗最可能代表什麼」。它預設你在一台節點上、用一台 VM，由上而下走完，然後才讓其他東西碰這個儲存。

請先準備好：

- 一台你敢重開機的節點；
- 一組具備所需權限的儲存伺服器帳號（PowerStore 需要 Storage Operator，PowerVault 需要 `manage`）；
- 儲存伺服器的管理位址，以及開在旁邊的儲存伺服器 GUI 或 CLI；
- 30 分鐘。

---

## 在儲存建立之前

### 1. 安裝，並確認其他東西沒有跟著動

```bash
pvesm status > /tmp/before.txt
apt install ./jt-pve-storage-dellemc_<version>_all.deb
systemctl restart pvestatd            # 每一台節點都要
pvesm status > /tmp/after.txt
diff /tmp/before.txt /tmp/after.txt
```

**預期**：沒有任何儲存改變狀態。如果節點上**所有**儲存都變成 `inactive` 或直接消失，代表這個外掛破壞了整個節點的 storage schema —— 請移除套件、重啟 `pvestatd` 並回報。正是因為有這種失效模式，這一項才排在第一個。

`systemctl restart pvestatd` 不是可有可無的。在許多 PVE 版本上，`reload` 會讓舊的 Perl 程式碼留在記憶體裡；請確認 PID 真的變了：

```bash
systemctl show -p MainPID pvestatd
```

### 2. 確認三個 type 都註冊了

```bash
perl -e 'use PVE::Storage;
  my $p = PVE::Storage::Plugin->private()->{plugins};
  print join(", ", grep { /dell/ } sort keys %$p), "\n";'
```

**預期**：`dellpowerflex, dellpowerstore, dellpowervault`，而且**不會**出現 `implementing an older storage API` 警告。出現該警告代表協商出來的 API 版本不適用於這台 PVE —— 請一併回報：

```bash
perl -MPVE::Storage -e 'print PVE::Storage::APIVER, " ", PVE::Storage::APIAGE, "\n"'
```

---

## 加入儲存

### 3. 加進去，並盯著儲存伺服器端的變化

請把儲存伺服器的 GUI 開著。storage id 要**短** —— PowerVault 只給它 10 個字元、PowerFlex 9 個，太長會在建立時就被拒絕，而不是默默截斷。

```bash
pvesm add dellpowerstore ps1 \
    --dell-portal 10.0.0.5 --dell-username pveadmin --dell-password 'secret' \
    --dell-protocol iscsi --content images,rootdir
```

**預期**：指令正常返回，而且儲存伺服器上出現一個名為 `pve-<cluster>-<node>` 的 host 物件，帶著這台節點的 IQN 或 WWPN。

| 你看到的 | 代表什麼 |
|---|---|
| `Cannot reach the array at ...` | 管理位址、帳密或 TLS 有問題。訊息中 `Array error:` 之後的是儲存伺服器自己的說法 |
| host 物件沒有出現 | 建立 host 的指令被拒絕了；請看儲存伺服器的事件記錄裡它說了什麼 |
| 這台節點的 IQN 掛在**別的** host 物件上 | 先前的手動註冊佔用了它。請在儲存伺服器上移除，或設定 `dell-cluster-name` 讓產生的名稱與既有的一致 |

### 4. `pvesm status`，以及最該先確認的四件事

```bash
time pvesm status
```

**預期**：儲存是 `active`，容量與儲存伺服器自己的 UI 相差在 1% 以內，而整個指令只花幾秒。如果要花上數十秒，請當成問題回報 —— 慢的儲存會餓死鄰居，而那正是 `dell-status-timeout` 要限制的事。

接著是「其他一切都依賴它們」的四項未驗證項目：

```bash
# 1. 本外掛用來判斷「會去碰哪些裝置」的 SCSI vendor 與 product 字串
sg_inq /dev/sdX | head -3

# 2. 由儲存伺服器 WWN 推導出的 WWID，與主機實際看到的比對
/lib/udev/scsi_id -g -u /dev/sdX

# 3. 儲存伺服器公布了哪些 iSCSI portal，以及這台節點實際連上了哪些
iscsiadm -m session

# 4. 本外掛寫出來的 multipath drop-in
cat /etc/multipath/conf.d/dellpowerstore.conf
multipath -ll
```

第 1 項要與系列外掛裡的 `multipath_vendor`／`multipath_product` 比對：不一致的話，**任何裝置都不會被辨識**，而這正是第一次上機最可能發生的失敗。第 2 項則要與 `multipath -ll` 裡的 WWID 比對。

---

### Unity XT：第一次接觸

Unity 系列從未在儲存伺服器上執行過；首次執行正是用來結清
[TESTING_zh-TW.md](TESTING_zh-TW.md) 裡 `NOT VERIFIED` 登記的。三件特別的事：

```bash
pvesm add dellunity u480 \
    --dell-portal 192.168.1.21,192.168.1.22 \
    --dell-username admin --dell-password '...' \
    --dell-protocol fc --unity-pool pool_1 --content images,rootdir
```

- **`dell-portal` 事後不能改。** Unity 設計上有一個跟著主 SP 走的浮動管理
  IP，填它即可；若你想多一層保險，也可以逗號再列入 SP 的固定位址。
- **第一顆 LUN 對應之後，回報三件事**：`sg_inq /dev/sdX`（本外掛用來過濾
  清掃範圍的 vendor／product 字串）、外掛算出的 WWID 是否與 `multipath -ll`
  一致、以及第一次 `qm rollback` 之後，儲存伺服器上是否有名為
  `<磁碟區>.pve-snap-pve.rollback*` 的快照（那是 `copyName` 生效的證明；
  如果出現的反而是儲存伺服器自取名稱的快照，請立刻回報）。
- **錯誤訊息裡的 302 是授權失敗**，不是重新導向：代表 `X-EMC-REST-CLIENT`
  標頭沒有送達。請檢查節點與儲存伺服器之間有沒有 proxy。

### 儲存伺服器上可能原本就有屬於這台節點的 host 物件

在這個外掛跑起來之前，儲存伺服器上通常已經有一個 —— 由當初做 fabric 分區的人建立 ——
以它自己的命名持有這台節點的 WWPN 或 IQN，例如 `tpepve-01-fc`。一個 initiator 只能
屬於**一個** host 物件，所以外掛沒辦法用自己的名稱把同樣的埠再註冊一次。

在 PowerStore 上它也不會去試。當 `pve-{叢集}-{節點}` 這個名稱底下沒有 host 時，它會
問儲存伺服器「本節點的 initiator 現在在哪個 host 上」，改用那一個，並把名稱記在
`/var/lib/pve-storage-dellemc/{storeid}-host`。不改名、不刪除，也不搬動任何
initiator。journal 裡會看到一次這樣的訊息：

```
Storage 'ps1': this node's initiators are already registered to host
'tpepve-01-fc' on the array, so that object is used instead of creating
'pve-pve-tpepve01'. It holds this node's ports and no others.
```

有兩種情況會被拒絕而不是自行猜測，訊息裡都會指名是哪一個：

- 那個 host 同時持有**別台的**埠 —— 對應到它的磁碟區會被那台看見；
- 本節點的埠散在**兩個** host 物件上 —— 一個節點就是一個 host 物件，要合併是您的決定。

每台節點會在自己第一次啟用這個儲存時各自解析，不需要逐台操作。

---

## 第一台 VM

### 5. 一顆磁碟

```bash
pvesm alloc ps1 999 '' 8G
pvesm list ps1
```

**預期**：儲存伺服器上出現名為 `pve-ps1-999-disk0`（PowerStore）或 `pve-ps1-999-d0`（PowerVault、PowerFlex）的 volume，已對應到這台節點，而 `/dev/mapper` 底下出現對應裝置。

| 你看到的 | 代表什麼 |
|---|---|
| `The device for volume ... did not appear within 60s` | volume 存在也對應好了，但裝置沒出現。訊息中會附上 iSCSI session 狀態；不是 `LOGGED_IN` 的 session 無法送出 LUN |
| volume 建好之後又被刪掉 | 對應失敗，外掛把它回滾了。儲存伺服器的拒絕理由就在訊息裡 |
| 會成功，但幾乎耗掉整個逾時 | 請看 `multipath -ll` 裡有沒有 `failed faulty` 的路徑 |

### 6. 寫進去，再讀回來

```bash
dd if=/dev/urandom of=/dev/mapper/<wwid> bs=1M count=100 oflag=direct
dd if=/dev/mapper/<wwid> bs=1M count=100 iflag=direct | md5sum
```

這是「找到的裝置確實就是建立的那個 volume」的第一個證據。這裡若錯了，代表 WWID 對應是錯的，而外掛會寫到任何回應它的其他東西上。

### 7. 快照與還原

```bash
qm create 999 --name firstrun --scsi0 ps1:8 --scsihw virtio-scsi-single
qm snapshot 999 before
qm rollback 999 before
qm listsnapshot 999
```

**預期**：儲存伺服器上出現名為 `<volume>.pve-snap-before`（PowerStore）或 `<volume>-s-before`（PowerVault、PowerFlex）的快照，而還原正常返回。

「還原到不是最新的那個快照」是**刻意**被拒絕的：Dell 沒有說明還原之後，比還原點更新的快照會怎麼樣，而本外掛不願意讓 PVE 繼續列出儲存伺服器可能已經清掉的還原點。若你確認了自己儲存伺服器的行為，`dell-rollback-any-snapshot 1` 可以解除這個限制 —— 也請告訴我們你的發現。

### 8. 範本與連結複製

```bash
qm template 999
qm clone 999 1000 --name clone-of-firstrun
qm start 1000
```

**預期**：複製是瞬間完成的 —— 以秒計，不是以分鐘計。若花了好幾分鐘，那是完整複製，連結複製的路徑沒有生效。

接著確認刪除順序的規則成立：

```bash
qm destroy 999      # 在複製還在時，這一步預期會失敗
qm destroy 1000     # 先刪複製
qm destroy 999      # 再刪範本
```

第一步必須失敗，而且訊息中要指出是哪個相依的複製擋住了。如果它成功了，代表這台儲存伺服器允許刪除仍有相依物件的範本，這值得回報。

### 9. 全部刪掉，然後檢查有沒有殘留

```bash
qm destroy 1000; qm destroy 999
pvesm list ps1
multipath -ll
ls /dev/disk/by-id/ | grep -i <wwid-prefix>
```

**預期**：儲存伺服器上什麼都不剩、沒有 multipath map、也沒有殘留的 `sd` 路徑。殘留的 `sd` 裝置平時是安靜的，直到下一次 `multipathd` reload 用 `EBUSY` 灌滿 journal；詳見 [TROUBLESHOOTING_zh-TW.md](TROUBLESHOOTING_zh-TW.md)。

---

## 讓它跑一陣子

把儲存留著，觀察一段時間：

```bash
journalctl -u pvestatd -f | grep dellemc
```

**預期**：安靜。本外掛只有在出問題、或某個上限快到了的時候才會說話。有兩行值得先認識：

- `OUTAGE - the array API has been unreachable for Ns` —— 健康檢查放棄了。它回報的是「經過多久」而不是「輪詢幾次」，因為 PVE 一旦把儲存標成 inactive 就會有一段時間不再詢問。
- `orphan cleanup: ... is not on this storage's array and is not tracked` —— 一個本外掛不認識的裝置。它只會被**回報，永遠不會被自動移除**。動它之前請先確認沒有東西在用，而且絕不要用全系統的 flush。

---

## 如果它不動

收集以下這些，通常就足以判斷發生了什麼事：

```bash
pveversion -v | head -5
perl -MPVE::Storage -e 'print PVE::Storage::APIVER, " ", PVE::Storage::APIAGE, "\n"'
cat /etc/pve/storage.cfg | sed 's/dell-password.*/dell-password ***/'
journalctl -u pvestatd --since -30min | grep -i dell
multipath -ll
iscsiadm -m session
sg_inq /dev/sdX | head -5
```

同一時段儲存伺服器自己的事件記錄，和上面任何一項一樣重要：本外掛回報的是儲存伺服器告訴它的話，而儲存伺服器通常說得更多。

`docs/TESTING_zh-TW.md` 列出了哪些部分仍是推測、而非從 Dell 文件讀出來的。如果失敗剛好落在那些項目上，那就是第一個該看的地方。
