# pve-igd-passthrough

Fixes and tooling for passing an Intel Gen11+ integrated GPU (IGD) through to a
Proxmox VE virtual machine with OVMF, with the guest driving the physical
display outputs.

## Problem

With the IGD assigned to a VM, the guest shows:

- an i915 error at boot, after which i915 stops using stolen memory:

  ```text
  i915 0000:00:02.0: [drm] *ERROR* Stolen reserved area [mem 0x50200000-0x503fffff] outside stolen memory [mem 0xb8300000-0xbbefffff]
  ```

- IOMMU faults on the host for device DMA into the stolen reserved area,
  typically while a Moonlight client is running in the guest:

  ```text
  DMAR: [DMA Read NO_PASID] Request device [00:02.0] fault addr 0x50340000 [fault reason 0x06] PTE Read access is not set
  ```

- display instability: `[PLANE:...] fault`, `flip_done timed out`,
  `DSB ... timed out`.

## Root cause

The device needs guest physical addresses to equal host physical addresses
across its stolen memory, and the IGD assignment model does not provide that.

- The IGD hardware and its firmware (GuC/HuC) access the **stolen reserved
  area** inside the Data Stolen Memory (DSM) by host physical address, taken
  from registers locked by the host firmware. These accesses go through the
  IOMMU. On bare metal, an RMRR makes the IOMMU map the stolen range 1:1.
- VFIO treats the IGD's RMRR as relaxable and does not keep that 1:1 mapping;
  in the VM's IOMMU domain, device addresses are guest physical addresses.
- QEMU treats the DSM as relocatable: it asks the VM firmware to reserve the DSM
  anywhere below 4 GiB and emulates the BDSM register, while `STOLEN_RESERVED`
  (BAR0 + 0x1082C0) and the hardware keep using the host address.

The guest driver therefore sees an inconsistent layout, and the device DMA into
the reserved area misses the guest DSM. Details and evidence are in
[docs/analysis.md](docs/analysis.md).

## Status

- **Option ROM: fixed.** The VfioIgdPkg patch
  [rom/patches/host-bdsm](rom/patches/host-bdsm) places the guest DSM at the host
  DSM address on Gen11+ devices, deriving that address from registers QEMU
  already passes through. No QEMU change is needed. On the example machine the
  i915 error, the DMAR faults and the display errors are gone.
- **QEMU: planned.** The placement policy belongs in QEMU, which knows the host
  layout and controls the guest memory map. No patch yet; the intended approach
  is described in [qemu/README.md](qemu/README.md).

## Usage

1. Extract `IntelGopDriver.efi` from the host firmware and save it as
   `rom/local/IntelGopDriver.efi` (see
   [rom/README.md](rom/README.md#intel-gop-driver)).

2. Build the option ROM (requires Docker):

   ```bash
   git submodule update --init
   rom/build.sh --gop rom/local/IntelGopDriver.efi --variant host-bdsm work/out/igd.rom
   ```

3. Install it on the PVE host and attach it to the VM:

   ```bash
   scp work/out/igd.rom <pve-host>:/usr/share/kvm/igd-host-bdsm.rom
   ssh <pve-host> qm set <vmid> --hostpci0 0000:00:02.0,legacy-igd=1,romfile=igd-host-bdsm.rom
   ```

   The IGD-related VM settings used with this ROM:

   ```text
   bios: ovmf
   machine: pc-i440fx-<version>
   vga: none
   hostpci0: 0000:00:02.0,legacy-igd=1,romfile=igd-host-bdsm.rom
   args: -set device.hostpci0.addr=02.0 -set device.hostpci0.x-igd-opregion=on
   ```

4. Restart the VM and verify:

   ```bash
   scripts/collect-guest.sh root@<guest>        # guest BDSM equals the host BDSM, no stolen error
   scripts/collect-host.sh <pve-host> <vmid>    # no DMAR faults from 00:02.0
   ```

A prebuilt ROM for the example machine is available in
[rom/prebuilt](rom/README.md#prebuilt-roms). It embeds the GOP driver from that
machine's firmware; for other machines, build the ROM with your own GOP driver.

## Scope

- Gen11+ IGDs with a 64-bit BDSM register: Ice Lake, Elkhart Lake, Jasper Lake,
  Tiger Lake, Rocket Lake, Alder Lake (S/P/N) and Raptor Lake (S/U/P). Meteor
  Lake and newer access stolen memory through LMEMBAR and have no BDSM.
- The guest needs RAM covering the host DSM range below 4 GiB; see
  [Requirements and limitations](docs/analysis.md#requirements-and-limitations).

## Tested environment

The example machine referred to throughout the documentation:

| Item | Version |
|---|---|
| Machine | CWWK MINIPC-G12, Intel Pentium Gold 8505, AMI BIOS 5.26 |
| IGD | Alder Lake-P `8086:46b3` |
| Host | Proxmox VE 9.1.6, kernel 7.0.14-19-pve |
| QEMU / OVMF | pve-qemu-kvm 11.0.3-3, pve-edk2-firmware 4.2026.08-1 |
| Guest | Ubuntu 24.04, kernel 7.0.0-34-generic, i915 |

## Repository layout

```text
rom/        IGD option ROM: VfioIgdPkg submodule, patches, containerized build, prebuilt ROMs
qemu/       planned QEMU fix and the workflow for patching the installed pve-qemu-kvm
scripts/    fetch-pve-qemu.sh, collect-host.sh, collect-guest.sh
docs/       analysis.md
```

`work/` (git-ignored) holds the EDK2 and pve-qemu checkouts, firmware dumps and
build outputs. Everything is built in containers on a workstation; on the PVE
host only read-only state collection and the ROM deployment are performed.
