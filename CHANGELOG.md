# Changelog

All notable changes to this project are documented here.
繁體中文版本：[CHANGELOG_zh-TW.md](CHANGELOG_zh-TW.md)

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
