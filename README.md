# jt-pve-storage-dellemc

Dell EMC storage plugins for Proxmox VE.

**[Documentation site](https://jasoncheng7115.github.io/jt-pve-storage-dellemc/)** &middot; **[繁體中文說明](README_zh-TW.md)**

> ## ⚠️ BETA SOFTWARE — READ BEFORE INSTALLING
>
> **This is a beta release (0.7.36~beta1). It has never been run against a
> physical Dell EMC array.** Every array-facing behaviour is unverified: the
> REST endpoints and field names, the SCSI vendor and product strings that
> decide which devices the plugin will touch, the WWN to WWID conversion, and
> the entire Fibre Channel path.
>
> **Do not install this on a production cluster or point it at an array
> holding data you care about.** A storage plugin runs as root, creates and
> deletes volumes on the array, and manipulates block devices on every node.
> A defect here can destroy virtual machine data, take a storage offline, or
> leave a node in a state that only a reboot clears — and because multipath
> and SCSI state is shared, the damage is not necessarily limited to this
> plugin's own storage.
>
> Use a test cluster, a test array, and independent backups of anything you
> put on it. See [Disclaimer and risk](#disclaimer-and-risk) below and
> [docs/TESTING.md](docs/TESTING.md) for exactly what has and has not been
> verified.

One package, one shared host-side layer, and one PVE storage type per Dell EMC
product family. The first family implemented is **PowerStore** over iSCSI or
Fibre Channel, using direct volume provisioning (one VM disk = one array
volume) so that array-side snapshots, thin clones, compression and replication
all operate on a single VM disk as their natural unit.

---

## Project status

> **Version 0.7.36~beta1 — three storage types are code complete, and
> has NOT been run against a PowerStore array.**
> Every array-facing detail — REST paths and field names, the SCSI vendor and
> product strings, the WWN to WWID conversion — is still unverified, so this
> is a release to test with, on a non-production cluster and a non-production
> array. 1.0.0 is the on-hardware test pass, not more code.

| Phase | Content | State |
|---|---|---|
| 0 | Skeleton: Makefile, `debian/`, CI, README | **done** |
| 1 | Common layer: Naming, REST, Multipath, ISCSI, FC, WwidState, Health | **done** |
| 2 | `Common::BlockBase` abstract plugin base | **done** |
| 3 | PowerStore REST API client | **done** |
| 4 | `dellpowerstore` plugin, recovery tool, docs | **code done**, on-hardware pass outstanding |
| 5 | FC verification, PVE 9.2 verification, 1.0.0 release | needs hardware |
| 6 | `dellpowervault` plugin for PowerVault ME4/ME5 | **code done**, on-hardware pass outstanding |
| 7 | `dellpowerflex` plugin, NVMe/TCP and SDC | **code done**, on-hardware pass outstanding |
| 8+ | PowerMax | not started |

## Product families

Dell EMC's product lines differ too much to share one PVE storage type, so
each family gets its own — see [ARCHITECTURE.md](docs/ARCHITECTURE.md) for
why. They share the host-side layer, so adding a family is a plugin file and
an API client, not a restructuring.

| Order | Family | PVE storage type | Data path | Status |
|---|---|---|---|---|
| 1 | **PowerStore** | `dellpowerstore` | iSCSI / FC (dm-multipath) | **in development** |
| 2 | **PowerVault ME4/ME5** | `dellpowervault` | iSCSI / FC / SAS (dm-multipath) | **in development** |
| 3 | **PowerFlex** | `dellpowerflex` | NVMe/TCP or SDC | **in development** |
| 4 | PowerMax | `dellpowermax` | FC / iSCSI (dm-multipath), NVMe/FC and NVMe/TCP (NVMe-oF) | planned |
| — | PowerScale | `dellpowerscale` | NFS (directory semantics) | not scheduled |
| — | Unity XT | `dellunity` | iSCSI / FC | not scheduled |
| — | ObjectScale, PowerProtect | — | — | out of scope |

PowerStore, PowerVault ME and PowerMax share the block base class. PowerFlex
does not: its volumes arrive through the SDC kernel module or an NVMe/TCP
namespace, with no SAN login and no dm-multipath.

PowerScale is not scheduled. It is NAS, so it would need its own directory
semantics and content types rather than the block layer everything else here
shares — Proxmox VE's built-in NFS storage already covers most of what it
would offer.

Object and backup-appliance products are out of scope on purpose: they do not
fit the PVE storage plugin model.

---

## CRITICAL: Multipath safety rules

These rules are not stylistic. Breaking any of them can take a whole node —
including storage that has nothing to do with this plugin — out of service.

1. **NEVER run `multipath -F` (capital F).** It flushes every unused multipath
   map on the node, system-wide. On a mixed-storage node this disconnects any
   map that happens to be idle at that moment, including maps from other
   vendors and other plugins. Always flush exactly one map:
   `multipath -f /dev/mapper/<wwid>` (lowercase `f`).
   The build fails if a capital-F flush appears anywhere in this repository —
   see `make check-multipath-flush`.

2. **Use `systemctl restart multipathd`, never `systemctl reload multipathd`.**
   Reload only re-reads the configuration file; restart is what actually
   reapplies device-mapper state.

3. **Avoid `no_path_retry queue` and `dev_loss_tmo infinity`.** With stale
   device residue present, queued I/O that can never complete puts PVE daemons
   into uninterruptible sleep (D state), which no signal can clear — the node
   has to be rebooted. Use `no_path_retry 30`, `fast_io_fail_tmo 5`,
   `dev_loss_tmo 60`.

4. **The plugin never rewrites a multipath configuration file it did not
   create.** Its own drop-in carries a version marker; a file without that
   marker is treated as operator-owned and left untouched.

5. **Install the package on every node of the cluster.** A node missing the
   plugin fails with `Parameter verification failed (400)` or
   `No such storage` for Dell EMC storages, and live migration to that node
   will not work.

---

## Disclaimer and risk

### Development status

This is **beta software**, published so that it can be tested. It has not
been run against a physical Dell EMC array even once. Everything marked
`NOT VERIFIED ON HARDWARE` in [docs/TESTING.md](docs/TESTING.md) — which is
currently every array-facing behaviour — may simply be wrong.

### What can go wrong

A Proxmox VE storage plugin runs as root on every node. This one creates and
deletes volumes on the array, maps them to hosts, and manipulates SCSI and
device-mapper state. Realistic failure modes include:

- **Data loss.** A volume deleted, overwritten by a rollback, or truncated by
  a wrong size calculation takes the virtual machine's data with it.
- **Storage outage.** A defect on the activation or status path can leave a
  storage `inactive`, and because Proxmox VE polls storages sequentially, a
  slow or hanging one delays every other storage on the node.
- **Node hangs.** I/O to a device with no working path can put processes into
  uninterruptible sleep, which no signal clears. Recovery is a reboot.
- **Collateral damage.** Multipath and SCSI state is shared across the whole
  node. A mistake in device cleanup can affect storage this plugin does not
  own, from other vendors or other plugins.

The design takes these seriously — the safety rules above, the vendor gating,
the timeout-bounded device access and the ownership prefix all exist for
them — but *designed to be safe* is not *demonstrated to be safe*. That
demonstration is what 1.0.0 requires.

### No warranty

Provided under the [MIT license](LICENSE), **as is and without warranty of
any kind**, express or implied, including but not limited to merchantability,
fitness for a particular purpose and non-infringement. In no event shall the
author be liable for any claim, damages or other liability, including data
loss or business interruption, arising from the use of this software.

You are solely responsible for evaluating it against your own hardware,
firmware version and workload before any production use.

### Before you install

- Use a **non-production** Proxmox VE cluster and a **non-production** array.
- Keep **independent backups** of anything you place on this storage. A
  storage snapshot is not a backup.
- Read [docs/TESTING.md](docs/TESTING.md) and verify at least the four items
  listed there for your array and firmware.
- Report what you find:
  [issues](https://github.com/jasoncheng7115/jt-pve-storage-dellemc/issues).

### Trademarks and affiliation

This is an **independent community project**. It is not affiliated with,
endorsed by, sponsored by, or supported by Dell Technologies. "Dell",
"Dell EMC", "PowerStore", "PowerMax", "PowerFlex", "PowerScale", "Unity" and
"PowerVault" are trademarks of their respective owners, used here only to
identify the hardware this software talks to. Proxmox and Proxmox VE are
trademarks of Proxmox Server Solutions GmbH.

---

## Requirements

| Item | Requirement |
|---|---|
| Proxmox VE | 9.1 or later (Storage API 13) |
| PowerStore OS | 3.0 or later (REST API v3); 4.x is the primary target |
| Perl modules | `libwww-perl`, `liblwp-protocol-https-perl`, `libjson-perl`, `liburi-perl` |
| System tools | `open-iscsi`, `multipath-tools`, `sg3-utils`, `psmisc` (`lsscsi` recommended) |

---

## Installation

### Download a package

Prebuilt `.deb` packages are attached to each
[release](https://github.com/jasoncheng7115/jt-pve-storage-dellemc/releases).
Verify the download against the `SHA256SUMS` file published beside it.

```bash
apt install ./jt-pve-storage-dellemc_<version>_all.deb
```

### Or build from source

```bash
make test            # perl -c on every module + multipath safety guard
make deb             # produces ../jt-pve-storage-dellemc_<version>_all.deb
```

Install on **every** node:

```bash
apt install ./jt-pve-storage-dellemc_<version>_all.deb
```

Use `apt install ./file.deb`, not `dpkg -i`: `dpkg -i` does not pull in
dependencies, and the missing binaries only surface later as failures deep
inside the plugin.

After an upgrade, run `systemctl restart pvestatd` on every node — a reload
does not reliably replace already-loaded Perl modules.

---

## Configuration

### PowerStore

```bash
pvesm add dellpowerstore ps1 \
    --dell-portal 192.168.1.50 \
    --dell-username pveadmin \
    --dell-password 'SecurePassword' \
    --dell-protocol iscsi \
    --content images,rootdir \
    --shared 1
```

Add `--pstore-appliance` on a multi-appliance cluster, `--pstore-volume-group`
to keep every volume in one group, and `--dell-protocol fc` for Fibre Channel.

### PowerVault ME4 / ME5

```bash
pvesm add dellpowervault me5 \
    --dell-portal 192.168.1.60 \
    --dell-username manage \
    --dell-password 'SecurePassword' \
    --pvault-pool A \
    --content images,rootdir \
    --shared 1
```

`--pvault-pool` is required on an array with more than one pool. Keep the
storage id short: this family limits names to 32 bytes, and a name that would
not fit is refused rather than truncated.

### PowerFlex

```bash
pvesm add dellpowerflex pflex1 \
    --dell-portal 192.168.1.70 \
    --dell-username admin \
    --dell-password 'SecurePassword' \
    --dell-protocol nvme \
    --pflex-storage-pool pool1 \
    --content images,rootdir \
    --shared 1
```

`--pflex-storage-pool` is required. `--dell-protocol nvme` (the default) uses
NVMe/TCP with the in-kernel initiator; `sdc` uses Dell's kernel module, which
you must install yourself — read
[docs/POWERFLEX_SDC.md](docs/POWERFLEX_SDC.md) before choosing it.

Parameter reference: [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md).
First-time setup: [`docs/QUICKSTART.md`](docs/QUICKSTART.md).

---

## Known limitations

- **Full Clone does not use array-side cloning.** PVE implements a full clone
  as `alloc_image` plus a block-by-block `qemu-img` copy and never calls the
  plugin's `clone_image`. This is a PVE architectural decision, not a plugin
  defect. Use Linked Clone to get the array's thin clone.
- **Rollback is limited to the most recent snapshot.** Dell's manuals
  describe what restoring a volume from a snapshot does to the volume and
  say nothing about the snapshots taken after the one being restored. On an
  array that discards them, PVE would carry on listing restore points that
  no longer exist, and nobody would find out until the day one was needed.
  So a rollback that is not to the newest snapshot is refused, and PVE is
  told which snapshots are in the way. Delete them first, or — if you have
  verified the behaviour on your own array — set `dell-rollback-any-snapshot 1`.
- **Volumes cannot be shrunk.** Only growth is supported; a shrink request is
  rejected rather than silently truncating a guest filesystem.
- **The VM config backup volume is not offered on PowerVault ME.** On
  PowerStore, every snapshot of a VM also writes that VM's configuration to a
  1 MB volume, so `pve-dell-config-get` can recover it when `/etc/pve` is
  gone. That costs one extra volume per snapshot, and an ME array's volume and
  snapshot ceiling is roughly an order of magnitude lower than PowerStore's —
  low enough that the cost is the difference between running out of volumes
  and not. So the feature is simply absent on `dellpowervault`; snapshots and
  rollback are unaffected, and the configuration is still recoverable from a
  PVE backup or from `/etc/pve` on another node. On PowerStore it is on by
  default and can be turned off with `dell-config-backup 0`.
- **The plugin only touches objects it owns.** Every list, delete and cleanup
  path filters on the `pve-<storeid>-` name prefix; anything else on the array
  is never read or modified.

---

## Documentation

| Document | Description |
|---|---|
| [`docs/FIRST_RUN.md`](docs/FIRST_RUN.md) | **The first run on real hardware**: the order to do it in, what to check after each step, and what each failure means |
| [`docs/QUICKSTART.md`](docs/QUICKSTART.md) | First storage in a few minutes |
| [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md) | Every `storage.cfg` parameter |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Multi-family architecture, how to add a family |
| [`docs/NAMING_CONVENTIONS.md`](docs/NAMING_CONVENTIONS.md) | PVE object to array object naming |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | Symptoms, causes, recovery |
| [`docs/TESTING.md`](docs/TESTING.md) | Test matrix and hardware verification status |
| [`docs/RELEASE_TESTING.md`](docs/RELEASE_TESTING.md) | What is tested before every release |
| [`docs/POWERFLEX_SDC.md`](docs/POWERFLEX_SDC.md) | PowerFlex host access: SDC vs NVMe/TCP, and Dell's support matrix |

---

## Related projects

- [jt-pve-storage-purestorage](https://github.com/jasoncheng7115/jt-pve-storage-purestorage)
- [jt-pve-storage-netapp](https://github.com/jasoncheng7115/jt-pve-storage-netapp)

## License

MIT — see [LICENSE](LICENSE).

## Author

Jason Cheng (Jason Tools) &lt;jason@jason.tools&gt;
