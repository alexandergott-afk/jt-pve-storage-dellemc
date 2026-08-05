# Testing and Hardware Verification Status

繁體中文：[TESTING_zh-TW.md](TESTING_zh-TW.md)

## What HAS been observed on hardware

One array has run this plugin: a **PowerVault ME4024, system name MIL-ME4024,
firmware `GT280R011-01`, Fibre Channel**. Everything in this section was read
off that array rather than out of a document, and the payloads are kept
verbatim in `t/fixtures/powervault/` so the suite is checked against what a
real array sends.

| Observed | Result | Fixed in |
|---|---|---|
| `GET /show/system` returns `text/*` with a non-ASCII byte | `pvesm add` failed outright with `Wide character in subroutine entry`. `decoded_content` returns characters where `decode_json` wants bytes | 0.7.62 |
| `GET /show/host-groups` carries only `host-group` at the top level; hosts nest under `host` (singular), initiators under `initiator` | the host lookup found nothing, so the plugin recreated the host on every poll and the array refused with `-10389`; the storage stayed inactive | 0.7.63 |
| `GET /show/pools` reports free space as `total-avail` / `total-avail-numeric`; there is no `avail` | every pool read as 100% used and PVE refuses to allocate into a full pool. Pool B measured 98.56% used, which is real | 0.7.63 |
| `-10389` is the return code for "The specified host name is already in use" | now read as proof the host exists, from the code and never from the wording | 0.7.63 |
| `map`/`unmap` take an identifier, not a name: `<name>` is an INITIATOR, `<name>.*` a host, `<name>.*.*` a host group | the bare host name was sent, looked up as an initiator, and refused with `-10386`. No volume could be mapped at all | 0.7.65 |
| `show maps` nests: the top level is `volume-view`, one per volume, each carrying its rows under `volume-view-mappings` | the mapping list came back empty, every LUN looked free, and the second volume mapped to a host was refused with `-3177` | 0.7.65 |
| Every volume carries a placeholder row for its default mapping — `lun ""`, `access "not-mapped"`, `access-numeric 0`, `identifier "all other initiators"`, `nickname ""` — visible only in the JSON | it was read as a host and unmapped on every delete, failing with `-10007` | 0.7.65 |
| A mapping can be recorded at host-group level even when the `map` named a host, if that host is the group's only member | a group-level row holds its LUN against every host in the group | 0.7.65 |
| The WWID rule: `3` + `6` (NAA) + OUI `00c0ff` + `000` + volume serial characters 7–12 + the serial's last 16. The `0000` in the serial is right-padded and the WWID's `000` left-padded — opposite directions | the plugin's computed WWID matched `multipath -ll` and `/dev/mapper` on four volumes | already correct |
| `unmap volume initiator <host>.* <volume>` | was marked NOT VERIFIED in the source | verified |
| The WWPN spelling a host object wants: bare hex, comma-separated (`100000109b643bca,100000109b643c04`) | the array accepted it | verified |
| `*` percent-encoded in a path is decoded before the CLI sees it | which is why the URL escaping needs no exception for the `.*` suffix | verified |

### The smoke test that ran on it

Every item in `docs/FIRST_RUN` passed on that array once the three defects
above were fixed: `pvesm status` (3.2s, capacity agreeing with the GUI),
`pvesm alloc` for several volumes with LUNs 4/5/6 in sequence, mapping and
dm-multipath (two paths, prio 50/10), `dd` read and write through
`/dev/mapper` (175 MB/s write, 344 MB/s read, verified by checksum),
`qm snapshot`, `qm rollback`, `qm delsnapshot`, `qm template`, a linked clone
in seconds, the array correctly refusing to delete a template with a live
clone (`-3442`), and unmap, delete and local device cleanup.

**This is the first end-to-end run in the project's history.** It does not
make the other two families verified, and it does not make iSCSI or SAS
verified — this array ran Fibre Channel.

Still not captured from that array, and therefore still inferred:

| Open question | Why it matters | How it is covered meanwhile |
|---|---|---|
| How a host belonging to **no** host group appears in the JSON. The CLI prints ungrouped hosts in a separate block; which key that becomes is unknown | a node whose host is not in a group is the default case for a single-node install | the key list is no longer what decides. Every object in an ME answer names its own type in `object-name`, and a row saying `"object-name": "host"` is collected whichever key it arrived under |
| Whether a host that is **inside** a host group can be mapped to individually at all. On that array a host which was its group's only member had its mapping recorded at group level regardless | a deployment whose hosts are grouped may need group-aware comparison, not just host-aware | a group-level row is counted as holding its LUN, so no id is handed out twice. Whether such a deployment works otherwise is untested |
| What should happen when `qm destroy` fails partway — the array refused to delete a template with a live clone, correctly, but PVE had already removed the VM configuration, so the volume was left with nothing pointing at it | an orphan needing `pvesm free` by hand | the orphan reaper reports it; it is not removed unattended |

## Hardware verification status

