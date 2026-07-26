# Naming Conventions

> **Status: skeleton (Phase 0).** Authoritative rules land with
> `Common::Naming` in Phase 1. 繁體中文：[NAMING_CONVENTIONS_zh-TW.md](NAMING_CONVENTIONS_zh-TW.md)

## Prefix isolation

Every object the plugin creates on the array is named `pve-<storeid>-...`.
Every list, delete and cleanup path filters on that prefix first. Objects that
do not carry it are never read, renamed or deleted — this is the safety
boundary that lets the plugin share an array with other workloads.

## Planned mapping

| PVE object | Array object | Name pattern |
|---|---|---|
| VM disk | Volume | `pve-{storeid}-{vmid}-disk{n}` |
| Container rootfs | Volume | `pve-{storeid}-{vmid}-disk{n}` |
| Cloud-init | Volume | `pve-{storeid}-{vmid}-cloudinit` |
| EFI disk | Volume | `pve-{storeid}-{vmid}-efidisk{n}` |
| TPM state | Volume | `pve-{storeid}-{vmid}-tpmstate{n}` |
| RAM state (vmstate) | Volume | `pve-{storeid}-{vmid}-state-{snapname}` |
| VM config backup | Volume (1 MB, ext4) | `pve-{storeid}-{vmid}-vmconf-{snapname}` |
| Snapshot | Volume snapshot | `{volume}.pve-snap-{snapname}` |
| Template marker | Volume snapshot | `{volume}.pve-base` |
| PVE node | Host | `pve-{cluster}-{node}` |
| Shared host | Host group | `pve-{cluster}-shared` |

PowerStore name length and character restrictions are still to be confirmed
against hardware; see `docs/TESTING.md`.
