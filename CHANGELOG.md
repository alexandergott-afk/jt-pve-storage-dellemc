# Changelog

All notable changes to this project are documented here.
繁體中文版本：[CHANGELOG_zh-TW.md](CHANGELOG_zh-TW.md)

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
