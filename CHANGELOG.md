# Changelog

All notable changes to this project are documented here.
繁體中文版本：[CHANGELOG_zh-TW.md](CHANGELOG_zh-TW.md)

Versioning: the patch number increments per release and runs to .99 before
the minor number moves — 0.7.0, 0.7.1, … 0.7.99, then 0.8.0. Every 0.x
release is a prerelease; 1.0.0 is the on-hardware test pass.

## [0.7.4~beta1] - 2026-07-27

Continues the cross-check against the related projects' incident records, and
against Dell's own PowerStore and PowerVault manuals.

### Fixed
- **The storage API version is negotiated, not hardcoded.** PVE rejects a
  plugin claiming a version newer than its own — and every storage of that
  type then disappears from the node — while claiming an older one makes PVE
  print `implementing an older storage API` on every load of `PVE::Storage`,
  which is once per `pvesm` call and per daemon start. PVE 9 raised `APIVER`
  twice within the 9.1 point releases, so no fixed number is right everywhere.
  The plugin now claims what the running PVE asks for, capped at the newest
  version whose changes are actually implemented here.
- **`volume_resize` handles the `$snapname` parameter** added in storage API
  14. It was being ignored, so a request to resize a snapshot would have
  resized the volume it was taken from. It is refused with an explanation.
- **Deleting a snapshot now releases the clone that was reading it.** This is
  the `vzdump` snapshot-mode path: PVE takes a snapshot, reads it through
  `path()` — which needs a clone of the snapshot on the array — and deletes
  the snapshot as soon as the backup finishes. An array will not delete a
  snapshot something was cloned from, so every such backup would have failed
  at cleanup, leaving the clone on the array and its device on this node.
  Dell's PowerVault guide states the rule plainly: a volume or snapshot with
  child snapshots cannot be deleted until the children are.
- **The orphan reaper leaves alone any device that still has a working path.**
  A disk hot-added to a running VM is briefly missing from the array's
  listing while the guest already has it open, and a guest's open file
  descriptor is neither a holder nor a mount, so the in-use check cannot see
  it. Removing the map under a running guest shows up as I/O errors on a
  brand-new disk.
- **Outages are measured in time, not polls.** Once PVE marks a storage
  inactive it stops asking for a while, so a real outage may produce one or
  two calls into the plugin — a counter waiting for three consecutive
  failures would stay silent through exactly the outages worth reporting.
  `activate_storage` also records the failure it dies on: PVE calls it before
  `status()` and never reaches `status()` if it dies, which is what an
  unreachable array does.
- **`volume_snapshot_info` and `rename_snapshot` are implemented.** The base
  class versions read a qcow2 file through `filesystem_path`, which this
  plugin cannot provide, so they failed with a message about a method the
  caller never asked for.
- **PowerVault answers the confirmation prompt on rollback.** The CLI
  Reference documents `rollback volume [prompt yes|no] snapshot <snap> <vol>`;
  without it the array waits for an answer a script will never give.
- **PowerFlex reports real snapshot timestamps** instead of showing every
  snapshot as 1970.
- **`pve-dell-config-get` bounds its `mount` and `umount`.** It runs during an
  outage against storage that may be half dead, where an unbounded mount
  never returns.

### Changed
- **Rolling back to anything but the most recent snapshot is refused.** Dell's
  manuals describe what restoring a volume from a snapshot does to the volume
  and say nothing about the snapshots taken after the restore point. On an
  array that discards them, PVE would carry on listing restore points that no
  longer exist. PVE is told which snapshots are in the way, as the built-in
  plugins with destructive rollbacks do.

### Added
- `dell-rollback-any-snapshot` (boolean, default off): lifts the restriction
  above for an operator who has verified the behaviour on their own array.

## [0.7.3~beta1] - 2026-07-27

