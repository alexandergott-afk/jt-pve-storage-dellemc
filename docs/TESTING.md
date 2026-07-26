# Testing and Hardware Verification Status

> **Status: skeleton (Phase 0).** 繁體中文：[TESTING_zh-TW.md](TESTING_zh-TW.md)

## Hardware verification status

Nothing in this project has been verified against a physical PowerStore yet.
Every item below is marked `NOT VERIFIED ON HARDWARE` until it has been
executed on a real array and the result recorded here with the PowerStore OS
version it was observed on.

| Item | Status |
|---|---|
| REST endpoint paths and response field names | NOT VERIFIED ON HARDWARE |
| Authentication flow (`login_session`, `DELL-EMC-TOKEN`) | NOT VERIFIED ON HARDWARE |
| SCSI vendor / product strings used for multipath matching | NOT VERIFIED ON HARDWARE |
| WWN to multipath WWID conversion | NOT VERIFIED ON HARDWARE |
| Volume name length and character limits | NOT VERIFIED ON HARDWARE |
| LUN ID assignment behaviour | NOT VERIFIED ON HARDWARE |
| Fibre Channel data path | NOT VERIFIED ON HARDWARE |
| NVMe-TCP data path | out of scope for 1.0 |

## Automated checks

```bash
make syntax                  # perl -c on every module and script
make unit                    # t/*.t
make check-multipath-flush   # fails on any system-wide multipath flush
make test                    # all of the above
```

## Manual test matrix

The full 26-item matrix (install, cluster consistency, capacity reporting,
array-offline behaviour, disk lifecycle, snapshots, templates and clones,
containers, live migration, path failure, reboot recovery, orphan reaping,
LUN ID growth, FC, PVE upgrade) is defined in chapter 12 of
`jt-pve-storage-dellemc.md` and gets recorded here as each item is executed.