**Nothing in this project has been run against a physical PowerStore.**
One PowerVault ME4024 has run it; see the section above for what that
established and what it did not.

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
pools basetype documents `total-avail`, so every pool looked full; and the mapping check
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
| `total-avail-numeric` | pool free space | the pools basetype documents `total-avail`; **Avail** is the printed column heading. Confirmed on an ME4024, where the heading spelling was absent and every pool read as 100% full |
| `avail-numeric`, `avail-size-numeric`, `available-size-numeric` | tried after `total-avail` | older spellings; none is the documented one |
| `size-numeric` (volume) | volume size | the volumes basetype documents `size` as the volume's capacity |
| `allocated-size-numeric` | volume space in use | the volumes basetype documents `allocated-size` |
| `total-size-numeric`, `alloc-size-numeric` | tried after the properties above; **Total Size** and **Alloc Size** are the printed column headings, which are not the same thing as the property names | — |
| `wwn`, `volume-wwn`, `serial-number` | the WWID the host will see | the volumes basetype documents `wwn` as the volume's World Wide Name and `serial-number` as its serial; which one the host's WWID derives from is still **not verified** |
| `volume-name`, `name` | object name | documented as **Name** |
| `nickname` | the host or host group a mapping belongs to | `volume-view-mappings` documents it as the host or host group name, **blank if unset**. Confirmed on an ME4024 that it carries the identifier grammar's suffix: `pve-pve-host15.*` for a host, `pvegroup01.*.*` for a group. A comparison that does not drop the suffix never matches |
| `identifier` | the initiator a mapping belongs to (WWPN or IQN) | `volume-view-mappings`, documented |
| `lun`, `access`, `ports` | LUN, access mode and ports of a mapping | `volume-view-mappings`, documented. Confirmed on an ME4024: `lun` arrives as a **string** (`"2"`), and is `""` on the default-mapping placeholder |
| `access-numeric` | telling a real mapping from the default-mapping placeholder | confirmed on an ME4024: `3` read-write, `1` read-only, **`0` on the placeholder row**. Every volume carries one such row even with no default mapping, its `identifier` set to the display string `all other initiators` and its `nickname` empty. The CLI's own table does not show it; only the JSON does |
| `volume-view`, `volume-group-view` | the top level of a `show maps` answer, one entry per volume | confirmed on an ME4024: the mapping rows nest inside these under `volume-view-mappings`, and there is no top-level array of mappings. The nested rows call themselves `host-view` in `object-name`, so this listing is walked by key, not by the type the row claims |
| `volume-name`, `volume-serial` | which volume a nested mapping row belongs to | confirmed on an ME4024. The rows themselves name their parent only by `durable-id`, so the identity is carried down from the enclosing view — and then used to check that `show maps <volume>` filtered as asked |
| `media` | `iSCSI`, `FC(P)`, `FC(L)`, `SAS` | documented as **Media** |
| `target-id` | the IQN of an iSCSI port | documented as **Target ID** |
| `ip-address` | iSCSI portal address | documented |
| `status`, `health` | whether a port is usable | documented |
| `creation-date-time-numeric` | snapshot date | documented in the volumes basetype as an unformatted epoch |
| `name-numeric`, `status-numeric` | fallback spellings tried when the plain field is absent | — |
| `port-type`, `primary-ip-address` | older spellings of Media and IP Address | — |
| `host-id`, `host`, `name` | further spellings a mapping row may use for who it belongs to | — |
| `host` (nested), `hosts`, `host-view` | the keys a `show host-groups` answer carries its host rows under | the answer is a tree: groups at the top, hosts NESTED inside them, initiators nested again. Confirmed on an ME4024, where reading a top-level `hosts` array found none and the plugin could not see the host it had just created |
| `name`, `host-name` | a host's own name | the host basetype documents `name`; `host-name` is the host-view spelling |
| `durable-id` | telling two host rows apart when the tree reaches one twice | documented |
| `return-code` | whether a command was refused, and why | documented per command; `-10389` is "host name already in use". The code is read, never the wording |

`-numeric` fields are counted in 512-byte blocks; the plain field is a
formatted string like `1996.7GB` and is only parsed when the numeric one is
absent.

### Unity XT (from Dell's own `gounity` client)

Every URI, request body and field name below is read from
`github.com/dell/gounity` — the client Dell's CSI driver uses against Unity —
rather than from documentation prose. Where the two disagreed, the code won.
**None of it has been run against a Unity array.**