Cross-checked against the production incident records of the two related
projects, [jt-pve-storage-netapp](https://github.com/jasoncheng7115/jt-pve-storage-netapp)
and [jt-pve-storage-purestorage](https://github.com/jasoncheng7115/jt-pve-storage-purestorage).
Every documented failure class was traced through this codebase; nine were
present here.

### Fixed
- **A refused delete could be reported as success.** `free_image` read `$@`
  after other `eval`s had run in between, and an `eval` resets it. An array
  that refused the delete produced the same return as a successful one, so
  PVE dropped the disk from the VM configuration while the volume was still
  there. The error is now captured the moment the delete returns.
- **A volume could be deleted while still mapped.** If the array failed to
  answer which hosts a volume was mapped to, `free_image` carried on and
  deleted it anyway. Every node it was mapped to would keep a device that
  answers nothing, and anything touching one hangs in uninterruptible sleep.
  That query failing is now fatal, which is retryable; ghost devices are not.
- **The orphan reaper made one array call per volume** whenever a listing did
  not carry WWIDs. That runs in the background of every `status()` poll on
  every node, so it scales as volumes × nodes every ten seconds — the shape
  that collapses an array's management gateway. It now uses only what the
  listing returned, and a listing that carries no WWIDs at all abandons the
  pass instead of concluding that every volume was deleted.
- **Temporary snapshot-access clones could leak.** A worker killed between
  creating one and deleting it left an object with no PVE volume name: it
  appears in no listing and the reaper does not touch objects the array still
  has. They are now recorded per node and removed once the creating process is
  gone.
- **PowerStore collection listings could truncate silently.** The pager
  stopped on a page shorter than the one it asked for, but an array may cap a
  page below the requested size. Volumes past the cut disappeared from the
  disk list and the reaper treated them as deleted. It now follows the
  `Content-Range` the array returns.
- **PowerVault and PowerFlex now wait for an object to become visible after
  creating it**, as PowerStore already did. A successful create is not a
  promise that the next query can see it, and every caller maps or looks up
  the object immediately afterwards.
- **PowerFlex unmaps before deleting in every rollback path**, and a clone
  this node cannot map is rolled back instead of left behind as a disk whose
  device never appears.
- **The block-device test that follows a device glob runs inside the same
  timeout as the glob**, rather than after it.
- `decode_json` was called in `PowerStore/API.pm` without importing `JSON`.

### Added
- `t/11-imports.t`: `perl -c` compiles a call to an undefined subroutine
  without complaint, so a helper used without its `use` line fails only at
  runtime — on the array-facing path, which cannot be exercised without
  hardware. The missing `JSON` import above was found this way.

## [0.7.2~beta1] - 2026-07-26

A review pass over every plugin entry point against the Proxmox VE 9.2.5
storage API source, and over each family's API client. Nine defects, all of
which would have surfaced in the first hours against real hardware.

### Fixed
- **PowerFlex applied the wrong name limit.** `PowerFlex::Naming` overrides
  the limit to 31 characters, but the inherited PowerVault methods read that
  family's constant of 32 directly, so every generated name was allowed to be
  one byte too long. A snapshot or linked clone on a storage with a longer id
  was refused by the array. The shared methods now take the limit from the
  class.
- **Deleting a volume left its snapshots behind.** PVE removes a VM's disks
  without touching storage snapshots — `qm destroy` calls `vdisk_free`
  directly — and a template always carries its marker snapshot, so both
  failed on the array. The snapshots this plugin created are now removed
  first, as the Ceph and ZFS plugins do. The template marker is handled last
  and only when the array's refusal was not about dependents, so a template
  whose linked clones still exist keeps the marker it is identified by.
- **The temporary clone used to read a snapshot ignored the family name
  limits.** It was built by string concatenation and came out at 39 bytes,
  which PowerVault (32) and PowerFlex (31) both refuse, so reading a snapshot
  could not work on those families. It now goes through the naming class.
- **A generated NVMe host NQN was never persisted.** `nvme gen-hostnqn`
  returns a new random NQN on every call, so the array was told one NQN while
  `nvme connect` presented another and the namespace never appeared. It is
  now written to `/etc/nvme/hostnqn`, atomically and without overwriting an
  existing file.
- **Linked clones were listed under the wrong volid.** `clone_image` returns
  `base-100-disk-0/vm-101-disk-0`, which is what PVE stores, but
  `list_images` reported `vm-101-disk-0`. `qm rescan` would see a volume no
  configuration references and add it again as an unused disk. The parent is
  now derived from the array's own metadata; a family that cannot determine
  it reports the clone under its plain name, as the LVM-thin plugin does.
- **A `vollist` filter matched by prefix**, so a request for `vm-1-disk-1`
  also returned `vm-1-disk-10`. It matches exactly now, as the built-in
  plugins do.
- **PowerStore could fail on an operation the array had accepted.** Some
  requests answer 202 with a job id rather than the finished object, and the
  volume was looked up by name immediately afterwards. Creation and cloning
  now wait for the object to appear.
- **PowerVault reported a volume as zero bytes** when `show volumes` returned
  only the formatted size and not the `-numeric` field. Zero also made every
  resize look like growth. The formatted string is parsed as a fallback.
- **The periodic SAN rescan stopped after a backwards clock step**, the same
  defect already fixed in the health cooldown.

### Changed
- Host registration is checked at most once every five minutes per storage
  instead of on every `activate_storage`, which PVE calls on every pvestatd
  poll. On PowerVault that check is a full `show host-groups`.
- `pve-dell-config-get` refuses a storage that is not `dellpowerstore`
  instead of speaking PowerStore REST to another family's array, and says why
  the config backup does not exist on PowerVault.

## [0.7.1~beta1] - 2026-07-26

### Changed
- The VM config backup volume is no longer offered on the `dellpowervault`
  family. Every snapshot of a VM would spend one additional volume on a copy
  of its configuration, and a PowerVault ME array's volume and snapshot
  ceiling is roughly an order of magnitude below PowerStore's — low enough
  that the cost decides whether an array runs out of volumes. Snapshots,
  rollback and linked clones are unaffected, and the configuration remains
  recoverable from a PVE backup or from `/etc/pve` on another node.
- `Common::BlockBase` gained `supports_config_backup()`, the family-level
  switch that decides this, and it now gates every config-volume path.

### Added
- `dell-config-backup` (boolean, default on): turns the config backup off on
  a family that does offer it, for a PowerStore close to its volume limit.
  Setting it on a family that does not offer the feature has no effect.

### Fixed
- Deleting a snapshot or a disk still cleans up any config volumes an earlier
  version wrote, even once the feature is switched off — otherwise they would
  be stranded on the array.

## [0.7.0~beta1] - 2026-07-26

Adds the `dellpowerflex` storage type for PowerFlex 3.x and 4.x.

### Added
- `PowerFlex/API.pm`, `PowerFlex/Naming.pm`, `PowerFlex/Host.pm` and
  `DellPowerFlexPlugin.pm`.
- `Common/Schema.pm`: the shared `dell-*` options, extracted so a family that
  is not a block plugin can use them without inheriting `BlockBase`.
- `docs/POWERFLEX_SDC.md`: the SDC and NVMe/TCP comparison, Dell's support
  matrix and where it lives, and how to check whether a kernel is supported —
  as links to the official sources rather than a copy that would go stale.
- Setup instructions for all three families in the README, and a link to the
  documentation site under the title.
- 991 unit tests in total.

### PowerFlex specifics
- **It does not inherit the block base class.** Volumes arrive through Dell's
  SDC kernel module or the in-kernel NVMe/TCP initiator; there is no SCSI LUN
  and no dm-multipath, so everything `BlockBase` does for devices would be
  wrong.
- **NVMe/TCP is the default.** Dell's Proxmox VE guidance lists SDC support
  for PVE 8.x and only *planned* support for PVE 9.x, and `scini` must be
  compiled for each kernel — so a kernel upgrade can leave a node with no
  storage until it rebuilds. NVMe/TCP uses the kernel Proxmox already ships.
- **NVMe paths are ANA, and the timeouts matter.** Connections are made with
  `ctrl-loss-tmo` 60s rather than the kernel's 600s: it is the NVMe
  equivalent of `no_path_retry`, and an unbounded value turns a total path
  loss into what looks like a hang. Activation warns when
  `nvme_core.multipath` is disabled, and when only some of the array's
  targets could be reached.
- **Both authentication generations are detected**, not configured: the 4.x
  bearer token from `/rest/auth/login` (which expires in five minutes) and
  the 3.x token from `/api/login` that is then used as a password. A refused
  password is never replayed against the other endpoint, which would double
  the failed-login count against a lockout policy.
- Sizes round up to the 8 GB allocation unit; names are limited to 31
  characters.

### Removed
- The internal development specification is no longer in the repository.

## [0.6.0~beta1] - 2026-07-26

Adds the `dellpowervault` storage type for the PowerVault ME4 and ME5 series.

Still beta, and still unverified against hardware. What is different this time
is that the array-facing details were read from the *Dell PowerVault ME5
Series CLI Reference Guide* rather than written from memory, and
[docs/TESTING.md](docs/TESTING.md) now separates what came from the official
documentation from what did not.

### Added
- `PowerVault/API.pm`, `PowerVault/Naming.pm` and `DellPowerVaultPlugin.pm`.
- 154 further unit tests, 867 in total.

### Things this family does differently, and why they matter
- **HTTP 200 does not mean success.** ME exposes its CLI over HTTPS; a
  rejected command answers 200 with the verdict in a `status` object. Judging
  by the HTTP code would let a failed volume create look like it worked, and
  PVE would then record a disk that does not exist.
- **`expand volume` takes a delta, not a total.** PVE asks for the new
  absolute size. Passing it through would grow a 32 GiB volume to 64 GiB when
  the user asked for 33.
- **Sizes round up here.** The array aligns to 4 MiB and rounds *down*, so the
  client rounds up first; otherwise the volume is smaller than PVE believes.
- **Names are limited to 32 bytes and may not contain a dot.** This family
  therefore has its own naming module: short object names, a snapshot
  separator of `-s-` rather than a dot, and a 10-character budget for the
  storage id. A name that will not fit raises an error rather than being
  truncated into a collision with another VM's volume.
- **A linked clone is a snapshot.** ME snapshots are writable and mappable, so
  a clone is a snapshot given a volume-shaped name — instant, and no copy.

### Changed
- Roadmap: PowerStore, then PowerVault ME, then PowerFlex, then PowerMax.
  PowerScale is not scheduled.
- The type string is `dellpowervault`, not `dellme5`: every other family is
  named for its product line rather than a model number, and ME4 and ME5 share
  one API.

## [0.5.0~beta1] - 2026-07-26

Phases 2 to 4. The `dellpowerstore` storage type now exists.

> It has **not** been run against a PowerStore array. Every array-facing
> detail is still listed as unverified in [docs/TESTING.md](docs/TESTING.md).
> 1.0.0 is the on-hardware test pass, not more code.

### Added
- `Common/BlockBase.pm`: the abstract PVE plugin base. SAN activation,
  allocation, device discovery and teardown, snapshots, templates, clones,
  the multipath drop-in and the background orphan reaper — all independent of
  which array is behind them. A family plugin implements the `_array_*`
  methods and inherits the rest.
- `PowerStore/API.pm`: REST client for volumes, snapshots, thin clones, hosts,
  mappings and the transport endpoints, with fixtures and 96 request-shape
  tests.
- `PowerStore/Naming.pm`: PowerStore's wider name limits.
- `DellPowerStorePlugin.pm`: the storage type, plus the schema PVE registers.
- `bin/pve-dell-config-get`: reads a VM configuration back out of the config
  backup volume written beside each snapshot. In recover mode it parses
  `storage.cfg` itself, or takes the array details on the command line, and
  never goes through pvesm — the situation it exists for is the one where
  `/etc/pve` is gone or pvedaemon will not start.
- Documentation: quick start, configuration reference, architecture,
  troubleshooting, naming conventions and the hardware test matrix, in English
  and Traditional Chinese, plus the project page under `docs/`.

### Notes on behaviour worth knowing
- Volumes are mapped to every node at creation, so live migration does not
  have to remap first, and unmapping always precedes deletion — the other
  order lets an in-flight rescan on any node re-import the LUN and rebuild the
  device behind the delete.
- LUN ids are assigned by the plugin, filling gaps from `pstore-lun-id-base`.
  PowerStore's own REST-side sequence starts at 200 and never reuses an id, so
  a cluster that attaches and detaches constantly eventually walks it past
  what the host scans, and new disks stop appearing.
- Volume sizes round up to PowerStore's 8 KiB granularity. Rounding down would
  hand back a volume smaller than PVE asked for.
- `make syntax` reports modules that need Proxmox VE as skipped rather than
  failing, so CI on a plain runner stays honest instead of green by accident.

## [0.2.0] - 2026-07-26

Phase 1 — the shared Common layer. Still no storage type: these are the
modules the family plugins will be built on.

### Added
- `Common/Naming.pm`: object naming, PVE volume name translation, and
  `is_pve_managed_volume`, the `pve-<storeid>-` ownership gate that every
  list, delete and cleanup path has to pass. Class methods, so a family can
  widen the name limits by subclassing without introducing shared mutable
  state — one PVE process loads every Dell plugin at once.
- `Common/REST.pm`: HTTP transport. A POST is never retried on 5xx, because
  the request may have taken effect and a retry would create a second volume.
  A 401 clears the session and retries once. 429/503 back off, honouring
  `Retry-After` up to 30s. Sessions carry the creating pid so a forked PVE
  worker re-authenticates instead of reusing one that is not its own.
  Constructing with `retries => 1` and a short timeout gives the health
  client `activate_storage` and `status()` need.
- `Common/Multipath.pm`: device lifecycle ported from the NetApp and Pure
  plugins with the vendor gate parameterised. `multipath -F` is never
  generated: `multipath_flush` requires a device. Every sysfs access runs in a
  forked, timeout-bounded child, because a plain read of a dead LUN lands in
  uninterruptible sleep that no signal clears.
- `Common/ISCSI.pm`: initiator identity, portal probing, session lifecycle,
  and a per-session rescan that skips sessions which are not `LOGGED_IN`.
- `Common/FC.pm`: HBA discovery and WWN normalisation across the three
  spellings the same WWN arrives in. No LIP by default.
- `Common/WwidState.pm`: per-node WWID tracking, with the grace period and
  miss threshold that must both pass before the orphan reaper may tear a
  device down, and sibling detection so one Dell storage never reports
  another's live device as a stale orphan.
- `Common/Health.pm`: outage detection and capacity alerting for `status()`,
  rate limited so a ~10 second poll cannot flood the journal.
- 342 unit tests (`t/01-naming.t` .. `t/05-state.t`), covering the retry
  policy, the reap guards, the ownership gate and the taint helpers without
  needing an array or a device.

### Fixed
- Rate-limited health messages now treat "never emitted" explicitly and
  treat a timestamp in the future as due. Previously both leaned on epoch
  arithmetic against 0, so a backwards clock step could silence a real
  outage for as long as the skew lasted.

## [0.1.0] - 2026-07-26

Phase 0 — project skeleton. No storage type is registered by this release.

### Added
- MIT license, bilingual README skeleton with the multipath safety rules and
  the hardware-verification disclaimer.
- `Makefile` with `install`, `uninstall`, `test`, `syntax`, `unit`,
  `check-multipath-flush`, `deb` and `clean` targets. The module list is
  discovered from `lib/**/*.pm` instead of being hand-maintained, so packaging
  does not have to change as modules are added.
- Debian packaging: `control`, `rules`, `compat`, `changelog`, `copyright`,
  `docs`, `postinst`, `prerm`, `postrm`. Installation is driven by the
  Makefile through `override_dh_auto_install`.
- `postinst` checks: required binaries present (catches `dpkg -i` without
  dependency resolution), dangerous multipath settings in `/etc/multipath.conf`
  and `/etc/multipath/conf.d/*.conf`, stale all-paths-failed Dell maps, missing
  LVM `global_filter`, in-flight storage operations, and a cluster-wide
  installation reminder.
- GitHub Actions workflow: safety guard, `perl -c` and unit tests gate the
  `.deb` build.
- CI guard `make check-multipath-flush`: the build fails if the system-wide
  flush `multipath -F` — which must never be used — appears in shipped code or
  documentation. Prose that explicitly forbids the command is allowed through.
- Directory skeleton for the multi-family layout (`lib/PVE/Storage/Custom/`,
  `DellEMC/Common/`, per-family subdirectories, `t/`, `docs/`, `bin/`).
