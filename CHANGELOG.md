# Changelog

All notable changes to this project are documented here.
繁體中文版本：[CHANGELOG_zh-TW.md](CHANGELOG_zh-TW.md)

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
