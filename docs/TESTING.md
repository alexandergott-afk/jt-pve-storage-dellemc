# Testing and Hardware Verification Status

繁體中文：[TESTING_zh-TW.md](TESTING_zh-TW.md)

## Hardware verification status

**Nothing in this project has been run against a physical PowerStore.**

Everything below is `NOT VERIFIED ON HARDWARE` until it has been executed on a
real array and the result recorded here together with the PowerStore OS
version it was observed on.

| Item | Where | Status |
|---|---|---|
| REST endpoint paths | `PowerStore/API.pm` | NOT VERIFIED ON HARDWARE |
| Response field names (`size`, `wwn`, `logical_used`, `protection_data`) | `PowerStore/API.pm` | NOT VERIFIED ON HARDWARE |
| Filter syntax (`eq.`, `ilike.`, `cs.{...}`, `->>`) | `PowerStore/API.pm` | NOT VERIFIED ON HARDWARE |
| Authentication (`login_session`, `DELL-EMC-TOKEN`) | `PowerStore/API.pm` | NOT VERIFIED ON HARDWARE |
| Capacity source (`space_metrics_by_cluster`) | `PowerStore/API.pm` | NOT VERIFIED ON HARDWARE |
| SCSI vendor / product strings for multipath | `DellPowerStorePlugin.pm` | NOT VERIFIED ON HARDWARE |
| WWN to multipath WWID conversion | `PowerStore/API.pm` | NOT VERIFIED ON HARDWARE |
| Volume name length and character limits | `PowerStore/Naming.pm` | NOT VERIFIED ON HARDWARE |
| LUN id assignment behaviour | `PowerStore/API.pm` | NOT VERIFIED ON HARDWARE |
| Multipath device settings | `DellPowerStorePlugin.pm` | NOT VERIFIED ON HARDWARE |
| Fibre Channel data path | everywhere | NOT VERIFIED ON HARDWARE |
| WWPN spelling in a host object (bare hex vs colon-separated) | `DellPowerStorePlugin.pm`, `DellPowerVaultPlugin.pm` | NOT VERIFIED ON HARDWARE |
| Thin-clone parent field used to report linked clones (`protection_data.source_id`, `ancestorVolumeId`) | `DellPowerStorePlugin.pm`, `DellPowerFlexPlugin.pm` | NOT VERIFIED ON HARDWARE |
| NVMe-TCP | — | out of scope for 1.0 |

### Verifying the four that matter most

Do these first on any array this plugin is pointed at. Each one is cheap, and
each one is a silent failure if it is wrong.

```bash
# 1. Endpoints and field names: the array documents itself
#    https://<mgmt-ip>/swaggerui

# 2. The SCSI vendor and product strings, which decide which devices the
#    plugin will ever touch
sg_inq /dev/sdX | head -5
multipathd show config | grep -A3 -i dell

# 3. WWN to WWID. The array reports naa.68ccf098...; this must match.
/lib/udev/scsi_id -g -u /dev/sdX

# 4. Whether LUN ids stay low over time
#    PowerStore Manager > Compute > Host Information > <host> > Mapped Volumes
```

## PowerVault ME (dellpowervault)

The ME4 and ME5 series expose the CLI over HTTPS rather than a REST object
model. What follows is split by provenance, because that distinction decides
where to look first when something does not work.

### Taken from the official Dell documentation

Read from the *Dell PowerVault ME5 Series Storage System CLI Reference Guide*
during development. Still unverified against hardware, but not guesswork:

