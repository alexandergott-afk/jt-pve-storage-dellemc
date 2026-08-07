# The first run on real hardware

繁體中文版本：[FIRST_RUN_zh-TW.md](FIRST_RUN_zh-TW.md)

No part of this plugin has ever run against a Dell EMC array. Everything
array-facing was written from Dell's published documentation, and where the
documentation could not be read it was inferred — inference that has already
been wrong four times on PowerVault alone, each time found by going back and
reading the guide.

So the first run is not a formality. This page is the order to do it in, what
to look at after each step, and what the failure most likely means. It is
written to be worked through top to bottom on one node, with one VM, before
anything else touches the storage.

Have ready:

- a node you can afford to reboot,
- an array account with the role the operations need (Storage Operator on
  PowerStore, `manage` on PowerVault),
- the array's management address, and its GUI or CLI open beside you,
- 30 minutes.

---

## Before the storage exists

### 1. Install, and check nothing else moved

```bash
pvesm status > /tmp/before.txt
apt install ./jt-pve-storage-dellemc_<version>_all.deb
systemctl restart pvestatd            # on EVERY node
pvesm status > /tmp/after.txt
diff /tmp/before.txt /tmp/after.txt
```

**Expected:** no storage changes state. If every storage on the node has gone
`inactive` or vanished, the plugin has broken the storage schema for the whole
node — remove the package, restart `pvestatd`, and report it. That failure
mode is why this is the first check.

`systemctl restart pvestatd` is not optional. `reload` leaves the old Perl in
memory on many PVE versions; verify the PID changed:

```bash
systemctl show -p MainPID pvestatd
```

### 2. Check the three types registered

```bash
perl -e 'use PVE::Storage;
  my $p = PVE::Storage::Plugin->private()->{plugins};
  print join(", ", grep { /dell/ } sort keys %$p), "\n";'
```

**Expected:** `dellpowerflex, dellpowerstore, dellpowervault`, and **no**
`implementing an older storage API` warning. The warning means the negotiated
API version is wrong for this PVE — report the output of

```bash
perl -MPVE::Storage -e 'print PVE::Storage::APIVER, " ", PVE::Storage::APIAGE, "\n"'
```

---

## Adding the storage

### 3. Add it, and watch what the array does

Keep the array's GUI open. Add the storage with a **short** storage id —
PowerVault gives it 10 characters and PowerFlex 9, and a longer one is refused
at creation rather than silently truncated.

```bash
pvesm add dellpowerstore ps1 \
    --dell-portal 10.0.0.5 --dell-username pveadmin --dell-password 'secret' \
    --dell-protocol iscsi --content images,rootdir
```

**Expected:** the command returns, and a host object named
`pve-<cluster>-<node>` appears on the array carrying this node's IQN or WWPNs.

| What you see | What it means |
|---|---|
| `Cannot reach the array at ...` | the management address, credentials, or TLS. The message carries the array's own words after `Array error:` |
| the host object does not appear | the host-creation command was refused; check the array's event log for what it said |
| this node's IQN is on a *different* host object | an earlier manual registration owns it. Remove it on the array, or set `dell-cluster-name` so the generated name matches the existing one |

### 4. `pvesm status`, and the four things worth checking first

```bash
time pvesm status
```

**Expected:** the storage is `active`, the capacity is within about 1% of what
the array's own UI shows, and the whole command takes a couple of seconds. If
it takes tens of seconds, raise it as a problem — a slow storage starves its
neighbours, which is what `dell-status-timeout` exists to bound.

Then the four unverified things that everything else depends on:

```bash
# 1. The SCSI vendor and product strings this plugin gates every device on
sg_inq /dev/sdX | head -3

# 2. The WWID the array's WWN produces, against what the host sees
/lib/udev/scsi_id -g -u /dev/sdX

# 3. What the array publishes as iSCSI portals, and what this node reached
iscsiadm -m session

# 4. The multipath drop-in this plugin wrote
cat /etc/multipath/conf.d/dellpowerstore.conf
multipath -ll
```

Compare 1 against `multipath_vendor` / `multipath_product` in the family
plugin: if they do not match, **no device will ever be recognised**, and that
is the single most likely first-run failure. Compare 2 against the WWID in
`multipath -ll`.

---

### Unity XT: first contact

The Unity family has never run against an array; a first run is what settles
its `NOT VERIFIED` register in [TESTING.md](TESTING.md). Three specifics:

```bash
pvesm add dellunity u480 \
    --dell-portal 192.168.1.21,192.168.1.22 \
    --dell-username admin --dell-password '...' \
    --dell-protocol fc --unity-pool pool_1 --content images,rootdir
```

- **`dell-portal` cannot be changed later.** Unity has a floating management
  IP that follows the master SP by design; that one address is enough. For
  extra insurance the comma form also accepts the SPs' fixed addresses.
- **After the first LUN maps, report three things**: `sg_inq /dev/sdX`
  (the vendor/product strings this plugin gates its cleanup sweeps on),
  whether the plugin's WWID matches `multipath -ll`, and — after the first
  `qm rollback` — whether the array holds a snapshot named
  `<volume>.pve-snap-pve.rollback*` (proof that `copyName` works; an
  array-named snapshot there instead must be reported at once).
- **A 302 in an error message is an authorization failure**, not a redirect:
  the `X-EMC-REST-CLIENT` header did not arrive. Look for a proxy between
  the node and the array.

