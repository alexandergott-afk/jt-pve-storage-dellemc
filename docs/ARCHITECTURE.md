# Architecture

> **Status: outline (Phase 0).** Expanded in Phase 2 with the concrete
> `BlockBase` contract. 繁體中文：[ARCHITECTURE_zh-TW.md](ARCHITECTURE_zh-TW.md)

## One repository, several storage types

Dell EMC product families differ too much to share a single PVE storage type.
Each family is registered as its own type and they share a host-side layer:

| Family | PVE type | Data path | Base class |
|---|---|---|---|
| PowerStore | `dellpowerstore` | iSCSI / FC, dm-multipath | `Common::BlockBase` |
| PowerMax | `dellpowermax` | FC / iSCSI, dm-multipath | `Common::BlockBase` |
| PowerFlex | `dellpowerflex` | SDC kernel module, `/dev/scini*` | own base |
| PowerScale | `dellpowerscale` | NFS, directory semantics | own base |

Why not one plugin with a `--dell-type` option:

- `plugindata()` is a class method. PVE calls it to learn the supported content
  types and disk formats *before* any `storage.cfg` parameter is parsed, so a
  block family and a NAS family cannot share one return value.
- PVE's JSON schema has no way to express "required only when family is X".
  A single type would have to declare the union of every family's options, and
  an invalid combination would only fail at runtime.
- The type string is a permanent contract: changing it later invalidates
  existing `storage.cfg` files.

The plugin type is always chosen explicitly by the operator at `pvesm add`
time. It is never probed from the array: `storage.cfg` is parsed constantly by
`pvestatd`, `pvedaemon`, `pveproxy`, `qm` and `pct`, including while the array
is unreachable, and a parse that depends on a REST call would take down the
whole node's storage list.

## Layers

```
DellPowerStorePlugin.pm            family specifics: type, plugindata, options
        |                          array operations expressed as abstract methods
        v
DellEMC::Common::BlockBase         everything array-independent:
                                   activate/deactivate, status, alloc/free,
                                   snapshots, device waiting, orphan reaping
        |
        +-- Common::REST           HTTP client: retries, timeouts, sessions
        +-- Common::ISCSI          initiator, portal login
        +-- Common::FC             HBA and WWPN discovery
        +-- Common::Multipath      SCSI device lifecycle, dm-multipath maps
        +-- Common::Naming         PVE object names <-> array object names
        +-- Common::WwidState      WWID tracking, orphan grace periods
        +-- Common::Health         status failure counters, capacity alerts
```

`PowerStore::API` extends `Common::REST` with PowerStore authentication and
endpoints; `PowerStore::Naming` narrows `Common::Naming` to PowerStore's name
length and character rules.

## Adding a family

1. Add `lib/PVE/Storage/Custom/DellEMC/<Family>/API.pm` extending
   `Common::REST`.
2. Add `lib/PVE/Storage/Custom/Dell<Family>Plugin.pm` extending
   `Common::BlockBase` for a block family, or `PVE::Storage::Plugin` directly
   for a family whose data path is not dm-multipath.
3. Implement every abstract `_array_*` method; declare family options with a
   dedicated prefix so they cannot collide with another plugin's schema.
4. No packaging change is needed — the Makefile discovers new modules.
