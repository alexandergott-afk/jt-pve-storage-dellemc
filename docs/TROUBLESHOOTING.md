# Troubleshooting

繁體中文：[TROUBLESHOOTING_zh-TW.md](TROUBLESHOOTING_zh-TW.md)

Every message from this plugin is prefixed with `[dellpowerstore:<storeid>]`,
so start here:

```bash
journalctl -t pvestatd -t pvedaemon | grep dellpowerstore
```

---

## `Parameter verification failed (400)` or `No such storage`

The package is not installed on that node. Install it on **every** node of the
cluster; `/etc/pve/storage.cfg` is cluster-wide but the plugin code is not.

```bash
# on the node that fails
dpkg -l jt-pve-storage-dellemc
```

After an upgrade, also run `systemctl restart pvestatd` on every node: a
reload does not reliably replace Perl modules that are already loaded.

---

## The storage shows `inactive`

`inactive` means the health poll failed. It does **not** stop running VMs:
their devices stay mapped and their I/O is unaffected.

```bash
journalctl -t pvestatd -n 50 | grep dellpowerstore
```

Common causes, in the order worth checking:

1. **Credentials.** `HTTP 401` in the journal. Verify `dell-username` and
   `dell-password`, and that the account is not locked out in PowerStore
   Manager.
2. **Management network.** A timeout rather than a 401. Check reachability
   from that specific node.
3. **A slow array.** The health path allows `dell-status-timeout` seconds
   (default 5) and makes one attempt. On a heavily loaded array the storage
   may flip to `inactive` for one poll and recover on the next; raise the
   timeout if it is persistent.
4. **No usable path.** With iSCSI, `activate_storage` fails outright when no
   portal is reachable, and the message names which ones it tried.

If **other** storages also went `inactive` at the same time, suspect this one
was slow: PVE polls storages sequentially, so one slow storage delays the
rest. That is what `dell-status-timeout` exists to bound.

---

## New disks stop appearing after a while

The symptom: volumes are created on the array, the mapping exists, and no
device ever shows up on the host. Older volumes still work.

PowerStore keeps **separate automatic LUN id sequences** for its UI and for
REST/PSTCLI. The REST sequence starts at 200 and only ever climbs — ids are
never reused. A PVE cluster attaches and detaches constantly, so that counter
walks upward until it passes what the host's SCSI layer scans, and every new
disk after that point is invisible.

This plugin assigns LUN ids itself for exactly this reason, filling gaps from
`pstore-lun-id-base` (default 1) upward, so it should not happen. To confirm
what a host actually has:

```bash
# in PowerStore Manager: Compute > Host Information > <host> > Mapped Volumes
# and check the LUN column
```

If you find high ids from before this plugin was in use, detach and reattach
those volumes so they get a low id.

---

## `Cannot delete volume ... device is still in use`

The plugin refuses to delete a volume whose device is mounted, has holders, or
is open by a process. The message lists what it found.

The most common cause is **not** a running VM. It is the host's LVM having
auto-activated a volume group that lives *inside* a guest disk, which is
common on nodes upgraded from earlier PVE releases:

```bash
lsblk /dev/mapper/<wwid>
vgs -o vg_name,vg_uuid,pv_name
```

Deactivate the guest VG and retry:

```bash
vgchange -an <guest_vg_name>
```

To stop it recurring, add a filter to the `devices` section of
`/etc/lvm/lvm.conf`:

```
global_filter = [ "r|/dev/mapper/36.*|", "r|/dev/dm-.*|", "a|.*|" ]
```

Fresh PVE 9 installs already have a filter; upgraded nodes often do not.

---

## Stale multipath devices with all paths failed

A volume deleted from another node leaves this node with a map pointing at
storage that no longer answers. The plugin's orphan reaper removes those
automatically, but only once the WWID has been tracked past the grace period
(10 minutes) **and** missing from the array for three consecutive passes, and
only when the device is idle. Those guards exist because reaping a device that
is actually in use destroys a running VM's disk.

Devices the plugin does not recognise are reported, never removed:

```
orphan cleanup: /dev/mapper/36... is not on this storage's array and is not
tracked by any Dell storage on this node
```

To remove one by hand, one map at a time:

```bash
multipathd disablequeueing map <wwid>
dmsetup message <wwid> 0 fail_if_no_path
multipath -f /dev/mapper/<wwid>
# only if that fails:
dmsetup remove --force --retry <wwid>
```

**Never `multipath -F`** (capital F). It flushes every unused map on the node,
including maps belonging to storage this plugin does not manage.

---

## Processes stuck in D state, node unresponsive

Uninterruptible sleep cannot be cleared by any signal, including SIGKILL. Once
PVE daemons are in it, the node needs a reboot.

The cause is almost always queued I/O to a device with no working path, which
means `no_path_retry queue` or `queue_if_no_path` applied to these devices:

```bash
grep -rE 'no_path_retry|queue_if_no_path|dev_loss_tmo' \
    /etc/multipath.conf /etc/multipath/conf.d/
multipath -ll     # look for maps with every path failed
```

Fix the configuration to `no_path_retry 30`, `fast_io_fail_tmo 5`,
`dev_loss_tmo 60`, then:

```bash
systemctl restart multipathd     # restart, not reload
```

`reload` only re-reads the file; `restart` is what reapplies device-mapper
state.

---

## A volume's device never appears

The failure message already carries the host-side state as it was at the
moment of the failure — multipathd's view, whether a map exists for the WWID,
whether udev created the node, and the iSCSI session states. Read it before
reproducing anything.

The one case worth calling out: `rescan` is only issued on sessions the kernel
reports as `LOGGED_IN`. A session sitting in `FAILED` or `REOPEN` is skipped,
so a volume reachable only through that path can never be discovered no matter
how long you wait. The diagnostics say so explicitly when it applies.

```bash
iscsiadm -m session
cat /sys/class/iscsi_session/session*/state
```

For FC:

```bash
cat /sys/class/fc_host/host*/port_state
cat /sys/class/fc_remote_ports/rport-*/port_state
```

---

## Recovering a VM configuration

A storage snapshot restores the disk. The VM's configuration lives in
`/etc/pve`, which the snapshot does not cover, so every snapshot also writes
the configuration to a 1 MB volume beside the disk.

```bash
# what is available
pve-dell-config-get -l ps1 100

# restore one
pve-dell-config-get ps1 100 before-upgrade > /etc/pve/qemu-server/100.conf
```

When `/etc/pve` itself is gone or pvedaemon will not start, the tool can talk
to the array directly:

```bash
pve-dell-config-get -r --portal 10.0.0.5 --username pveadmin \
    --password secret ps1 100 before-upgrade
```

The volume is attached read-only for the duration and detached again
afterwards, including on failure and on Ctrl-C.

---

## Full Clone is slow

Expected, and not fixable from here. PVE implements a full clone as
`alloc_image` plus a block-by-block `qemu-img` copy, and never calls the
plugin's `clone_image`. Use **Linked Clone** to get the array's instant thin
clone.

---

## Deleting a template fails

A template's marker snapshot is the source of every linked clone made from it.
The array refuses to delete it while those clones exist, and the plugin
surfaces that with the dependent objects named. Delete the clones first.

---

## Collecting information for a bug report

```bash
pveversion -v | head -5
dpkg -l jt-pve-storage-dellemc
journalctl -t pvestatd -t pvedaemon --since '30 min ago' | grep -i dell
multipath -ll
iscsiadm -m session          # or the FC commands above
cat /etc/pve/storage.cfg     # remove the password first
```
