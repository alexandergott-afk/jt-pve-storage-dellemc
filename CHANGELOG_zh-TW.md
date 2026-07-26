# 變更紀錄

本專案所有值得記錄的變更都寫在這裡。
English version: [CHANGELOG.md](CHANGELOG.md)

## [0.1.0] - 2026-07-26

Phase 0 — 專案骨架。本版本尚未註冊任何 storage type。

### 新增
- MIT 授權、雙語 README 骨架（含 multipath 安全規則與實機驗證免責聲明）。
- `Makefile`，提供 `install`、`uninstall`、`test`、`syntax`、`unit`、`check-multipath-flush`、`deb`、`clean` 等目標。模組清單改由 `lib/**/*.pm` 自動探索，不需手動維護，後續各階段新增模組時打包設定不必跟著改。
- Debian 打包檔：`control`、`rules`、`compat`、`changelog`、`copyright`、`docs`、`postinst`、`prerm`、`postrm`。安裝動作透過 `override_dh_auto_install` 交由 Makefile 執行。
- `postinst` 檢查項目：必要執行檔是否存在（可攔截以 `dpkg -i` 安裝而未解相依的情況）、`/etc/multipath.conf` 與 `/etc/multipath/conf.d/*.conf` 中的危險設定、所有路徑皆失效的 Dell 殘留 map、缺少 LVM `global_filter`、進行中的儲存操作，以及叢集全節點安裝提醒。
- GitHub Actions 工作流程：安全檢查、`perl -c` 與單元測試通過後才建置 `.deb`。
- CI 檢查 `make check-multipath-flush`：只要程式碼或文件出現全系統 flush 的大寫 F 指令，建置即失敗；明確禁止該指令的敘述文字則放行。
- 多系列架構的目錄骨架（`lib/PVE/Storage/Custom/`、`DellEMC/Common/`、各系列子目錄、`t/`、`docs/`、`bin/`）。
