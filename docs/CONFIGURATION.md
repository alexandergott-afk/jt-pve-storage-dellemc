# Configuration Reference

> **Status: skeleton (Phase 0).** Filled in as parameters are implemented in
> Phases 2–4. 繁體中文：[CONFIGURATION_zh-TW.md](CONFIGURATION_zh-TW.md)

Parameter naming follows a fixed convention: options shared by every Dell EMC
block family use the `dell-` prefix and are declared once in
`DellEMC::Common::BlockBase`; family-specific options use a family prefix
(`pstore-` for PowerStore). PVE registers storage properties in one shared
schema, so a name may only ever have one definition across all plugins.

Planned sections:

- Common options (`dell-portal`, `dell-username`, `dell-password`,
  `dell-ssl-verify`, `dell-protocol`, `dell-host-mode`, `dell-cluster-name`,
  `dell-device-timeout`, `dell-portal-probe-timeout`, `dell-status-timeout`,
  `dell-activate-deadline`, `dell-config-backup-timeout`).
- PowerStore options (`pstore-appliance`, `pstore-volume-group`,
  `pstore-performance-policy`, `pstore-protection-policy`,
  `pstore-lun-id-base`).
- Standard PVE options (`nodes`, `disable`, `content`, `shared`).
- Worked `storage.cfg` examples for iSCSI and FC.
- Timeout tuning: how `dell-status-timeout` keeps a slow array from stalling
  the whole `pvestatd` polling cycle.