| Field | Read for | State |
|---|---|---|
| `id` | every object's handle; a LUN and its `storageResource` share it | documented |
| `name` | object name, and the key of the `name:` lookup | documented |
| `wwn` | the WWID the host will see, `'3'` + the bare hex | the conversion itself is **NOT VERIFIED**; confirm against `multipath -ll` on the first run |
| `sizeTotal`, `sizeUsed`, `sizeAllocated` | volume size and space in use, in **bytes** — not the 512-byte blocks PowerVault reports | Dell's own `LunDisplayFields` |
| `hostAccess` | which hosts may see a LUN. A list of `{host: {id}, accessMask}`, and writing it **REPLACES** the list | Dell's own field list; the replacement semantics are why `ExportVolume` and `ModifyVolumeExport` both exist in Dell's client |
| `accessMask` | `'1'` production, `'2'` snapshot, `'3'` both — a **string**, not a number | Dell's client hardcodes `'1'` |
| `pool` (in `lunParameters`) | the pool a create places the LUN in | the **JSON tag** on Dell's `LunParameters` struct. Its Go field NAME is `StoragePool`, and an earlier draft of this table said the key was `storagePool` from reading the field name — in Go code the `json:"..."` tag is the property name, the field name is a printed one |
| `sizeFree`, `sizeTotal`, `sizeUsed`, `sizeSubscribed` (pool) | pool capacity, in bytes | Dell's own `StoragePoolFields` |
| `isThinEnabled` | thin provisioning, sent as the **string** `'true'` | Dell's client uses `strconv.FormatBool` |
| `creationTime` | snapshot date, ISO 8601 with a zone offset | documented; the offset is read and applied, which cost another family a release |
| `storageResource` (on a snap) | which LUN a snapshot belongs to | Dell's own `SnapshotDisplayFields` |
| `fcHostInitiators`, `iscsiHostInitiators` | initiators registered to a host | Dell's own `HostDisplayFields` |
| `initiatorId`, `parentHost` | an initiator's WWPN/IQN and the host it belongs to | Dell's own `HostInitiatorsDisplayFields` |
| `initiatorType` | `'1'` FC, `'2'` iSCSI — **strings** | Dell's own constants |
| `entries[].content`, `content` | the two response shapes | documented |

Fields are **opt-in**: a request without `?fields=` comes back with almost
nothing. The first failure mode to expect is an object that looks EMPTY
rather than ABSENT, and those are different answers.

| Open question | Why it matters |
|---|---|
| The SCSI vendor and product strings. `DGC` / `VRAID` is the CLARiiON inheritance | **downgraded from a blocker to a first check.** Device discovery is WWID-keyed and does not consult the vendor at all, and multipath-tools' own built-in table carries `vendor "^DGC"`, so maps appear and devices are found even if this plugin's strings are wrong. A wrong string costs the tuning drop-in (the kernel's DGC defaults apply instead) and the vendor-gated residual-path sweep — degraded, not broken. Still confirm with `sg_inq /dev/sdX` on first contact and report what it prints |
| The WWN to WWID conversion | device discovery does not work at all if it is wrong |
| `POST /instances/snap/<id>/action/restore` | the one destructive call that is **not** in Dell's client, because a CSI driver never rolls back |
| Whether the array rounds a LUN size up or down | this plugin rounds up to 8 KiB first, which makes the question harmless either way |
| The minimum LUN size Unisphere accepts | assumed 1 GiB, rounded up from every reference found; a tiny volume (EFI disk, TPM state, 4 MiB each) is rounded up to it, so being too generous wastes space and being wrong the other way breaks `qm create` |
| How many thin clones one base resource supports, and how many snapshots one LUN family carries | Dell's white paper suggests both are bounded (thin clones per base, snapshots per family); a template with more linked clones than the limit will be refused by the array. Not enforced client-side — the array's refusal is authoritative |
| That `copyName` on a snap restore names the automatic backup snapshot | Dell's white paper documents that every restore creates one; if `copyName` is ignored, the backup gets an array-chosen name that the snapshot purge does not recognise, and the volume becomes undeletable. **Check for a snapshot named `<volume>.pve-snap-rollback*` after the first `qm rollback`** |
| Whether an HLU can be pinned | nothing depends on it; Unity assigns them |

### Testing Unity without a Unity

`github.com/mackayd/Unity-API-Emulator` is a single Python file that speaks
Unity's REST envelope: the `entries`/`content` shapes, `?fields=`, filtering,
pagination, `name:` lookups, and the two authentication rules — it answers
**302** when `X-EMC-REST-CLIENT` is missing and **403** when a write arrives
without `EMC-CSRF-TOKEN`.

```bash
git clone https://github.com/mackayd/Unity-API-Emulator
python3 Unity_RestAPI_Emulator.py --port 18443 \
    --username admin --password 'Password123!' \
    --strict-auth --require-csrf --quiet
```

Then point a storage at `127.0.0.1:18443` with `dell-ssl-verify 0`.

**It is not a Dell product and does not emulate storage behaviour.** It
cannot tell you whether a delete really deletes, whether a WWID matches a
device, or whether a mapping reaches a host. What it can do is exercise the
transport, the authentication, the response shapes and the request bodies
over real HTTP, which nothing else here can do before hardware.

It has already been worth it: the emulator answers `createLun` with 204 and
no body, and that made `volume_create` return `undef` in silence. A real
array may do the same under some firmware, or answer asynchronously with a
job. Every create now falls back to a lookup by the name it just used, and
fails loudly if even that cannot answer.

The emulator has also caught what no unit test could: the create that
answers 204 with no body, and — driven through a full `pvesm add` — a
refused storage that had already written the multipath drop-in and issued
the node-wide reconfigure. An end-to-end path against it belongs in every
future family's bring-up.

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
