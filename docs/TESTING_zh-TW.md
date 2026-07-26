# 測試與實機驗證狀態

> **狀態：骨架（Phase 0）。** English: [TESTING.md](TESTING.md)

## 實機驗證狀態

本專案目前尚未在任何實體 PowerStore 上驗證過。下列項目在實機執行並把結果（含當時的 PowerStore OS 版本）記錄到本文件之前，一律標記為 `NOT VERIFIED ON HARDWARE`。

| 項目 | 狀態 |
|---|---|
| REST 端點路徑與回應欄位名稱 | NOT VERIFIED ON HARDWARE |
| 認證流程（`login_session`、`DELL-EMC-TOKEN`） | NOT VERIFIED ON HARDWARE |
| multipath 比對用的 SCSI vendor／product 字串 | NOT VERIFIED ON HARDWARE |
| WWN 轉 multipath WWID 的換算 | NOT VERIFIED ON HARDWARE |
| Volume 名稱長度與字元限制 | NOT VERIFIED ON HARDWARE |
| LUN ID 配發行為 | NOT VERIFIED ON HARDWARE |
| Fibre Channel 資料路徑 | NOT VERIFIED ON HARDWARE |
| NVMe-TCP 資料路徑 | 不在 1.0 範圍內 |

## 自動化檢查

```bash
make syntax                  # 對每個模組與腳本執行 perl -c
make unit                    # t/*.t
make check-multipath-flush   # 出現全系統 multipath flush 即失敗
make test                    # 以上全部
```

## 人工測試矩陣

完整的 26 項測試矩陣（安裝、叢集一致性、容量回報、陣列離線行為、磁碟生命週期、快照、範本與複製、容器、線上遷移、路徑故障、重開機復原、orphan 清理、LUN ID 攀升、FC、PVE 升級）定義於 `jt-pve-storage-dellemc.md` 第 12 章，每完成一項就回填到本文件。
