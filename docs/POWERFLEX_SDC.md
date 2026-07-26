# PowerFlex host access: SDC and NVMe/TCP

繁體中文：[POWERFLEX_SDC_zh-TW.md](POWERFLEX_SDC_zh-TW.md)

PowerFlex volumes do not arrive as SCSI LUNs. There are two ways a Proxmox VE
node can see them, and the choice has consequences that outlive this plugin.

| | SDC | NVMe/TCP |
|---|---|---|
| Host component | Dell's `scini` kernel module | in-kernel `nvme_tcp` |
| PowerFlex version | 3.x and 4.x | 4.0 and later (needs SDT) |
| Devices | `/dev/scini*`, `/dev/disk/by-id/emc-vol-*` | `/dev/nvme*n*` |
| Multipathing | the SDC's own | NVMe native (ANA) |
| Survives a kernel upgrade | only if the module rebuilds | yes |
| Installed by this plugin | **no** | nothing to install |

`dell-protocol nvme` is the default for that last row alone.

## Why the default is NVMe/TCP

The SDC is a proprietary kernel module that must match the running kernel.
Dell does not ship a prebuilt `scini` for Proxmox VE's kernel, so it is
compiled on the node — which means a kernel upgrade can leave a node with no
storage until the module is rebuilt.

Dell's own guidance for Proxmox VE (see the KB below) states support as:

- **Proxmox VE 8.x** (Debian 12): PowerFlex 4.5.3 or 3.6.5 and later
- **Proxmox VE 9.x** (Debian 13): *planned* for PowerFlex 5.1.x

This plugin requires Proxmox VE 9.1, which is in the second row. If you intend
to use the SDC there, confirm the current support status with Dell first.

NVMe/TCP has none of these problems: the initiator is in the kernel Proxmox
already ships, and an upgrade cannot break it.

## Official Dell references

Bookmark these; they are the authority, and they change.

