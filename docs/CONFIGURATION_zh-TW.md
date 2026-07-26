# 設定參數說明

> **狀態：骨架（Phase 0）。** 隨 Phase 2〜4 實作參數時逐步補齊。English: [CONFIGURATION.md](CONFIGURATION.md)

參數命名採固定慣例：所有 Dell EMC block 系列共通的選項使用 `dell-` 前綴，且只在 `DellEMC::Common::BlockBase` 定義一次；各系列專屬選項使用系列前綴（PowerStore 為 `pstore-`）。PVE 的 storage property 註冊在同一份共用 schema，因此同一個名稱在所有外掛之間只能有一種定義。

預計章節：

- 共通選項（`dell-portal`、`dell-username`、`dell-password`、`dell-ssl-verify`、`dell-protocol`、`dell-host-mode`、`dell-cluster-name`、`dell-device-timeout`、`dell-portal-probe-timeout`、`dell-status-timeout`、`dell-activate-deadline`、`dell-config-backup-timeout`）。
- PowerStore 專屬選項（`pstore-appliance`、`pstore-volume-group`、`pstore-performance-policy`、`pstore-protection-policy`、`pstore-lun-id-base`）。
- PVE 標準選項（`nodes`、`disable`、`content`、`shared`）。
- iSCSI 與 FC 的 `storage.cfg` 完整範例。
- 逾時調校：`dell-status-timeout` 如何避免反應緩慢的陣列拖垮整輪 `pvestatd` 輪詢。
