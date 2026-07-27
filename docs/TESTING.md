# Testing and Hardware Verification Status

繁體中文：[TESTING_zh-TW.md](TESTING_zh-TW.md)

## Hardware verification status

**Nothing in this project has been run against a physical PowerStore.**

Everything below is `NOT VERIFIED ON HARDWARE` until it has been executed on a
real array and the result recorded here together with the PowerStore OS
version it was observed on.

| Item | Where | Status |
|---|---|---|
| REST endpoint paths | `PowerStore/API.pm` | NOT VERIFIED ON HARDWARE — but every path this plugin uses appears verbatim in Dell's own `python-powerstore` SDK (`PyPowerStore/utils/constants.py`); see below |
| Response field names (`size`, `wwn`, `logical_used`, `protection_data`) | `PowerStore/API.pm` | NOT VERIFIED ON HARDWARE |
| Filter syntax (`eq.`, `ilike.`, `cs.{...}`, `->>`) | `PowerStore/API.pm` | NOT VERIFIED ON HARDWARE — the operator prefixes and the `*` wildcard are read from the developers guide |
| Authentication (`login_session`, `DELL-EMC-TOKEN`, `auth_cookie`) | `PowerStore/API.pm` | NOT VERIFIED ON HARDWARE — the header, the cookie and "non-GET requires the token" are read from the developers guide |
| Capacity source (`space_metrics_by_cluster`) | `PowerStore/API.pm` | NOT VERIFIED ON HARDWARE |
| SCSI vendor / product strings for multipath | `DellPowerStorePlugin.pm` | NOT VERIFIED ON HARDWARE |
| WWN to multipath WWID conversion | `PowerStore/API.pm` | NOT VERIFIED ON HARDWARE |
| Volume name length and character limits | `PowerStore/Naming.pm` | NOT VERIFIED ON HARDWARE |
| LUN id assignment behaviour | `PowerStore/API.pm` | NOT VERIFIED ON HARDWARE |
| Multipath device settings | `DellPowerStorePlugin.pm` | NOT VERIFIED ON HARDWARE |
| Fibre Channel data path | everywhere | NOT VERIFIED ON HARDWARE |
| What a restore does to snapshots taken after the restore point | `DellPowerStorePlugin.pm`, `DellPowerVaultPlugin.pm`, `DellPowerFlexPlugin.pm` | NOT VERIFIED ON HARDWARE |
| WWPN spelling in a host object (bare hex vs colon-separated) | `DellPowerStorePlugin.pm`, `DellPowerVaultPlugin.pm` | NOT VERIFIED ON HARDWARE |
| Thin-clone parent field used to report linked clones (`protection_data.source_id`, `ancestorVolumeId`) | `DellPowerStorePlugin.pm`, `DellPowerFlexPlugin.pm` | NOT VERIFIED ON HARDWARE |
| NVMe-TCP | — | out of scope for 1.0 |

### Where to check them

The array publishes its own API reference. On PowerStore that is Swagger UI at
`https://<mgmt-ip>/swaggerui`, which lists every path this plugin uses and
generates the equivalent `curl` command; check each endpoint there before
trusting it. Dell's published documentation shows the same shape for the
object types it does document — `POST /volume_group/{id}/clone`,
`POST /file_system/{id}/snapshot` — which is consistent with the
`/volume/{id}/clone` and `/volume/{id}/snapshot` used here, but consistency
with a sibling object type is not verification.

On PowerVault the reference is the ME4 / ME5 Series CLI Reference Guide, and
the commands can be checked one at a time over SSH before the plugin sends
them over HTTPS.

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
| `pattern` takes shell-style wildcards — `*`, `?`, `[]` — and matches names *containing* the string | show volumes |
| `show volumes` prints the columns Name, Total Size, Alloc Size, Serial Number, WWN, Pool, Class, Type, Role, Health | show volumes |
| The **volumes basetype** — the property names the JSON actually carries — documents `volume-name`, `durable-id`, `serial-number`, `wwn`, `size`, `total-size`, `allocated-size` (each with a `-numeric` twin in blocks), `health`, `creation-date-time` and `creation-date-time-numeric`. **A printed column heading is not a property name** | volumes basetype |
| A `show maps` row carries `nickname` (host or host group name, blank if unset), `identifier` (initiator WWPN or IQN), `lun`, `access`, `ports`, `parent-id` | volume-view-mappings basetype |
| An initiator row carries `id` (WWPN or IQN) and `hba-nickname` | initiator-view basetype |

