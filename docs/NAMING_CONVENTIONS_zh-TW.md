# 命名慣例

English: [NAMING_CONVENTIONS.md](NAMING_CONVENTIONS.md)

命名規則實作於 `Common::Naming`，PowerStore 的限制在 `PowerStore::Naming`。`t/01-naming.t` 涵蓋雙向轉換與歸屬檢查。

## 前綴隔離

外掛在陣列上建立的每個物件都以 `pve-<storeid>-` 命名，所有列舉、刪除與清理路徑都先以此前綴過濾。沒有這個前綴的物件一律不讀取、不改名、不刪除 — 這是讓外掛能與其他工作負載共用同一台陣列的安全邊界。

## 對照表

| PVE 物件 | 陣列物件 | 命名樣式 |
|---|---|---|
| VM 磁碟 | Volume | `pve-{storeid}-{vmid}-disk{n}` |
| Container rootfs | Volume | `pve-{storeid}-{vmid}-disk{n}` |
| Cloud-init | Volume | `pve-{storeid}-{vmid}-cloudinit` |
| EFI disk | Volume | `pve-{storeid}-{vmid}-efidisk{n}` |
| TPM state | Volume | `pve-{storeid}-{vmid}-tpmstate{n}` |
| RAM state（vmstate） | Volume | `pve-{storeid}-{vmid}-state-{snapname}` |
| VM 設定備份 | Volume（1 MB、ext4） | `pve-{storeid}-{vmid}-vmconf-{snapname}` |
| 快照 | Volume snapshot | `{volume}.pve-snap-{snapname}` |
| 範本標記 | Volume snapshot | `{volume}.pve-base` |
| PVE 節點 | Host | `pve-{cluster}-{node}` |
| 共享 host | Host group | `pve-{cluster}-shared` |

名稱中的 storeid 會先經過清洗：`[A-Za-z0-9_-]` 以外的字元變成 `_`，連字號也變成底線。底線轉換的用意，是避免某個儲存的前綴包含另一個儲存的前綴 —— 否則 `ps` 與 `ps-1` 會得到 `pve-ps-` 與 `pve-ps-1-`，儲存 `ps` 就會把 `ps-1` 的 volume 當成自己的。

PowerStore 自身的名稱長度與字元限制仍待實機確認，請見 [TESTING_zh-TW.md](TESTING_zh-TW.md)。
