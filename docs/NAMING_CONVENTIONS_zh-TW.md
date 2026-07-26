# 命名慣例

> **狀態：骨架（Phase 0）。** 正式規則隨 Phase 1 的 `Common::Naming` 一併定案。English: [NAMING_CONVENTIONS.md](NAMING_CONVENTIONS.md)

## 前綴隔離

外掛在陣列上建立的每個物件都以 `pve-<storeid>-` 命名，所有列舉、刪除與清理路徑都先以此前綴過濾。沒有這個前綴的物件一律不讀取、不改名、不刪除 — 這是讓外掛能與其他工作負載共用同一台陣列的安全邊界。

## 對照表（規劃）

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

PowerStore 的名稱長度與可用字元限制尚待實機確認，請見 `docs/TESTING.md`。