### Verified against Dell's CLI Reference since

These were guessed and are now read from the ME4/ME5 CLI Guide. Two of the
guesses were wrong, and both sit on the first activation of the storage:

| Command | As documented | What it was |
|---|---|---|
| create a host | `create host initiators <list> <name>` | `create host id <list> <name>` |
| add an initiator to a host | `add host-members initiators <list> <host>` | `set initiator host <host> <initiator>` — a different command that names an initiator and attaches it to nothing |
| delete a volume | `delete volumes <list>` | unchanged; confirmed to prompt only in interactive console mode |
| rename a volume | `set volume name <new> <volume>` | unchanged |
| unmap | `unmap volume initiator <hosts> <volumes>` | unchanged; omitting the initiator would delete the DEFAULT mapping instead |
| roll back | `rollback volume [prompt yes\|no] snapshot <snap> <volume>` | now answers the prompt |
| list volumes | `show volumes [details] [pattern <s>] [pool <p>] [type ...]` | argument order now matches the guide |
| map | see below — ME4 and ME5 document **different** orders | ME5 form, with a fallback |

`map volume` is the one command whose documented argument order differs
between the two families:

```
ME5:  map volume [access ...] initiator <initiators> [lun <LUN>] <volumes>
ME4:  map volume <volumes> [access ...] initiator <initiators> [lun <LUN>]
```

The plugin sends the ME5 form and falls back to the ME4 one if the array
refuses it, so both work; on an ME4 the journal says which order it settled
on. **On the first hardware run, check that line** — it is the cheapest
confirmation that the mapping path is behaving as documented.

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


## Field names: what has been read, and what has not

Two of the worst defects found before the first hardware run were field names
that did not exist: PowerVault's pool capacity read `avail-size` where the
array reports `Avail`, so every pool looked full; and the mapping check
compared against a host name in a listing that has no host-name column. Both
were invisible except as behaviour that made no sense.

So here is every field the API clients read. On the first run, compare this
against what the array actually returns — for PowerStore through Swagger UI
at `https://<mgmt-ip>/swaggerui`, for PowerVault by running the command over
SSH, for PowerFlex through the API directly.

### PowerVault ME (from the ME4/ME5 CLI Reference)

| Field | Read for | State |
|---|---|---|
| `total-size-numeric` | pool capacity, in 512-byte blocks | documented as **Total Size** |
| `avail-numeric` | pool free space | documented as **Avail** |
| `size-numeric` (volume) | volume size | the volumes basetype documents `size` as the volume's capacity |
| `allocated-size-numeric` | volume space in use | the volumes basetype documents `allocated-size` |
| `total-size-numeric`, `alloc-size-numeric` | tried after the properties above; **Total Size** and **Alloc Size** are the printed column headings, which are not the same thing as the property names | — |
| `wwn`, `volume-wwn`, `serial-number` | the WWID the host will see | the volumes basetype documents `wwn` as the volume's World Wide Name and `serial-number` as its serial; which one the host's WWID derives from is still **not verified** |
| `volume-name`, `name` | object name | documented as **Name** |
| `nickname` | the host or host group a mapping belongs to | `volume-view-mappings` documents it as the host or host group name, **blank if unset** |
| `identifier` | the initiator a mapping belongs to (WWPN or IQN) | `volume-view-mappings`, documented |
| `lun`, `access`, `ports` | LUN, access mode and ports of a mapping | `volume-view-mappings`, documented |
| `media` | `iSCSI`, `FC(P)`, `FC(L)`, `SAS` | documented as **Media** |
| `target-id` | the IQN of an iSCSI port | documented as **Target ID** |
| `ip-address` | iSCSI portal address | documented |
| `status`, `health` | whether a port is usable | documented |
| `creation-date-time-numeric` | snapshot date | documented in the volumes basetype as an unformatted epoch |
| `name-numeric`, `status-numeric` | fallback spellings tried when the plain field is absent | — |
| `port-type`, `primary-ip-address` | older spellings of Media and IP Address | — |
| `host-id`, `host`, `name` | further spellings a mapping row may use for who it belongs to | — |

