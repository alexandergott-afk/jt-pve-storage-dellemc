# Architecture

繁體中文：[ARCHITECTURE_zh-TW.md](ARCHITECTURE_zh-TW.md)

## One repository, one storage type per family

Dell EMC's product lines differ too much to share a single PVE storage type,
so each family gets its own and they share the host-side layer.

| Order | Family | PVE type | Data path | Base class |
|---|---|---|---|---|
| 1 | PowerStore | `dellpowerstore` | iSCSI / FC, dm-multipath | `Common::BlockBase` |
| 2 | PowerVault ME5 | `dellme5` | iSCSI / FC / SAS, dm-multipath | `Common::BlockBase` |
| 3 | PowerFlex | `dellpowerflex` | SDC kernel module, `/dev/scini*` | its own |
| 4 | PowerMax | `dellpowermax` | FC / iSCSI, dm-multipath | `Common::BlockBase` |

PowerScale and Unity XT are not scheduled. PowerScale is NAS, and Proxmox
VE's built-in NFS storage already covers most of what a dedicated plugin
would add.

Why not one plugin with a `--dell-type` option:

- **`plugindata()` is a class method.** PVE calls it to learn the supported
  content types and disk formats *before* any `storage.cfg` parameter is
  parsed. PowerStore is block storage that can only hold `raw`; a NAS family
  such as PowerScale holds `qcow2`, `subvol`, ISOs and backups. There is no
  single return value that describes both, and the same applies to PowerFlex,
  whose volumes appear through a kernel module rather than a SAN login.
- **The schema cannot express "required only when …".** PVE's JSON schema has
  `optional` and nothing else. A single type would have to declare the union
  of every family's options, and an invalid combination would only fail at
  runtime, on the array, halfway through an operation.
- **The type string is a permanent contract.** Changing it later invalidates
  every existing `storage.cfg`.

The type is always chosen explicitly at `pvesm add` time and is never probed
from the array. `storage.cfg` is parsed constantly by pvestatd, pvedaemon,
pveproxy, `qm` and `pct`, including while the array is unreachable; a parse
that depended on a REST call would take out the whole node's storage list.

Probing is fine *after* `activate_storage`, where a failure can degrade
gracefully: firmware version, whether NVMe-TCP is available, licensed
features, the appliance model.

## Layers

```
DellPowerStorePlugin.pm          family specifics: type, schema, and the
        |                        _array_* methods, expressed as REST calls
        v
DellEMC::Common::BlockBase       everything array-independent:
                                 activation, allocation, device discovery and
                                 teardown, snapshots, templates, clones, the
                                 multipath drop-in, the orphan reaper
        |
        +-- Common::REST         HTTP transport: retries, timeouts, sessions
        +-- Common::ISCSI        initiator, portal probing, session rescan
        +-- Common::FC           HBA discovery, WWN normalisation
        +-- Common::Multipath    SCSI device lifecycle, dm-multipath maps
        +-- Common::Naming       PVE names <-> array object names
        +-- Common::WwidState    WWID tracking, orphan grace periods
        +-- Common::Health       status failure counters, capacity alerts
```

`PowerStore::API` extends `Common::REST` with PowerStore's authentication and
endpoints. `PowerStore::Naming` extends `Common::Naming` with PowerStore's
name limits.

## The BlockBase contract

A block family implements these and inherits everything else. Each one dies
with the name of the class that failed to implement it, and `t/08` asserts
that none is left inherited.

```
type                    the PVE storage type string
multipath_vendor        SCSI vendor string, which gates every device the
multipath_product       plugin will touch
multipath_defaults      the family's multipath device settings

_array_ping             cheap reachability check for the health path
_array_get_capacity     ($total, $used, $avail) in bytes

_array_get_volume       _array_list_volumes    _array_create_volume
_array_delete_volume    _array_resize_volume   _array_rename_volume
_array_get_wwid

_array_snapshot_create  _array_snapshot_get    _array_snapshot_delete
_array_snapshot_list    _array_snapshot_rollback
_array_clone

_array_ensure_host      _array_list_hosts
_array_map_to_host      _array_unmap_from_host
_array_is_mapped        _array_mapped_hosts

_array_get_portals      iSCSI portals, [{ portal, iqn }]
```

Optional overrides: `naming`, `family_properties`, `family_options`,
`identity_suffix`, `capacity_scope`, `multipath_config_version`,
`_array_list_base_snapshots`.

## Property declaration

PVE merges every registered plugin's `properties()` into one schema and
**dies** with `duplicate property` if two plugins declare the same name — see
`PVE::SectionConfig::init`. That failure is not scoped to the offending
plugin; it happens while PVE builds the storage schema, so every storage on
the node stops working.

The shared `dell-*` options are therefore declared by whichever family class
PVE asks first, and the others declare only their own. Adding a family
requires no change to this mechanism, and `t/06` covers it.

## Adding a family

1. `lib/PVE/Storage/Custom/DellEMC/<Family>/API.pm`, extending
   `Common::REST`.
2. `lib/PVE/Storage/Custom/Dell<Family>Plugin.pm`, extending
   `Common::BlockBase` for a block family, or `PVE::Storage::Plugin` directly
   for one whose data path is not dm-multipath.
3. Implement the abstract methods above and declare family options with a
   dedicated prefix.
4. Nothing else. The Makefile discovers new modules and packaging follows.

ME5 and PowerMax will inherit `BlockBase` — they are the case it was written
for. PowerFlex will not: its data path is a kernel module presenting
`/dev/scini*`, with no SAN login and no dm-multipath, so only the REST
transport is reusable.

## Why the plugin is careful about the host

Three failure modes drove most of the design, and all three are inherited
lessons from the Pure Storage and NetApp plugins rather than theory:

1. **Uninterruptible sleep.** Reading an unresponsive device puts a process
   into D state, which no signal clears. Every sysfs access here runs in a
   forked, timeout-bounded child, and every command under an alarm.
2. **Blast radius.** The system-wide flush `multipath -F` is never issued —
   it would remove every unused map on the node — and neither is a LIP, which
   disrupts every LUN behind an HBA port. Destructive operations are
   vendor-gated and act on one object at a time.
3. **The sequential poll.** PVE polls storages one after another, so a slow
   array starves its neighbours. The health path uses a short timeout and a
   single attempt, and the expensive periodic work is rate-limited and pushed
   into a detached background pass.
