# IGD option ROM

An OVMF option ROM for IGD assignment, made of three EFI drivers:

- `IgdAssignmentDxe` (VfioIgdPkg): sets up the OpRegion and the guest DSM
  (BDSM);
- `PlatformGopPolicy` (VfioIgdPkg): provides the platform protocol required by
  the Intel GOP driver;
- `IntelGopDriver.efi`: the proprietary Intel GOP driver from the host firmware,
  for pre-OS display output.

## Pinned sources

| Component | Version |
|---|---|
| VfioIgdPkg | submodule `rom/VfioIgdPkg`, `067328df2554c865cc0078cb922357301c4c36c6` |
| EDK2 | `edk2-stable202608` (`2970e5699ba6267f3384ffab20f96647578aebc8`), cloned to `work/edk2` by `build.sh` |
| Toolchain | `rom/Dockerfile` (Debian trixie, GCC) |

EDK2 is pinned to the release used by `pve-edk2-firmware` 4.2026.08.

## Intel GOP driver

The GOP driver is not committed. Put it at `rom/local/IntelGopDriver.efi`.

1. Get the host firmware image, either from the vendor's BIOS update package or
   by reading the BIOS region on the host:

   ```bash
   flashrom -p internal --ifd -i bios -r bios.bin
   ```

2. Unpack it with `uefiextract` from
   [UEFITool NE](https://github.com/LongSoft/UEFITool/releases). The release
   binaries need a recent glibc; a container works:

   ```bash
   docker run --rm -u $(id -u):$(id -g) -v $PWD:/w -w /w debian:trixie ./uefiextract bios.bin all
   ```

3. Find the PE32 image containing the UTF-16 string `Intel(R) GOP Driver`:

   ```bash
   grep -rlaP 'I\x00n\x00t\x00e\x00l\x00\(\x00R\x00\)\x00 \x00G\x00O\x00P' bios.bin.dump --include body.bin
   ```

   It is usually the PE32 section of the `IntelGopDriver` file
   (`5BBA83E6-F027-4CA7-BFD0-16358CC9E123`). AMI firmware may instead wrap it
   as a GUID-subtyped section of a freeform file. Pick the innermost `body.bin`
   that starts with `MZ`.

Example (CWWK MINIPC-G12, AMI BIOS 5.26, 2023-06-07):

| Item | Value |
|---|---|
| Location | freeform file `A0327FE0-1FDA-4E5B-905D-B510C45A61D0`, section `380B6B4F-1454-41F2-A6D3-61D1333E8CB4` |
| GOP version | 21.0.1054 |
| Size | 189536 bytes |
| SHA256 | `919a2f3d8b7f90186aafd39cd3a8a5703975464658e71d7e1cc15be65847c3b8` |

The other sections of that freeform file (starting with `55 aa`) are legacy
VBIOS images and are not needed.

## Build

```bash
rom/build.sh [--gop FILE] [--variant NAME] [--release] OUTPUT.rom
```

- `--gop` adds `PlatformGopPolicy` and the GOP driver; without it the ROM only
  contains `IgdAssignmentDxe` and gives no pre-OS display output.
- `--variant NAME` applies `rom/patches/NAME/*.patch` to a copy of the
  submodule in `work/rom-build/NAME`; the submodule itself is not modified.
- The default is a DEBUG build, whose messages go to I/O port 0x402 (visible
  with QEMU `-debugcon file:debug.log -global isa-debugcon.iobase=0x402`).
- `--gop` and `OUTPUT.rom` must be inside the repository, which is mounted at
  `/src` in the build container. The ROM therefore does not embed the checkout
  location, and rebuilding produces a byte-identical ROM.

## Variants

| Variant | Description |
|---|---|
| none | upstream VfioIgdPkg: guest DSM allocated top-down below 4 GiB |
| `host-bdsm` | Gen11+: guest DSM placed at the host DSM address, falling back to the upstream allocation; fixes the stolen memory problem (see [docs/analysis.md](../docs/analysis.md#fix-in-the-option-rom)) |

## Prebuilt ROMs

`rom/prebuilt/` contains ROMs validated on specific machines. Each embeds the GOP
driver of that machine's firmware.

| File | Machine | IGD | Contents | Build | SHA256 |
|---|---|---|---|---|---|
| `cwwk-minipc-g12-host-bdsm.rom` | CWWK MINIPC-G12, Pentium Gold 8505, BIOS 5.26 | Alder Lake-P `8086:46b3` | VfioIgdPkg `067328d` + `host-bdsm`, GOP 21.0.1054 | DEBUG, EDK2 `edk2-stable202608` | `914c0b3e4c14a4545f4b788db711cb33e700b7f073db6f207d1063f4ac7904fb` |

Rebuild with:

```bash
rom/build.sh --gop rom/local/IntelGopDriver.efi --variant host-bdsm work/out/igd.rom
```