### The array may already have a host object for this node

Before this plugin ever runs, an array usually has one — built by whoever
zoned the fabric — holding this node's WWPNs or IQN under a name of its own,
such as `tpepve-01-fc`. An initiator belongs to **one** host object, so the
plugin cannot register the same ports a second time under its own name.

On PowerStore it does not try. When there is no host under
`pve-{cluster}-{node}`, it asks the array which host holds this node's
initiators and uses that one, recording the name in
`/var/lib/pve-storage-dellemc/{storeid}-host`. Nothing is renamed, nothing is
removed, and no initiator is moved. You will see this once, in the journal:

```
Storage 'ps1': this node's initiators are already registered to host
'tpepve-01-fc' on the array, so that object is used instead of creating
'pve-pve-tpepve01'. It holds this node's ports and no others.
```

Two situations are refused rather than guessed at, both with the offending
name in the message:

- the host also holds **another host's** ports — a volume mapped to it would
  be visible to whatever that is;
- this node's ports are split across **two** host objects — a node is one
  host object, and merging them is your call.

Each node resolves its own host the first time it activates the storage, so
nothing has to be done per node.

---

## The first VM

### 5. A disk

```bash
pvesm alloc ps1 999 '' 8G
pvesm list ps1
```

**Expected:** a volume named `pve-ps1-999-disk0` (PowerStore) or
`pve-ps1-999-d0` (PowerVault, PowerFlex) on the array, mapped to this node,
with a device under `/dev/mapper`.

| What you see | What it means |
|---|---|
| `The device for volume ... did not appear within 60s` | the volume exists and is mapped, but no device arrived. The message carries the iSCSI session states; a session that is not `LOGGED_IN` cannot deliver a LUN |
| the volume is created and then deleted again | mapping failed, so the plugin rolled it back. The array's refusal is in the message |
| it works, but takes most of the timeout | check `multipath -ll` for paths in `failed faulty` |

### 6. Write to it, and read it back

```bash
dd if=/dev/urandom of=/dev/mapper/<wwid> bs=1M count=100 oflag=direct
dd if=/dev/mapper/<wwid> bs=1M count=100 iflag=direct | md5sum
```

This is the first proof that the device found is the volume created. Getting
this wrong means the WWID mapping is wrong, and the plugin would be writing to
whatever else answers.

### 7. A snapshot, and a rollback

```bash
qm create 999 --name firstrun --scsi0 ps1:8 --scsihw virtio-scsi-single
qm snapshot 999 before
qm rollback 999 before
qm listsnapshot 999
```

**Expected:** the snapshot appears on the array under
`<volume>.pve-snap-before` (PowerStore) or `<volume>-s-before` (PowerVault,
PowerFlex), and the rollback returns.

Rolling back to anything other than the **most recent** snapshot is refused on
purpose: Dell does not document what a restore does to snapshots taken after
the restore point, and this plugin will not let PVE keep listing restore
points the array may have discarded. If you establish what your array does,
`dell-rollback-any-snapshot 1` lifts it — and please say what you found.

### 8. A template and a linked clone

```bash
qm template 999
qm clone 999 1000 --name clone-of-firstrun
qm start 1000
```

**Expected:** the clone is instant — seconds, not minutes. If it takes minutes,
it was a full copy and the linked-clone path did not engage.

Then check the deletion order holds:

```bash
qm destroy 999      # expected to FAIL while the clone exists
qm destroy 1000     # the clone first
qm destroy 999      # now the template
```

The first must fail with a message naming the dependent clone. If it succeeds,
the array allowed a template with dependents to be deleted, and that is worth
reporting.

### 9. Delete everything, and look for what was left

```bash
qm destroy 1000; qm destroy 999
pvesm list ps1
multipath -ll
ls /dev/disk/by-id/ | grep -i <wwid-prefix>
```

**Expected:** nothing on the array, no multipath map, and no residual `sd`
paths. Leftover `sd` devices are silent until the next `multipathd` reload
fills the journal with `EBUSY`; see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).

---

## While it runs

Leave the storage configured and watch for a while:

```bash
journalctl -u pvestatd -f | grep dellemc
```

**Expected:** silence. This plugin only speaks up when something is wrong or
when a limit is close. Two lines are worth knowing:

- `OUTAGE - the array API has been unreachable for Ns` — the health path gave
  up. It reports elapsed time rather than a poll count, because PVE stops
  polling a storage it has marked inactive.
- `orphan cleanup: ... is not on this storage's array and is not tracked` —
  a device this plugin does not recognise. It is **reported, never removed**.
  Confirm it is not in use before touching it, and never with a system-wide
  flush.

---

## If it does not work

Collect this, and it will usually be enough to say what happened:

```bash
pveversion -v | head -5
perl -MPVE::Storage -e 'print PVE::Storage::APIVER, " ", PVE::Storage::APIAGE, "\n"'
cat /etc/pve/storage.cfg | sed 's/dell-password.*/dell-password ***/'
journalctl -u pvestatd --since -30min | grep -i dell
multipath -ll
iscsiadm -m session
sg_inq /dev/sdX | head -5
```

The array's own event log for the same period matters as much as any of it:
this plugin reports what the array told it, and the array usually said more.

`docs/TESTING.md` lists what is still inferred rather than read from Dell's
documentation. If a failure lands on one of those lines, that is the first
place to look.
