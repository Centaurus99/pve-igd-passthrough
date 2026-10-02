#!/bin/bash
# Build an IGD option ROM from the pinned VfioIgdPkg submodule inside a container.
#
#   rom/build.sh [--gop FILE] [--variant NAME] [--release] OUTPUT.rom
#
# --variant NAME applies rom/patches/NAME/*.patch on top of the submodule
# (default: no patches). The submodule itself is never modified.
set -euo pipefail

EDK2_URL=https://github.com/tianocore/edk2.git
EDK2_TAG=edk2-stable202608
EDK2_COMMIT=2970e5699ba6267f3384ffab20f96647578aebc8
EDK2_SUBMODULES=(
    BaseTools/Source/C/BrotliCompress/brotli
    MdeModulePkg/Library/BrotliCustomDecompressLib/brotli
    MdePkg/Library/MipiSysTLib/mipisyst
    MdePkg/Library/BaseFdtLib/libfdt
)
IMAGE=pve-igd-edk2-builder:trixie

REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=$REPO/work
EDK2_DIR=$WORK/edk2

gop=
variant=
release=
output=

while [ $# -gt 0 ]; do
    case $1 in
        -g|--gop) gop=$(realpath "$2"); shift ;;
        -v|--variant) variant=$2; shift ;;
        -r|--release) release=--release ;;
        -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *) output=$1 ;;
    esac
    shift
done
[ -n "$output" ] || { echo "Error: output file is required" >&2; exit 1; }
output=$(realpath -m "$output")

case $gop in
    "") ;;
    $REPO/*) ;;
    *) echo "Error: --gop must be inside $REPO (it is bind-mounted)" >&2; exit 1 ;;
esac
case $output in
    $REPO/*) ;;
    *) echo "Error: output must be inside $REPO (it is bind-mounted)" >&2; exit 1 ;;
esac

# Pinned EDK2 checkout
if [ ! -d "$EDK2_DIR/.git" ]; then
    git clone --depth 1 -b "$EDK2_TAG" "$EDK2_URL" "$EDK2_DIR"
    git -C "$EDK2_DIR" submodule update --init --depth 1 "${EDK2_SUBMODULES[@]}"
fi
actual=$(git -C "$EDK2_DIR" rev-parse HEAD)
if [ "$actual" != "$EDK2_COMMIT" ]; then
    echo "Error: $EDK2_DIR is at $actual, expected $EDK2_COMMIT ($EDK2_TAG)" >&2
    exit 1
fi

# Stage VfioIgdPkg (+ variant patches) into a per-variant workspace
name=${variant:-standard}
stage=$WORK/rom-build/$name
rm -rf "$stage"
mkdir -p "$stage/VfioIgdPkg"
git -C "$REPO/rom/VfioIgdPkg" archive HEAD | tar -x -C "$stage/VfioIgdPkg"
if [ -n "$variant" ]; then
    patches=("$REPO"/rom/patches/"$variant"/*.patch)
    [ -e "${patches[0]}" ] || { echo "Error: no patches in rom/patches/$variant" >&2; exit 1; }
    for p in "${patches[@]}"; do
        echo "Applying $(basename "$p")"
        patch -d "$stage/VfioIgdPkg" -p1 --quiet < "$p"
    done
fi

docker build -q -t "$IMAGE" "$REPO/rom" >/dev/null

# Mount the repository at a fixed path so that build paths embedded in the
# images do not depend on the checkout location.
SRC=/src
in_src() { [ -n "$1" ] && echo "$SRC/${1#"$REPO"/}"; }

docker run --rm -u "$(id -u):$(id -g)" -v "$REPO:$SRC" -w "$(in_src "$stage")" \
    -e EDK2_DIR="$(in_src "$EDK2_DIR")" -e STAGE="$(in_src "$stage")" \
    -e GOP="$(in_src "$gop")" -e RELEASE="$release" -e OUTPUT="$(in_src "$output")" \
    "$IMAGE" bash -ec '
        export WORKSPACE=$STAGE
        export PACKAGES_PATH=$EDK2_DIR:$STAGE
        export EDK_TOOLS_PATH=$EDK2_DIR/BaseTools
        [ -x $EDK2_DIR/BaseTools/Source/C/bin/EfiRom ] || make -s -C $EDK2_DIR/BaseTools -j"$(nproc)"
        . $EDK2_DIR/edksetup.sh >/dev/null
        ./VfioIgdPkg/build.sh $RELEASE ${GOP:+--gop "$GOP"} "$OUTPUT"
    '

sha256sum "$output"
