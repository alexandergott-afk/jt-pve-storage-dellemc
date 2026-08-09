# 發布前測試計畫

English: [RELEASE_TESTING.md](RELEASE_TESTING.md)

每次發布之前都要先跑完這份計畫。第 1〜3 階段不需要儲存伺服器，每次發布都必須全部通過，沒有例外。第 4 階段需要實機；在還沒有儲存伺服器可用的期間，請如實記錄為「未執行」，而不是默默跳過 —— 發行說明必須誠實反映「測了什麼」。

---

## 第 1 階段 —— 自動化檢查

```bash
make release-check
```

它會執行下列項目，且必須全部通過：

| 檢查 | 能抓到什麼 |
|---|---|
| `make check-multipath-flush` | 全系統 flush 指令出現在專案任何位置 |
| `make syntax` | 無法編譯的模組 |
| `make unit` | 所有單元測試 |
| 版本一致性 | `Makefile`、`debian/changelog`、`bin/pve-dell-config-get` 三者版本不一致 |
| 變更紀錄 | `CHANGELOG.md` 或 `CHANGELOG_zh-TW.md` 缺少新版本的條目 |

另外請在**Proxmox VE 節點**上再跑一次 `make syntax`。在沒有 PVE 的機器上，繼承 `PVE::Storage::Plugin` 的模組會回報為「已跳過」—— 那是誠實的結果，但不是覆蓋率：

```bash
make syntax
# 在 PVE 節點上的預期結果：每個模組都是 "... OK"，沒有任何跳過
```

---

## 第 2 階段 —— 套件

```bash
make deb
dpkg-deb -c ../jt-pve-storage-dellemc_*_all.deb | grep -E 'perl5|bin/'
```

預期：三個 plugin 模組、`DellEMC/` 目錄樹，以及權限為 0755 的 `/usr/bin/pve-dell-config-get`。

```bash
dpkg-deb -I ../jt-pve-storage-dellemc_*_all.deb | grep -E 'Version|Depends'
```

預期：版本與 `debian/changelog` 相符，且 Depends 包含 `proxmox-ve`、三個 Perl 模組、`open-iscsi`、`multipath-tools`、`sg3-utils`、`psmisc`。

---

## 第 3 階段 —— 安裝到 Proxmox VE 節點

請使用一台**已經設定了其他儲存**的節點。這個階段的重點就是：安裝本套件不會對它們造成任何影響。

```bash
pvesm status > /tmp/before.txt          # 基準
apt install ./jt-pve-storage-dellemc_*_all.deb
```

預期：postinst 印出 multipath 安全規則、回報 iscsid 與 multipathd 狀態，並在無錯誤的情況下重載 PVE 服務。

### 3.1 既有儲存不受影響

```bash
pvesm status > /tmp/after.txt
diff /tmp/before.txt /tmp/after.txt
```

預期：沒有任何儲存改變狀態。若在此處發生 `duplicate property` 失敗，該節點上的**每一個**儲存都會停止運作，因此這個 diff 是整份計畫中最重要的一項檢查。

### 3.2 三個 type 都已註冊

```bash
perl -e 'use PVE::Storage;
  my $p = PVE::Storage::Plugin->private()->{plugins};
  print join(", ", grep { /dell/ } sort keys %$p), "\n";'
```

預期：`dellpowerflex, dellpowerstore, dellpowervault`

### 3.3 Schema 驗證

```bash
pvesm add dellpowerstore t1
# 預期：missing value for required option 'dell-username'

pvesm add dellpowervault t2 --dell-portal 1.2.3.4 --dell-username u \
    --dell-password p --pvault-tier-affinity bogus
# 預期：value 'bogus' does not have a value in the enumeration

pvesm add dellpowerflex t3 --dell-portal 1.2.3.4 --dell-username u \
    --dell-password p
# 預期：missing value for required option 'pflex-storage-pool'

pvesm add dellpowerflex t4 --dell-portal 1.2.3.4 --dell-username u \
    --dell-password p --pflex-storage-pool p1 --pflex-nvme-ctrl-loss-tmo 9999
# 預期：value must have a maximum value of 600
```

### 3.4 儲存伺服器不可達時要乾淨地失敗

```bash
pvesm add dellpowerstore t5 --dell-portal 10.255.255.1 --dell-username u \
    --dell-password p --dell-status-timeout 2 --content images
```