`-numeric` fields are counted in 512-byte blocks; the plain field is a
formatted string like `1996.7GB` and is only parsed when the numeric one is
absent.

### PowerStore (from the 4.x REST documentation)

Some of the request shape *was* read from the Dell PowerStore REST API
Developers Guide, and is quoted here so a first tester can tell it apart from
the rest:

| Read from the guide | What it says |
|---|---|
| Session | `GET /login_session` with HTTP Basic returns the `DELL-EMC-TOKEN` header and an `auth_cookie`; both authenticate the rest of the session |
| CSRF | "Requests other than GET require the DELL-EMC-TOKEN header" — obtained from a GET response, so this plugin also takes the newest one any response offers |
| Filter form | `?<attribute>=[not.]<operator>.<value>` |
| Operators | `eq` `neq` `gt` `gte` `lt` `lte` `ilike` `in` `is` `cs` `cd` |
| `ilike` wildcard | every example in the guide spells it `*` (`?name=ilike.User*`), which is what this plugin sends |
| Parameters | `select` (comma-separated attributes), `order`, `async` |
| Endpoints | every path this plugin uses appears verbatim in Dell's `python-powerstore` SDK: `/login_session`, `/logout`, `/cluster`, `/appliance`, `/volume`, `/volume/{id}`, `/volume/{id}/attach`, `/detach`, `/restore`, `/snapshot`, `/clone`, `/host`, `/host/{id}`, `/host_group`, `/host_volume_mapping`, `/ip_pool_address`, `/ip_port/{id}`, `/job/{id}` |
| Request bodies | the same SDK's `provisioning.py` sends exactly these: volume create `{name, size, appliance_id, volume_group_id, performance_policy_id, protection_policy_id, description}`; attach/detach `{host_id \| host_group_id, logical_unit_number}`; restore `{from_snap_id, create_backup_snap}`; clone `{name}`; snapshot `{name}`; host create `{name, os_type, initiators}`; add an initiator PATCH `{add_initiators}` |
| Initiators | `[{port_name, port_type}]` with `port_type` one of `iSCSI`, `FC`, `NVMe`, and `os_type` one of `Windows`, `Linux`, `ESXi`, `AIX`, `HP-UX`, `Solaris` — the enums `ansible-powerstore` documents |
| Metrics | `POST /metrics/generate` with `{entity, entity_id, interval}`. `space_metrics_by_cluster` is an **entity name for that call**, not a REST collection — reading it as one is what this plugin used to do |
| Pagination | `limit` (1–2000, default 100) and `offset` URL parameters, or a `Range` request header |
| Partial results | a collection larger than the limit answers `206 Partial Content` with `Content-Range: 0-99/1000` — the figure after the slash is the total |
| Offset past the end | `416 Range Not Satisfiable`, which paging can reach legitimately if the collection shrinks between pages, so it ends the paging instead of failing |

A wildcard the array reads differently would match nothing and make every
volume vanish from PVE while the array still holds them, so a name-prefix
listing that comes back empty is retried without the filter and matched
locally — with a warning naming the cause. Report that warning if you see it.

The **response** field names below are what is still open — what the array
actually puts in a row, which differs between 3.x and 4.x. Several are now
corroborated by the sample payloads in Dell's `ansible-powerstore` collection,
which is noted per row; the rest are still inferred.

