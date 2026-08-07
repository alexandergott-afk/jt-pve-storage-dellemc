# Configuration Reference

繁體中文：[CONFIGURATION_zh-TW.md](CONFIGURATION_zh-TW.md)

Options shared by every Dell EMC block family use the `dell-` prefix.
PowerStore-specific options use `pstore-`. PVE registers storage properties in
one shared schema, so a name may only ever have one definition across all
plugins — that is why the prefixes exist.

## Common options

| Option | Type | Required | Default | Description |
|---|---|---|---|---|
| `dell-portal` | string | yes, fixed | — | Management address(es); **cannot be changed after the storage is created**, so list both controllers up front on an array whose controllers each have their own management IP and no floating address (PowerVault ME, Unity): `192.168.1.11,192.168.1.12`. On a controller failover the client moves to the next address by itself. The data path needs nothing — dm-multipath handles it |
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

## Management-address failover: which arrays need the comma

Arrays differ in how their management interface survives a controller
failure, and it decides how to fill in `dell-portal`:

| Array | Management model | What to put in `dell-portal` |
|---|---|---|
| **PowerVault ME4/ME5** | one fixed IP **per controller** (A and B), no virtual address. Both management controllers answer at all times, but a failed controller's IP disappears **with it** — nothing floats to the survivor | **both controllers, comma-separated**: `192.168.1.11,192.168.1.12` |
| PowerStore | a floating cluster management IP | the cluster IP alone is enough |
| Unity XT | **one floating management IP by design** — it follows the master SP, so a SP failover keeps the same address (management pauses for the minutes the failover takes) | the system management IP alone is enough; the comma form is accepted but not needed |
| PowerFlex | PowerFlex Manager / gateway VIP | the VIP |

This is the client-side equivalent of what a NetApp cluster-management LIF
or a Pure `vir0` does on the array side: PowerVault simply has no such
thing, so the plugin does the moving instead. On a connection failure it
steps to the next address, re-authenticates (a session belongs to the
controller that issued it), and stays on the address that answers.

Three things to know:

- **`dell-portal` cannot be changed after the storage is created.** On an
  ME, list both controllers at `pvesm add` time — during an incident it is
  too late.
- **The data path needs none of this.** FC and iSCSI reach both controllers
  at all times; dm-multipath and ALUA handle a controller failover on their
  own, and running guests never notice. This section is only about
  management: status, allocation, snapshots, deletion.
- **The cost is bounded.** With every address dead, `pvesm status` pays one
  short timeout per address (measured: 4.0 s at `dell-status-timeout 2` with
  two addresses) and other storages are not delayed.

To see an ME's two addresses on the array itself: `show network-parameters`.

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


## Unity XT (`dellunity`)

| Option | Type | Required | Default | Meaning |
|---|---|---|---|---|
| `unity-pool` | string | no | — | Pool new LUNs are created in. Required on an array with more than one pool |
| `unity-thin` | boolean | no | `1` | Create thin LUNs. Thin provisioning must be licensed on the array |

```bash
pvesm add dellunity unity480 \
    --dell-portal 10.0.0.10 \
    --dell-username admin --dell-password '...' \
    --dell-protocol fc \
    --unity-pool pool_1 \
    --content images,rootdir
```

### What is different about this family

**Nothing here has been run against a Unity array.** See
[TESTING.md](TESTING.md) for what that means item by item.

- **The array is asked for a LUN by name**, at
  `/instances/lun/name:<name>`, rather than with a server-side filter. Every
  other family here needs a filter, and an unverified filter that returns
  nothing is indistinguishable from "there is nothing there".
- **Host access replaces rather than adds.** Unity's `hostAccess` is the
  whole list of hosts that may see a LUN, so mapping this node reads the
  current list and sends the union. That is why a mapping operation makes two
  round trips rather than one.
- **A linked clone is a thin clone of a snapshot**, so a template's marker
  snapshot outlives its clones and the array refuses to delete a template
  while one exists.
- **`unity-thin` needs a licence.** If thin provisioning is not licensed on
  the array, set it to `0`; the array refuses the create otherwise.

## PowerFlex options

Used by the `dellpowerflex` type. PowerFlex does not reach the host as a SCSI
LUN, so none of the multipath options apply here; `dell-protocol` takes
`nvme` (the default) or `sdc` instead of `iscsi` or `fc`.

| Option | Type | Required | Default | Description |
|---|---|---|---|---|
| `pflex-storage-pool` | string | **yes** | — | Storage pool new volumes are created in. PowerFlex has no default pool |
| `pflex-protection-domain` | string | no | — | Protection domain of that pool. Only needed when the same pool name exists in more than one domain |
| `pflex-nvme-ctrl-loss-tmo` | 0–600 | no | `60` | Seconds the kernel keeps retrying a lost NVMe controller before it fails the I/O. This is the NVMe equivalent of `no_path_retry`; the kernel's own default of 600 is long enough to be indistinguishable from a hang |
| `pflex-nvme-io-queues` | 1–128 | no | — | NVMe/TCP I/O queues per controller. Unset lets the kernel decide, which is normally one per CPU |
| `pflex-thick` | boolean | no | `0` | Create thick-provisioned volumes. Thin is the default and is what makes snapshots and clones cheap |

### Sizes and names on this family

PowerFlex allocates in **8 GiB** units, so a smaller request is rounded up to
one. Volume and snapshot names are limited to **31 characters** — one fewer
than PowerVault — which gives the storage id a **9-character budget**.

### Which data path

`dell-protocol nvme` uses the in-kernel NVMe/TCP initiator against the array's
SDT components and needs nothing proprietary on the host. `dell-protocol sdc`
uses Dell's SDC kernel module, which has to match the running kernel; Proxmox
VE kernels are not on Dell's support matrix, so a kernel upgrade can leave a
node without storage. See [POWERFLEX_SDC.md](POWERFLEX_SDC.md).

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

## Host objects the array already has

An array usually has a host object for each node before this plugin ever runs
— built by whoever zoned the fabric — holding that node's WWPNs or IQN under a
name of its own. An initiator can belong to only one host object, so the
plugin cannot simply create its own beside it.

It does not have to. On PowerStore, when there is no host under the name this
plugin uses (`pve-<cluster>-<node>`), it looks for one that already holds this
node's initiators and uses that instead, recording the name locally so every
later mapping goes to the same object. Nothing is renamed, nothing is removed,
and no initiator is moved.

It adopts only a host whose initiators are a **subset of this node's**. One
that also carries another host's ports is a shared or foreign object, and a
volume mapped to it would be visible to whatever else is in it — so the plugin
refuses and says which port made it refuse. Ports split across two host
objects are refused as well: a node is one host object.

One consequence worth knowing. Volumes are pre-mapped to the other nodes'
hosts by searching for the `pve-<cluster>-` prefix, so a node whose host was
adopted under a different name is not pre-mapped from elsewhere. It maps
itself when it activates the storage, which is what happens before a migration
completes, so nothing breaks — the mapping simply happens a moment later.
