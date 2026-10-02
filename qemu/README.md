# QEMU

The problem is currently fixed in the option ROM (see
[docs/analysis.md](../docs/analysis.md)). The DSM placement policy belongs in
QEMU, though: QEMU knows the host layout, controls the guest memory map, and
defines the contract the VM firmware follows. This directory is for that fix.
There are no patches yet; `qemu/patches/` is empty.

## Planned approach

Make QEMU tell the firmware where the DSM must go, instead of letting the
firmware pick any address.

1. In `vfio_pci_igd_config_quirk()` (`hw/vfio/igd.c`), for Gen11+ devices, read
   the host BDSM from config 0xC0 before it is emulated, and mask the lock bit.
2. Check that `[host BDSM, host BDSM + DSM size)` lies within guest RAM below
   4 GiB (`below_4g_mem_size`). If it does not, report it and keep the current
   behavior, or fail when explicitly requested.
3. Publish the address in a new fw_cfg file, e.g. `etc/igd-bdsm-base`
   (uint64, little endian), next to `etc/igd-bdsm-size`, and extend
   `docs/igd-assign.txt`: when the file is present, the firmware must reserve the
   stolen memory region at that address.
4. Control it with a device property (enabled by default for Gen11+ when the
   range fits), so the old behavior stays available.

Firmware side: `IgdAssignmentDxe` allocates at `etc/igd-bdsm-base` when present
and keeps the current BGSM-based inference as a fallback for QEMU versions
without it.

Not planned: rewriting guest reads of `STOLEN_RESERVED` (BAR0 + 0x1082C0). It
hides the inconsistency from i915 but leaves the device DMA outside the guest
DSM.

Open questions:

- whether QEMU should also preset or lock the emulated BDSM to the host value;
- how to handle hosts whose DSM lies above the guest's below-4 GiB RAM (e.g.
  q35 with more than 2.75 GiB of RAM and a host TOLUD above 2 GiB);
- whether pre-Gen11 devices (32-bit BDSM) are affected in the same way.

## Workflow

Patches are kept as files in `qemu/patches/*.patch` and applied on top of the
pve-qemu-kvm version installed on the host:

```bash
scripts/fetch-pve-qemu.sh --from-host <pve-host>   # read the installed pve-qemu-kvm version
scripts/fetch-pve-qemu.sh 11.0.3-3                 # or name it explicitly
```

The script checks out, in `work/pve-qemu-<version>`:

- the `pve-qemu` commit `bump version to <version>`;
- the QEMU submodule commit of that release, fetched through its tag from
  `mirror_qemu` (e.g. `v11.0.3`);
- `qemu/patches/*.patch` copied to `debian/patches/local/` and appended to
  `debian/patches/series`, after the Proxmox patches.

Build the package from there in a container, never on the PVE host.

## IGD handling in QEMU v11.0

`hw/vfio/igd.c`, for Gen11+ devices:

| Register | Handling |
|---|---|
| PCI config 0xC0 (BDSM, 64-bit) | emulated, 0 at reset, writable by guest firmware |
| PCI config 0x50 (GGC) | passed through; emulated only with `x-igd-gms` |
| PCI config 0xFC (ASLS) | emulated, written by guest firmware |
| BAR0 + 0x1080C0 (BDSM mirror) | `vfio-igd-bdsm-quirk`, mirrors config 0xC0 |
| BAR0 + 0x108040 (GGC mirror) | mirrors config 0x50 only with `x-igd-gms` |
| BAR0 + 0x108100 (BGSM) | passed through |
| BAR0 + 0x1082C0 (STOLEN_RESERVED) | passed through |

fw_cfg files: `etc/igd-opregion` (OpRegion contents, with `x-igd-opregion=on`)
and `etc/igd-bdsm-size` (DSM size the firmware must reserve).