| Item | Source |
|---|---|
| `GET /api/login/<sha256("user_password")>`, lowercase hex | Using a script to access the CLI |
| HTTP Basic alternative at `GET /api/login`; SHA-256 is not compatible with LDAP accounts | same |
| Headers `sessionKey` and `dataType: json` | same |
| 30-minute session inactivity timeout | same |
| Command URL form `https://<ip>/api/<verb>/<object>/<args>` | same |
| Response carries a `status` array with `response-type`, `response`, `return-code` | Using JSON API output |
| `create volume [pool] [volume-group] size <n>[B\|GiB\|…] <name>` | create volume |
| Volume names: max 32 bytes, may not contain `" , . < \` | create volume |
| Sizes align to 4 MiB and are rounded **down** by the array | create volume, expand volume |
| `expand volume size <amount> <volume>` — the amount is **additive** | expand volume |
| Shrinking is not supported | expand volume |
| `map volume [access rw] initiator <hosts> [lun <n>] <volumes>`; a LUN is required when an initiator is named | map volume |
| `show volumes [details] [pattern <string>] [pool <pool>] [type …]` | show volumes |
| `create snapshots volumes <volumes> <snap-names>`; snapshot names max 32 bytes, unique system-wide | create snapshots |

### NOT VERIFIED — check these first

Dell's documentation site refused several requests during development, so
these follow the same CLI grammar but were not read from the guide. They are
marked `NOT VERIFIED` in `PowerVault/API.pm`:

| Item | Where |
|---|---|
| `delete volumes <name>` | `volume_delete` |
| `delete snapshot <name>` | `snapshot_delete` |
| `set volume name <new> <volume>` | `volume_rename` |
| `rollback volume <volume> snapshot <snapshot>` | `snapshot_rollback` |
| `unmap volume initiator <host> <volume>` | `volume_unmap` |
| `create host id <ids> <name>` and `set initiator host <name> <id>` | `host_create`, `host_add_initiators` |
| Field names of `show pools`, `show maps`, `show ports`, `show snapshots` | capacity, mappings, portals |
| SCSI vendor and product strings (`DellEMC` / `ME[45]…`) | `DellPowerVaultPlugin` |
| WWN to WWID conversion | `wwn_to_wwid` |

Verify the grammar of any of these in one command:

```bash
# on the array's own CLI, over SSH
help delete volumes
help unmap volume
help create host
```


## Automated checks

```bash
make syntax                  # perl -c on every module and script
make unit                    # t/*.t
make check-multipath-flush   # fails on any system-wide multipath flush
make test                    # all of the above
```

867 unit tests currently run without an array or a device. They cover naming
and the ownership gate, the REST retry policy, the reap guards, request shape
against fixtures, and the plugin's PVE schema. Tests that need
`PVE::Storage::Plugin` skip themselves on a machine without Proxmox VE.

What the unit tests cannot tell you: whether the endpoints exist, whether the
field names are right, or whether a device ever appears. That is what the
matrix below is for.

## Manual test matrix

Run on a cluster of at least three nodes with a real array. Record the result
and the PowerStore OS version in the Result column.

| # | Test | Precondition | Pass criteria | Result |
|---|---|---|---|---|
| 1 | Package install | clean node | `apt install ./deb` resolves dependencies, postinst reports no error | — |
| 2 | Cluster-wide install | 3 nodes | `pvesm status` agrees on every node | — |
| 3 | `pvesm add` validation | — | a missing required option is rejected | — |
| 4 | Capacity reporting | — | matches PowerStore Manager within 1% | — |
| 5 | Array unreachable | management network pulled | storage goes `inactive` within ~5s, sibling storages unaffected | — |
| 6 | Create a VM disk | — | volume on the array, multipath device on the node | — |
| 7 | Online grow | VM running | guest sees the new size after a rescan | — |
| 8 | Shrink | — | refused, with both sizes named | — |
| 9 | Delete a disk | VM stopped | volume gone, no device or map left behind | — |
| 10 | Delete an in-use disk | VM running | refused, with the reason | — |
| 11 | Snapshot create/list/delete | — | array snapshot matches | — |
| 12 | Snapshot rollback | VM stopped | data restored, no stale cache | — |
| 13 | RAM snapshot (vmstate) | VM running | state volume created, VM resumes correctly | — |
| 14 | Config backup + `pve-dell-config-get` | PowerStore | configuration is readable back; no config volume is created on PowerVault ME | — |
| 15 | Template + linked clone | — | clone is instant | — |
| 16 | Delete a template with clones | — | refused, dependants named | — |
| 17 | Full clone | — | completes via qemu-img | — |
| 18 | LXC container rootfs | — | creates and starts | — |
| 19 | EFI disk, TPM state, cloud-init | — | each is created | — |
| 20 | Live migration | 2 nodes | completes with no I/O interruption | — |
| 21 | Single path failure | pull one iSCSI link | I/O continues, multipath shows the failed path | — |
| 22 | Node reboot | — | logs in and devices reappear automatically | — |
| 23 | Orphan reaper | delete a volume from another node | the stale device is removed after the grace period, others untouched | — |
| 24 | LUN id growth | 300 attach/detach cycles | ids stay low and dense | — |
| 25 | Fibre Channel | FC fabric | items 1–24 repeated | — |
| 26 | PVE 9.1 to 9.2 upgrade | — | plugin still works, `get_identity` returns cleanly | — |

## Soak criteria for 1.0.0

Beyond the matrix:

- 72 hours of pvestatd polling with no false `inactive` and no error
  accumulation in the journal
- management network cut for 10 minutes and restored: the storage returns to
  `active` on its own, and running VMs see no I/O interruption
- LUN ids still low after item 24
