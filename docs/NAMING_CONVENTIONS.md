# Naming Conventions

繁體中文：[NAMING_CONVENTIONS_zh-TW.md](NAMING_CONVENTIONS_zh-TW.md)

Implemented in `Common::Naming`, with the PowerStore limits in
`PowerStore::Naming`. `t/01-naming.t` covers the round trips and the
ownership gate.

## Prefix isolation

Every object the plugin creates on the array is named `pve-<storeid>-...`.
Every list, delete and cleanup path filters on that prefix first. Objects that
do not carry it are never read, renamed or deleted — this is the safety
boundary that lets the plugin share an array with other workloads.

## Mapping

| PVE object | Array object | Name pattern |
|---|---|---|
| VM disk | Volume | `pve-{storeid}-{vmid}-disk{n}` |
| Container rootfs | Volume | `pve-{storeid}-{vmid}-disk{n}` |
| Cloud-init | Volume | `pve-{storeid}-{vmid}-cloudinit` |
| EFI disk | Volume | `pve-{storeid}-{vmid}-efidisk{n}` |
| TPM state | Volume | `pve-{storeid}-{vmid}-tpmstate{n}` |
| RAM state (vmstate) | Volume | `pve-{storeid}-{vmid}-state-{snapname}` |
| VM config backup | Volume (1 MB, ext4) | `pve-{storeid}-{vmid}-vmconf-{snapname}` (PowerStore only) |
| Snapshot | Volume snapshot | `{volume}.pve-snap-{snapname}` |
| Template marker | Volume snapshot | `{volume}.pve-base` |
| PVE node | Host | `pve-{cluster}-{node}` |
| Shared host | Host group | `pve-{cluster}-shared` |

The storeid inside a name is sanitized: characters outside `[A-Za-z0-9_-]`
become `_`, and hyphens become underscores. The underscore conversion is what
keeps one storage's prefix from containing another's — `ps` and `ps-1` would
otherwise yield `pve-ps-` and `pve-ps-1-`, and storage `ps` would claim
`ps-1`'s volumes.

**That folding is lossy, and the plugin refuses the consequence rather than
living with it.** `ps-1`, `ps.1`, `ps+1`, `ps@1` and `ps__1` all become
`ps_1`; so do `ps1_`, `_ps1` and `ps1!` become `ps1`. Two such storages on one
array would share every volume name: each would list the other's disks, and
deleting a disk from one would delete it from the other, with the ownership
gate passing for both.

It cannot be fixed inside the name — PowerVault allows 32 characters for a
whole volume name and PowerFlex 31, and there is nothing to spend. So
`on_add_hook` refuses to create a storage whose prefix matches one that
already exists, naming the other storage and what to change. The storage id is
free at that moment; a storage that already holds volumes is not.

PowerStore's own name length and character limits are still to be confirmed
against hardware; see [TESTING.md](TESTING.md).
