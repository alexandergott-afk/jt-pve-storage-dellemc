# Configuration Reference

繁體中文：[CONFIGURATION_zh-TW.md](CONFIGURATION_zh-TW.md)

Options shared by every Dell EMC block family use the `dell-` prefix.
PowerStore-specific options use `pstore-`. PVE registers storage properties in
one shared schema, so a name may only ever have one definition across all
plugins — that is why the prefixes exist.

## Common options

| Option | Type | Required | Default | Description |
|---|---|---|---|---|
| `dell-portal` | string | yes, fixed | — | Management IP or FQDN of the array. Cannot be changed after the storage is created |
| `dell-username` | string | yes | — | REST API user |
| `dell-password` | string | yes | — | REST API password |
| `dell-ssl-verify` | boolean | no | `0` | Verify the array's TLS certificate |
| `dell-protocol` | `iscsi` \| `fc` | no | `iscsi` | SAN protocol |
| `dell-host-mode` | `per-node` \| `shared` | no | `per-node` | One host object per node, or one for the cluster |
| `dell-cluster-name` | string | no | `pve` | Cluster name used in host object names |
| `dell-device-timeout` | 10–300 | no | `60` | Seconds to wait for a volume's device to appear |
| `dell-portal-probe-timeout` | 0–30 | no | `2` | TCP pre-check per iSCSI portal; 0 disables it |
| `dell-status-timeout` | 2–60 | no | `5` | REST timeout on the pvestatd health path |
| `dell-activate-deadline` | 0–300 | no | `30` | Wall-clock budget for the portal login loop; 0 disables it |
| `dell-rollback-any-snapshot` | boolean | no | `0` | Allow rolling back to a snapshot that is not the most recent one. Off because Dell does not document what a restore does to the snapshots taken after the one being restored; on an array that discards them PVE would keep listing restore points that no longer exist |
| `dell-config-backup` | boolean | no | `1` | Write the VM config to a 1 MB volume beside each snapshot. Costs one extra volume per snapshot of a VM, so turn it off on an array whose volume count is the binding limit. Ignored on PowerVault ME, which does not offer the feature |
| `dell-config-backup-timeout` | 5–60 | no | `15` | Device wait for the config backup volume |
| `dell-rescan-interval` | 0–3600 | no | `300` | Minimum seconds between periodic SAN rescans; 0 rescans every time |

## PowerStore options

| Option | Type | Required | Default | Description |
|---|---|---|---|---|
| `pstore-appliance` | string | no | — | Appliance for new volumes in a multi-appliance cluster. Unset lets PowerStore choose |
| `pstore-volume-group` | string | no | — | Put every volume in this volume group. Must already exist |
| `pstore-performance-policy` | `High` \| `Medium` \| `Low` | no | `Medium` | Performance policy for new volumes |
| `pstore-protection-policy` | string | no | — | Protection policy (snapshot and replication rules). Must already exist |
| `pstore-lun-id-base` | 1–200 | no | `1` | Lowest LUN id the plugin assigns |

## PowerVault ME options

Used by the `dellpowervault` type, which covers the ME4 and ME5 series.

| Option | Type | Required | Default | Description |
|---|---|---|---|---|
| `pvault-pool` | string | no | — | Pool new volumes are created in. Required on an array with more than one pool |
| `pvault-volume-group` | string | no | — | Put every volume in this volume group. Must already exist |
| `pvault-tier-affinity` | `no-affinity` \| `archive` \| `performance` | no | `no-affinity` | Tier affinity for new volumes |
| `pvault-lun-id-base` | 1–200 | no | `1` | Lowest LUN id the plugin assigns |

### Naming is the binding constraint on this family

PowerVault accepts **32 bytes** for a volume or snapshot name and does not
allow a dot in a volume name — both documented in the ME5 CLI Reference Guide.
The plugin therefore uses short names (`pve-me5-100-d0`) and gives the storage
id a **10-character budget**.

A storage id that does not leave room raises an error at creation time rather
than producing a truncated name that could collide with another VM's volume.
Keep the storage id short on this family.

## Standard PVE options

`nodes`, `disable`, `content`, `shared` — all optional. Use `content
images,rootdir` for VM disks and container root filesystems, and `shared 1` on
a cluster.

## Examples

`/etc/pve/storage.cfg`:

```
dellpowerstore: ps1
    dell-portal 192.168.1.50
    dell-username pveadmin
    dell-password SecurePassword
    dell-protocol iscsi
    dell-host-mode per-node
    dell-cluster-name mycluster
    pstore-volume-group pve-vg
    content images,rootdir
    shared 1
```

Fibre Channel, restricted to the nodes that are on the fabric:

```
dellpowerstore: ps-fc
    dell-portal 192.168.1.50
    dell-username pveadmin
    dell-password SecurePassword
    dell-protocol fc
    nodes node1,node2
    content images
    shared 1
```

## The options that matter under load

Most defaults can be left alone. These three are the ones worth understanding
before a storage misbehaves.

### `dell-status-timeout`

PVE polls every storage roughly every ten seconds, **sequentially**. A storage
that takes 30 seconds to answer does not just delay itself — it delays every
storage polled after it, and those show up as `inactive` in the GUI even
though nothing is wrong with them.

The health path therefore uses a short timeout and makes a **single attempt**.
Losing the retry costs nothing: the next poll is the retry. Raise this only if
the array's management network is genuinely slow, and expect the whole poll
cycle to slow with it.

### `dell-activate-deadline`

Per-portal timeouts bound each portal but not the loop over all of them. An
array publishing eight portals, three of which accept a TCP connection and
then never answer, can hold `activate_storage` for minutes.

Once the budget is spent **and at least one path is up**, the remaining
portals are deferred to a later activation and a warning names them. The
budget is never applied while zero paths are up: with no path, the storage
must fail honestly rather than report success.

### `dell-rescan-interval`

`activate_storage` runs on every poll. Rescanning the SAN unconditionally
means a host-wide `multipathd reconfigure` and a `udevadm trigger` six times a
minute on every node, which keeps device-mapper in flux exactly while a VM
start or a backup is trying to discover a device.

A rescan still happens **immediately** whenever this node logs in to a new
portal, so newly mapped volumes are not delayed. The interval only bounds the
periodic safety net for volumes mapped out of band.

## Host modes

`per-node` (default) registers one host object per PVE node, named
`pve-{cluster}-{node}`. Every volume is mapped to every node, so live
migration does not have to remap anything first, and the array can report
per-node connectivity.

`shared` registers one host group for the whole cluster. Fewer objects on the
array, but the array can no longer tell you which node a path belongs to.

## Verifying a configuration

```bash
pvesm status                     # capacity and whether it is active
pvesm list ps1                   # volumes PVE knows about
journalctl -t pvestatd | grep dellpowerstore    # what the plugin is saying
```
