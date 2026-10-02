# Stolen memory relocation in Gen11+ IGD passthrough

## Background

At boot, the host firmware reserves two regions of system memory for the IGD,
right below TOLUD:

- **GSM** (GTT Stolen Memory), holding the global GTT. Its base is in BGSM.
- **DSM** (Data Stolen Memory), used as VRAM before the OS driver loads and as
  "stolen memory" by the driver afterwards. Its base is in BDSM. GSM sits
  directly below DSM, so `BDSM = BGSM + GSM size`.

Part of the DSM is the **stolen reserved area**, described by `STOLEN_RESERVED`.
It is used by the hardware and its firmware (GuC/HuC WOPCM and similar). The
firmware also publishes an RMRR covering GSM and DSM, telling the OS that the
device needs these addresses mapped 1:1 in the IOMMU.

Relevant registers on Gen11+ devices and how QEMU (v11.0) handles them:

| Register | Location | Content | QEMU |
|---|---|---|---|
| GGC | PCI config 0x50 | GMS (DSM size), GGMS (GSM size) | passed through (emulated only with `x-igd-gms`) |
| BDSM | PCI config 0xC0, 64-bit | DSM base | emulated; 0 at reset, written by guest firmware |
| BDSM mirror | BAR0 + 0x1080C0 | DSM base | emulated, mirrors config 0xC0 |
| BGSM | BAR0 + 0x108100 | GSM base | passed through (host value) |
| STOLEN_RESERVED | BAR0 + 0x1082C0 | reserved area base (bits 63:20), size (bits 8:7: 1/2/4/8 MiB), enable (bit 0) | passed through (host value) |

## Root cause

The device needs guest physical addresses to equal host physical addresses
across its stolen memory, and the IGD assignment model does not provide that.

1. **The hardware uses host physical addresses.** The IGD and its
   microcontrollers access the stolen reserved area by the physical address
   programmed by the host firmware into locked registers, not through GTT
   entries written by the driver. These accesses go through the IOMMU; on bare
   metal the RMRR identity mapping makes them work.
2. **VFIO drops the identity mapping.** The host kernel marks graphics RMRRs as
   `direct-relaxable`, which allows the device to be assigned but means VFIO
   does not reproduce the 1:1 mapping. In the VM's IOMMU domain, every address
   the device emits is a guest physical address.
3. **QEMU relocates the DSM.** Through fw_cfg `etc/igd-bdsm-size`, QEMU asks the
   VM firmware to reserve a DSM-sized region anywhere below 4 GiB and to write
   its address to the emulated BDSM. VfioIgdPkg's `IgdAssignmentDxe` allocates
   it top-down, so the guest DSM ends up at an unrelated address. BGSM,
   `STOLEN_RESERVED` and the hardware keep the host layout.

