# jt-pve-storage-dellemc

Dell EMC storage plugins for Proxmox VE.

**[繁體中文說明](README_zh-TW.md)**

One package, one shared host-side layer, and one PVE storage type per Dell EMC
product family. The first family implemented is **PowerStore** over iSCSI or
Fibre Channel, using direct volume provisioning (one VM disk = one array
volume) so that array-side snapshots, thin clones, compression and replication
all operate on a single VM disk as their natural unit.

---

## Project status

> **Version 0.2.0 — shared Common layer (Phase 1).**
> This package still registers **no** storage type. It contains the build
> system, packaging, safety tooling and the modules the family plugins will
> be built on. Do not deploy it expecting a working storage backend yet.

| Phase | Content | State |
|---|---|---|
| 0 | Skeleton: Makefile, `debian/`, CI, README | **done** |
| 1 | Common layer: Naming, REST, Multipath, ISCSI, FC, WwidState, Health | **done** |
| 2 | `Common::BlockBase` abstract plugin base | planned |
| 3 | PowerStore REST API client | planned |
| 4 | `dellpowerstore` plugin, docs, on-hardware iSCSI test pass | planned |
| 5 | FC verification, PVE 9.2 verification, 1.0.0 release | planned |
| 6+ | PowerMax / PowerFlex / PowerScale (separate specs) | not started |

The full development specification lives in
[`jt-pve-storage-dellemc.md`](jt-pve-storage-dellemc.md).

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

## Disclaimer

- This is an **independent, community project**. It is not affiliated with,
  endorsed by, or supported by Dell Technologies. "Dell", "Dell EMC",
  "PowerStore", "PowerMax", "PowerFlex" and "PowerScale" are trademarks of
  their respective owners.
- Provided under the MIT license, **without warranty of any kind**. You are
  responsible for validating it against your own hardware, firmware version
  and workload before production use.
- Items **not yet verified on physical hardware** are marked
  `NOT VERIFIED ON HARDWARE` in `docs/TESTING.md`. As of 0.1.0 that includes
  every array-facing behaviour: REST endpoint set and field names, the
  SCSI vendor/product strings used for multipath matching, and the
  WWN-to-WWID conversion.
- Always test on a non-production cluster and a non-production array first,
  and keep independent backups of any data you place on this storage.

---

## Requirements

| Item | Requirement |
|---|---|
| Proxmox VE | 9.1 or later (Storage API 13) |
| PowerStore OS | 3.0 or later (REST API v3); 4.x is the primary target |
| Perl modules | `libwww-perl`, `libjson-perl`, `liburi-perl` |
| System tools | `open-iscsi`, `multipath-tools`, `sg3-utils`, `psmisc` (`lsscsi` recommended) |

---

## Installation

Build from source:

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

Once Phase 4 lands, a PowerStore storage is added like this:

```bash
pvesm add dellpowerstore ps1 \
    --dell-portal 192.168.1.50 \
    --dell-username pveadmin \
    --dell-password 'SecurePassword' \
    --dell-protocol iscsi \
    --pstore-volume-group pve-vg \
    --content images,rootdir \
    --shared 1
```

Parameter reference: [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md).
First-time setup: [`docs/QUICKSTART.md`](docs/QUICKSTART.md).

---

## Known limitations

- **Full Clone does not use array-side cloning.** PVE implements a full clone
  as `alloc_image` plus a block-by-block `qemu-img` copy and never calls the
  plugin's `clone_image`. This is a PVE architectural decision, not a plugin
  defect. Use Linked Clone to get the array's thin clone.
- **Volumes cannot be shrunk.** Only growth is supported; a shrink request is
  rejected rather than silently truncating a guest filesystem.
- **The plugin only touches objects it owns.** Every list, delete and cleanup
  path filters on the `pve-<storeid>-` name prefix; anything else on the array
  is never read or modified.

---

## Documentation

| Document | Description |
|---|---|
| [`docs/QUICKSTART.md`](docs/QUICKSTART.md) | First storage in a few minutes |
| [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md) | Every `storage.cfg` parameter |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Multi-family architecture, how to add a family |
| [`docs/NAMING_CONVENTIONS.md`](docs/NAMING_CONVENTIONS.md) | PVE object to array object naming |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | Symptoms, causes, recovery |
| [`docs/TESTING.md`](docs/TESTING.md) | Test matrix and hardware verification status |

---

## Related projects

- [jt-pve-storage-purestorage](https://github.com/jasoncheng7115/jt-pve-storage-purestorage)
- [jt-pve-storage-netapp](https://github.com/jasoncheng7115/jt-pve-storage-netapp)

## License

MIT — see [LICENSE](LICENSE).

## Author

Jason Cheng (Jason Tools) &lt;jason@jason.tools&gt;