預期：建立失敗，訊息中指出儲存名稱與位址，而且 `/etc/pve/storage.cfg` 中**不會**留下任何條目。

```bash
time pvesm status
```

預期：數秒內回應，且其他儲存全部維持 active。慢的儲存不可以餓死鄰居 —— 這正是 `dell-status-timeout` 存在的目的。

### 3.5 災難復原工具

```bash
pve-dell-config-get --help
pve-dell-config-get nosuchstore 100
# 預期：指出儲存名稱，並建議改用 recover 模式
```

---

## 第 4 階段 —— 實機

依系列進行，只有搭配真實儲存伺服器才有意義。完整的 26 項矩陣在 [TESTING_zh-TW.md](TESTING_zh-TW.md)：某個系列首次發布時請跑完整份矩陣；若該版本只改動共用程式碼，跑下列子集即可。

### 4.1 共用程式碼變更的子集

| # | 測試項 | 通過標準 |
|---|---|---|
| 1 | `pvesm status` | 容量與儲存伺服器自身 UI 的誤差在 1% 以內 |
| 2 | 建立磁碟 | 儲存伺服器上出現 volume，節點上出現裝置 |
| 3 | 寫入後讀回 | `dd` 寫入與讀出，checksum 相符 |
| 4 | 快照後還原 | 資料回到快照當下的狀態 |
| 5 | 從範本做連結複製 | 以秒計完成，不是以分鐘計 |
| 6 | 刪除磁碟 | volume 消失，且無殘留裝置或 map |
| 7 | 線上遷移 | 完成且 I/O 無中斷 |
| 8 | 拔掉一條路徑 | I/O 持續；該路徑顯示為失效 |
| 9 | 重開一台節點 | 自動登入且裝置自動出現 |

### 4.2 各系列另需確認

**PowerStore** —— 反覆對應與解除對應 300 次之後，LUN ID 仍維持在低位且密集（這正是外掛要迴避的 Dell 缺陷）。

**PowerVault ME** —— 使用長到會超過 32 bytes 的 storage id 時，建立階段就被拒絕並指出長度限制，而不是被截斷。

**PowerFlex** —— `nvme list-subsys` 顯示一個 subsystem 有多條路徑，ANA 狀態為 `optimized`／`non-optimized`，且 `cat /sys/module/nvme_core/parameters/multipath` 為 `Y`。若使用 SDC，則 `drv_cfg --query_vols` 應能列出該 volume。

### 4.3 長時間測試，僅在 1.0.0 之前

- 連續 72 小時的 pvestatd 輪詢，沒有誤報 `inactive`，journal 也沒有錯誤累積
- 管理網路中斷 10 分鐘後恢復：儲存自行回到 `active`，執行中的 VM 全程沒有 I/O 中斷

---

## 第 5 階段 —— 發布

只有在第 1〜3 階段全數通過，且第 4 階段已完成或明確記錄為未執行之後，才進行發布。

```bash
# 1. 版本。小版號逐次遞增，到 .99 才進位到次版號：
#    0.7.0、0.7.1、……、0.7.99，然後 0.8.0。
#    以下三處要同步更新：
#      Makefile                 VERSION
#      debian/changelog         最上方新增一則條目
#      bin/pve-dell-config-get  $VERSION
#
# 2. 變更紀錄，**兩種語言都要**
#      CHANGELOG.md  CHANGELOG_zh-TW.md
#
# 3. 帶著新版本再跑一次檢查
make release-check

# 4. 建置並把套件保留在 repository 中。每一版都要留著：
#    releases/ 就是封存區，測試者才能取得他手上正在跑的那一份建置。
#    只新增檔案，絕不取代舊的。
make deb
cp ../jt-pve-storage-dellemc_<version>_all.deb releases/

# 5. Commit、打 tag、推送
git add -A && git commit
git tag -a v<version> -m 'Release <version>'
git push origin main --tags
```

推送 tag 同時會觸發 GitHub release，附上相同的 `.deb` 與 `SHA256SUMS`。若 tag 與 `debian/changelog` 的版本不一致，workflow 會拒絕發布。

### 發布之後

```bash
# 在節點上安裝「已發布的套件」，而不是本地建置的版本
apt install ./jt-pve-storage-dellemc_<version>_all.deb
pvesm status        # 每個儲存都仍為 active
```