Memory layout on the example machine (see
[Tested environment](../README.md#tested-environment); 60 MiB DSM, 8 MiB GSM,
2 MiB reserved area):

| Region | Host physical | Guest physical, relocated DSM | Guest physical, DSM at host address |
|---|---|---|---|
| GSM | `0x4c000000-0x4c7fffff` | not present | not present |
| DSM | `0x4c800000-0x503fffff` | `0xb8300000-0xbbefffff` | `0x4c800000-0x503fffff` |
| Reserved area (`STOLEN_RESERVED = 0x50200087`) | `0x50200000-0x503fffff` | `0x50200000-0x503fffff`, ordinary guest RAM | `0x50200000-0x503fffff`, inside the guest DSM |

## Consequences

### The guest driver rejects stolen memory

i915 reads the DSM base from BDSM (guest address) and the reserved area from
`STOLEN_RESERVED` (host address). Since the reserved area is not contained in
the DSM, `i915_gem_init_stolen()` logs

```text
i915 0000:00:02.0: [drm] *ERROR* Stolen reserved area [mem 0x50200000-0x503fffff] outside stolen memory [mem 0xb8300000-0xbbefffff]
```

and returns before setting up the stolen memory allocator, so nothing (FBC, the
firmware framebuffer takeover, ...) can use stolen memory.

### Device DMA into the reserved area misses the guest DSM

With a relocated DSM, the host addresses of the reserved area are, in the
guest, ordinary RAM outside the guest DSM. On the example machine (host kernel
7.0.14, pve-qemu-kvm 11.0.3) the host logged 125 IOMMU faults over two days,
all from `00:02.0`, all with fault reason 0x06 and all inside
`0x50200000-0x503fffff`:

```text
DMAR: [DMA Read NO_PASID] Request device [00:02.0] fault addr 0x50340000 [fault reason 0x06] PTE Read access is not set
```

| Fault address | Count |
|---|---|
| `0x50340000` | 43 |
| `0x50200000` | 28 |
| `0x50208000` | 6 |
| other `0x502xxxxx`-`0x503xxxxx` | 48 |

The faults coincide with the guest starting a Moonlight client (VAAPI decode
plus fullscreen presentation); a plain VAAPI H.264 encode/decode loop does not
trigger them.

### Display instability

The guest also logged display errors, on a 4K output driven by two joined
pipes:

```text
i915 0000:00:02.0: [drm] *ERROR* [CRTC:150:pipe A][PLANE:34:plane 1A] fault (CTL=0x92009000, SURF=0x2000, SURFLIVE=0x2000)
i915 0000:00:02.0: [drm] *ERROR* [CRTC:268:pipe B][PLANE:152:plane 1B] fault (CTL=0x92009000, SURF=0x2000, SURFLIVE=0x2000)
i915 0000:00:02.0: [drm] *ERROR* [CRTC:150:pipe A] flip_done timed out
i915 0000:00:02.0: [drm] *ERROR* [CRTC:150:pipe A] DSB 0 timed out waiting for idle (current head=0x100, head=0x0, tail=0x140)
```

With host kernel 6.17 / pve-qemu-kvm 10.1 the PLANE faults occurred without any
host DMAR faults, which suggests the same DMA then reached ordinary guest memory
instead of faulting. With the guest DSM at the host address, none of these
errors have occurred on the example machine.

## Fix in the option ROM

Placing the guest DSM at the host DSM address makes BDSM, the BDSM mirror and
`STOLEN_RESERVED` consistent, so i915 accepts and uses stolen memory, and the
device DMA into the reserved area lands inside the guest DSM: guest memory that
is reserved for the IGD and not used by the guest OS.

[rom/patches/host-bdsm](../rom/patches/host-bdsm) implements this in
`IgdAssignmentDxe` for devices with a 64-bit BDSM:

1. Read GGC from config space and BGSM from BAR0 + 0x108100 (temporarily
   enabling memory decoding).
2. Host DSM base = `BGSM[63:20] + GSM size`, where the GSM size is decoded from
   `GGC[7:6]` (0, 2, 4 or 8 MiB).
3. `AllocatePages (AllocateAddress, EfiReservedMemoryType, ...)` at that base,
   for the DSM size requested by QEMU.
4. If any step fails, use the original top-down allocation.

No QEMU change is needed: BGSM and `STOLEN_RESERVED` are already passed
through, and the BDSM mirror reflects whatever the firmware writes.

## Where the fix belongs

Rewriting what the guest reads from `STOLEN_RESERVED` (to
`guest BDSM + (host reserved base - host BDSM)`) is not a fix. It makes i915
accept stolen memory, but the device still accesses the reserved area at the
host address, outside the guest DSM.

The root cause is the placement policy, which QEMU defines. The ROM fix infers
the required address from registers that QEMU happens to pass through; QEMU
could provide it directly, check that it fits the guest memory map, and apply
to any firmware. The firmware still has to perform the reservation, so a QEMU
fix changes the contract rather than replacing the ROM change. The planned
approach is in [qemu/README.md](../qemu/README.md).

## Requirements and limitations

- The host DSM range must be guest RAM below 4 GiB and still free when the
  option ROM runs. The host DSM ends at TOLUD, so the guest's below-4 GiB RAM
  must extend past the host TOLUD. With QEMU defaults, i440fx keeps all RAM below
  4 GiB for VMs smaller than 3.5 GiB and 3 GiB otherwise; q35 keeps all RAM below
  4 GiB for VMs smaller than 2.75 GiB and 2 GiB otherwise. On the example machine
  the host DSM ends at `0x50400000` (1.25 GiB).
- When the allocation at the host address fails, the ROM silently falls back to
  the relocated DSM; the only trace is a debug message on I/O port 0x402. Check
  the guest BDSM after boot.
- The host DSM base is derived as BGSM + GSM size, which holds on Intel client
  platforms. `STOLEN_RESERVED` is printed in the debug output for cross-checking.
- The guest learns the host physical address of the stolen memory. Both BGSM and
  `STOLEN_RESERVED` already expose it.

## Verification

Host (VM running):

```bash
setpci -s 00:02.0 c0.L c4.L     # host BDSM (bit 0 is the lock bit)
journalctl -k | grep 'Request device \[00:02.0\]'
```

Guest:

```bash
setpci -s 00:02.0 c0.L c4.L     # must equal the host BDSM
intel_reg read 0x1080c0 0x108100 0x1082c0
grep -i 'stolen' /proc/iomem
journalctl -b -k | grep -Ei 'stolen|plane.*fault|flip_done|DSB'
```

Expected with the fix: guest BDSM equals the host BDSM, the `STOLEN_RESERVED`
base lies inside `Graphics Stolen Memory` in `/proc/iomem`, no
`Stolen reserved area` error, and no DMAR faults from `00:02.0` on the host.
`scripts/collect-host.sh` and `scripts/collect-guest.sh` gather all of this.