| What | Where |
|---|---|
| **SDC on Proxmox VE** — the PVE-specific procedure | [KB 000466868](https://www.dell.com/support/kbdoc/zh-tw/000466868/powerflex-%E5%A6%82%E4%BD%95%E5%9C%A8-proxmox-ve-%E4%B8%8A%E8%A8%AD%E5%AE%9A-powerflex-sdc) |
| **Support matrix** — supported operating systems and kernels | [E-Lab Navigator: PowerFlex_OS.pdf](https://elabnavigator.dell.com/vault/pdf/PowerFlex_OS.pdf) |
| **Is my kernel supported?** | [KB 000332118](https://www.dell.com/support/kbdoc/en-us/000332118/powerflex-sdc-how-to-determine-kernel-version-is-supported) |
| **On-demand driver compilation** | [KB 000224134](https://www.dell.com/support/kbdoc/en-us/000224134/how-to-on-demand-compilation-of-the-powerflex-sdc-driver) |
| Prebuilt `.ko` files, by OS and PowerFlex version | [mft.dell.com](https://mft.dell.com/) |
| NVMe/TCP overview | [PowerFlex 4.5.x Technical Overview](https://www.dell.com/support/manuals/en-us/scaleio/flex-software-to-45x/nvme-over-tcp-overview) |

Dell notes that the E-Lab matrix does not always list every kernel a
distribution has released, and gives a prefix rule: a kernel is supported if
its version prefix matches a listed one — for example `4.18.0-553` covers
`4.18.0-553.51.1.el8_10.x86_64`.

## What this plugin does with either path

One VM disk is **one PowerFlex volume**, created through the REST API. There
is no LVM layer, no shared large volume carved up locally, and no volume
group on the host: the array's own snapshots, clones and thin provisioning
act on a single VM disk as their natural unit, and the SDC (or the NVMe
initiator) only presents that volume as a block device.

That is worth stating because Dell's Proxmox VE KB includes an LVM step. It
is for operators who put LVM *on top of* scini devices, which this plugin
does not do. The LVM setting that matters here is the opposite one, and it is
the same issue the SAN families have: the host's LVM scanner can auto-activate
a volume group that lives *inside* a guest disk, which then blocks the volume
from being deleted. See the LVM section of
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## If you choose the SDC anyway

This plugin does not install, configure or repair the SDC. It only checks
whether the module is loaded and says so plainly when it is not. Follow
[KB 000466868](https://www.dell.com/support/kbdoc/zh-tw/000466868/powerflex-%E5%A6%82%E4%BD%95%E5%9C%A8-proxmox-ve-%E4%B8%8A%E8%A8%AD%E5%AE%9A-powerflex-sdc);
the shape of it is:

```bash
# Build tools and the matching headers. Keep proxmox-default-headers
# installed: it is what lets the driver rebuild itself after a kernel update.
apt install gcc make proxmox-default-headers

# Allow on-demand compilation
mkdir -p /etc/emc/scaleio/scini_sync
touch /etc/emc/scaleio/scini_sync/.build_scini

# Install the SDC, pointing it at the MDMs
MDM_IP=<mdm1>,<mdm2> dpkg -i EMC-ScaleIO-sdc-*.Debian*.x86_64.deb
```

Caveats Dell calls out for Proxmox VE:

- **Secure Boot must be disabled**, since the compiled module is unsigned.
- The first install fails until on-demand compilation is enabled.
- Service ordering has to be arranged so `scini` is up before storage is used.
- LVM needs the `scini` device type added if you intend to run LVM on top of
  these devices. This plugin does not, so the setting that matters here is a
  `global_filter` that keeps the host from activating volume groups found
  inside guest disks.
- On Proxmox VE 8.x, container and VM migrations can fail with device-mapper
  errors.

### Checking the state on a node

```bash
lsmod | grep scini                       # is the module loaded?
systemctl status scini                   # and the service?
/bin/emc/scaleio/drv_cfg --query_guid    # this node's SDC GUID
/bin/emc/scaleio/drv_cfg --query_vols    # volumes the SDC currently sees
uname -r                                 # the kernel to check against the matrix
```

If the module is missing after a kernel upgrade, the driver cache and the
build script are where to look:

```bash
ls /bin/emc/scaleio/scini_sync/driver_cache/
/bin/emc/scaleio/scini_sync/driver_sync.sh
```

## If you choose NVMe/TCP

Requires PowerFlex 4.0 or later, with SDT configured on the storage side.

```bash
apt install nvme-cli
modprobe nvme_tcp

# This node's NQN. The array must know it before it will map anything.
cat /etc/nvme/hostnqn

nvme list-subsys        # sessions to the SDT
nvme list               # namespaces currently attached
```

The plugin connects to the SDTs the array publishes during
`activate_storage`, registers this node's NQN as a host if it is not already
registered, and waits for the namespace after mapping a volume.

## NVMe/TCP multipathing

Paths are handled by NVMe native multipathing (ANA), not dm-multipath. Three
things decide whether it actually works.

**1. Native multipathing must be on.** Without it each path appears as its own
block device, and two of them can be written through at once.

```bash
cat /sys/module/nvme_core/parameters/multipath     # must be Y
```

If it is N, add `nvme_core.multipath=Y` to the kernel command line and reboot.
The plugin warns at activation when it finds it disabled.

**2. Connect to every SDT.** One session is not multipathing. The plugin
connects to every target the array publishes during `activate_storage` and
warns if it could only reach some of them.

```bash
nvme list-subsys        # one subsystem, several paths, with ANA states
```

Healthy output shows several paths with `optimized` or `non-optimized` ANA
state. A path in `inaccessible` state is the NVMe equivalent of a failed path.

**3. Timeouts must be finite.** This is the same trap as `no_path_retry queue`
on the SAN families: with every path down, I/O that is retried forever puts
processes into uninterruptible sleep and the node has to be power-cycled.

| Setting | Kernel default | This plugin | Equivalent to |
|---|---|---|---|
| `ctrl-loss-tmo` | 600 s | **60 s** (`pflex-nvme-ctrl-loss-tmo`) | `no_path_retry` |
| `reconnect-delay` | 10 s | 10 s | — |
| `keep-alive-tmo` | 5 s | 5 s | path checker interval |

The plugin passes these on every `nvme connect`. Raise
`pflex-nvme-ctrl-loss-tmo` only if a brief total path loss is expected and
queuing is genuinely preferable to an I/O error.

```bash
# what a controller is actually using
cat /sys/class/nvme/nvme0/ctrl_loss_tmo
cat /sys/class/nvme/nvme0/reconnect_delay
```


One rule from Dell worth repeating: **a volume cannot be served to SDC hosts
and NVMe hosts at the same time.** A cluster can use both methods, but not for
the same volume — so do not point two storages with different
`dell-protocol` values at the same volumes.
