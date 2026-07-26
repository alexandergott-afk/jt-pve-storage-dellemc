# Troubleshooting

> **Status: skeleton (Phase 0).** Written alongside Phase 4.
> 繁體中文：[TROUBLESHOOTING_zh-TW.md](TROUBLESHOOTING_zh-TW.md)

Planned entries:

- `Parameter verification failed (400)` / `No such storage` — the package is
  missing on that node. Install it on every node.
- Storage shows `inactive` in `pvesm status` — management network, credentials,
  or `dell-status-timeout` too low for the array's response time.
- New disks stop appearing after many attach/detach cycles — PowerStore keeps
  separate automatic LUN ID sequences for its UI and for REST/PSTCLI, and the
  REST sequence climbs without reuse. The plugin assigns the LUN ID itself to
  avoid this; this entry explains how to confirm and how to reset.
- Volume cannot be deleted, "device is still in use (has holders)" — usually
  host LVM having auto-activated a VG that lives inside a guest disk. Fix with
  an LVM `global_filter`.
- Stale multipath maps with all paths failed — how to identify them and remove
  a single map safely.
- Devices in D state — what causes it, and why `no_path_retry queue` and
  `dev_loss_tmo infinity` must be avoided.
- Reading plugin messages out of the journal: every message is prefixed with
  `[dellpowerstore:<storeid>]`.