| Field | Read for | State |
|---|---|---|
| `id`, `name`, `size`, `logical_used` | volumes | all four appear in Dell's `ansible-powerstore` volume sample; `size` is in bytes |
| `wwn` | the WWID the host will see | the sample shows `naa.68ccf09800ac8ab0e2506d99bee29e40` — the `naa.` form this plugin converts. Still **not verified against a host's own `scsi_id`**, which is the thing to check |
| `state`, `type` | usable / Primary vs Snapshot | the sample shows `Ready` and `Primary`, which is what the filters here send |
| `protection_data.source_id` | which snapshot a thin clone came from | `protection_data` in the sample carries `source_id`, `parent_id`, `family_id` |
| `creation_timestamp` | snapshot date | the sample shows `2022-01-06T05:41:59.381459+00:00` — fractional seconds and an explicit offset, both handled |
| `appliance_id` | which appliance a volume is on | in the sample |
| `physical_total`, `physical_used`, `total_physical`, `total_used` | capacity, from a metrics record | **not verified** |
| `host_id`, `host_group_id`, `logical_unit_number`, `volume_id` | mapping rows | the same names the attach/detach request bodies use, which Dell's SDK confirms |
| `address`, `target_iqn` | iSCSI portals | **not verified** |
| `purposes` | which addresses publish an iSCSI target — a list, but a bare string is accepted too | **not verified** |
| `messages[].message_l10n`, `messages[].code` | the array's own error text | **not verified** |

### PowerFlex (from the REST documentation)

| Field | Read for | State |
|---|---|---|
| `id`, `name`, `sizeInKb`, `volumeSizeInKb` | volumes | corroborated |
| `ancestorVolumeId` | which volume a snapshot came from | documented in Dell's own `ansible-powerflex` volume module, which shows it on a snapshot object |
| `creationTime` | snapshot date | same source, an epoch on the volume object |
| `mappedSdcInfo`, `sdcId` | mappings | same source: `mappedSdcInfo` carries `sdcId`, `sdcName`, `sdcIp`, `accessMode`, `limitIops` |
| `hostId` | an NVMe host mapping, read alongside `sdcId` | **not verified** — the SDC-era documentation has no such field, and reading a field that is absent costs nothing |
| `mappedHostInfo` | NVMe host mappings, read alongside `mappedSdcInfo` because an empty answer here means "map it again" | **not verified** |
| `sdcGuid`, `sdcIp` | finding this node's SDC | **not verified** |
| `maxCapacityInKb`, `capacityInUseInKb`, `thinCapacityInUseInKb` | pool capacity | **not verified** |
| `protectionDomainId`, `protectionDomainName` | resolving an ambiguous pool name | both appear on the volume object in `ansible-powerflex` |
| `capacityAvailableForVolumeAllocationInKb` | pool capacity, fallback | **not verified** |
| `access_token`, `refresh_token` | the 4.x login reply | **not verified** |
| `errorCode`, `message` | the array's own error text | **not verified** |
| `volumeIdList` | the ids a snapshot request created | **not verified** |
| `ipList` (with `ip` and `role` per entry) | the SDT addresses a host may connect to | Dell's `ansible-powerflex` sdt module shows both, with roles `StorageOnly` / `HostOnly` / `StorageAndHost` |
| `nvmePort` | the port a host connects to, 4420 in Dell's example | same source. **Not `storagePort`**, which is 12200 and carries SDS-to-SDT traffic |
| `discoveryPort` | where the subsystem NQN is discovered, 8009 in Dell's example | same source |
| `systemNqn`, `nqn` | a subsystem NQN, if an SDT ever carries one | **not verified, and Dell's field list for an SDT has neither** — so the NQN is discovered with `nvme discover` instead |


A field that is missing does not fail loudly. A size reads as 0, a WWID as
undef, a capacity as full. The plugin refuses to act on some of those — an
orphan pass with no WWIDs at all is abandoned rather than treated as "every
volume was deleted" — but the only real answer is to compare this table
against one real response.

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
