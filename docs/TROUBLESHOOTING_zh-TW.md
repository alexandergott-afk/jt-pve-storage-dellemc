# 疑難排解

> **狀態：骨架（Phase 0）。** 與 Phase 4 同步撰寫。English: [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

預計條目：

- `Parameter verification failed (400)`／`No such storage` — 該節點沒有安裝本套件。叢集每一台節點都要安裝。
- `pvesm status` 顯示 `inactive` — 檢查管理網路、帳號密碼，或 `dell-status-timeout` 是否設得比陣列實際回應時間還短。
- 反覆 attach／detach 之後新磁碟掃不到 — PowerStore 對 UI 與 REST／PSTCLI 各自維護一組自動 LUN ID 序列，REST 那組只會遞增不會重用。外掛改為自行指定 LUN ID 以迴避此問題；本條說明如何確認現況與如何收斂。
- 無法刪除 volume，出現「device is still in use (has holders)」 — 通常是主機端 LVM 自動啟用了位於客體磁碟內部的 VG，需設定 LVM `global_filter`。
- 所有路徑皆失效的殘留 multipath map — 如何辨識，以及如何安全地只移除單一 map。
- 裝置進入 D state — 成因，以及為何必須避免 `no_path_retry queue` 與 `dev_loss_tmo infinity`。
- 從 journal 讀取外掛訊息：所有訊息都以 `[dellpowerstore:<storeid>]` 為前綴。
