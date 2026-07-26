# Quick Start

繁體中文：[QUICKSTART_zh-TW.md](QUICKSTART_zh-TW.md)

> **Read this first.** As of 0.5.0 nothing in this plugin has been run against
> a physical PowerStore. Use a non-production cluster and a non-production
> array, and read [TESTING.md](TESTING.md) before you begin.

## 1. Prerequisites

On every PVE node:

- Proxmox VE 9.1 or later
- `open-iscsi`, `multipath-tools`, `sg3-utils`, `psmisc` installed
- Network reachability to the array's management address and, for iSCSI, to
  its target portals — or a zoned FC fabric

On the array:

- PowerStore OS 3.0 or later
- A REST API account with at least the Storage Operator role
- iSCSI target addresses published, or FC zoning in place

## 2. Install on every node

```bash
apt install ./jt-pve-storage-dellemc_<version>_all.deb
```

Use `apt install ./file.deb` rather than `dpkg -i`: `dpkg -i` does not install
dependencies, and the missing binaries only surface much later as failures
inside the plugin.

A node without the package answers `Parameter verification failed (400)` or
`No such storage` for this storage, and cannot be a live migration target.

## 3. Check the multipath configuration

The installer prints the safety rules and warns about dangerous settings it
finds. Two of them are worth confirming by hand:

```bash
grep -rE 'no_path_retry|dev_loss_tmo|queue_if_no_path' \
    /etc/multipath.conf /etc/multipath/conf.d/ 2>/dev/null
```

`no_path_retry queue` and `dev_loss_tmo infinity` must not apply to these
devices. With every path down, queued I/O that can never complete puts
processes into uninterruptible sleep, and the node has to be power-cycled.

The plugin writes its own drop-in at
`/etc/multipath/conf.d/dellpowerstore.conf` on first activation. It carries a
version marker; a file without that marker is treated as yours and is never
touched.

## 4. Add the storage

```bash
pvesm add dellpowerstore ps1 \
    --dell-portal 192.168.1.50 \
    --dell-username pveadmin \
    --dell-password 'SecurePassword' \
    --dell-protocol iscsi \
    --content images,rootdir \
    --shared 1
```

Run this once, on any node — `/etc/pve/storage.cfg` is cluster-wide.

For Fibre Channel use `--dell-protocol fc`. If only some nodes are on the
fabric, add `--nodes node1,node2`.

Full parameter reference: [CONFIGURATION.md](CONFIGURATION.md).

## 5. Verify

```bash
pvesm status
```

The storage should appear as `active` with the array's capacity. On the array,
one host object per node should now exist, named `pve-{cluster}-{node}`.

If it shows `inactive`, the reason is in the journal:

```bash
journalctl -t pvestatd -n 50 | grep dellpowerstore
```

## 6. Create a disk and confirm the path

```bash
qm create 999 --name dell-test --memory 1024
qm set 999 --scsi0 ps1:8            # 8 GB
```

Then check both ends:

```bash
# On the node: a multipath device with several paths
multipath -ll | grep -A5 DellEMC

# On the array: a volume named pve-ps1-999-disk0
```

`pvesm list ps1` should show `ps1:vm-999-disk-0`.

## 7. Try a snapshot

```bash
qm snapshot 999 before-change
pve-dell-config-get -l ps1 999      # the config backup taken alongside it
qm delsnapshot 999 before-change
```

Every snapshot also writes the VM's configuration to a 1 MB volume, because a
storage snapshot restores the disk and nothing else. `pve-dell-config-get`
reads those back, including when `/etc/pve` is gone — see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## 8. Clean up the test

```bash
qm destroy 999
```

Confirm the volume is gone from the array and that no device is left behind:

```bash
multipath -ll | grep -c DellEMC
```

## Next

- [CONFIGURATION.md](CONFIGURATION.md) — every option, and the three that
  matter under load
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — symptoms and what to do
- [TESTING.md](TESTING.md) — what has and has not been verified
