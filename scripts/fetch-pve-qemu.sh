#!/bin/bash
# Fetch the pve-qemu packaging repo and the matching QEMU source for a given
# pve-qemu-kvm version, then apply qemu/patches/*.patch to the QEMU tree.
#
#   scripts/fetch-pve-qemu.sh [VERSION | --from-host SSH_HOST] [DEST]
#
# VERSION is a pve-qemu-kvm package version such as 11.0.3-3.
# --from-host reads the installed version from the PVE host (read-only).
# DEST defaults to work/pve-qemu-VERSION.
set -euo pipefail

PVE_QEMU_URL=https://git.proxmox.com/git/pve-qemu.git
QEMU_MIRROR_URL=https://git.proxmox.com/git/mirror_qemu.git

REPO=$(cd "$(dirname "$0")/.." && pwd)

if [ "${1:-}" = --from-host ]; then
    version=$(ssh -o BatchMode=yes "${2:?--from-host needs SSH_HOST}" \
        dpkg-query -W -f '\${Version}' pve-qemu-kvm)
    shift 2
else
    version=${1:?usage: $0 [VERSION | --from-host SSH_HOST] [DEST]}
    shift
fi
dest=${1:-$REPO/work/pve-qemu-$version}

echo "pve-qemu-kvm $version -> $dest"
if [ ! -d "$dest/.git" ]; then
    git clone -q "$PVE_QEMU_URL" "$dest"
fi
cd "$dest"
git fetch -q origin

commit=$(git log --all --format=%H --grep="^bump version to $version\$" | head -1)
[ -n "$commit" ] || { echo "Error: no 'bump version to $version' commit" >&2; exit 1; }
git checkout -q "$commit"
qemu_sha=$(git ls-tree "$commit" qemu | awk '{print $3}')
echo "pve-qemu commit: $commit"
echo "qemu submodule:  $qemu_sha"

# mirror_qemu does not serve unadvertised objects; fetch the tag pointing at it
tag=$(git ls-remote "$QEMU_MIRROR_URL" | awk -v s="$qemu_sha" '$1 == s && $2 ~ /\^\{\}$/ {sub(/\^\{\}$/, "", $2); print $2; exit}')
rm -rf qemu
git init -q qemu
if [ -n "$tag" ]; then
    echo "qemu tag:        ${tag#refs/tags/}"
    git -C qemu fetch -q --depth 1 "$QEMU_MIRROR_URL" "$tag"
else
    echo "qemu tag:        (none, fetching full history)"
    git -C qemu fetch -q "$QEMU_MIRROR_URL"
fi
git -C qemu checkout -q "$qemu_sha"

# Queue local patches after the PVE ones; the deb build applies the series
shopt -s nullglob
patches=("$REPO"/qemu/patches/*.patch)
mkdir -p debian/patches/local
for p in "${patches[@]}"; do
    echo "Queueing local/$(basename "$p")"
    cp "$p" debian/patches/local/
    grep -qxF "local/$(basename "$p")" debian/patches/series \
        || echo "local/$(basename "$p")" >> debian/patches/series
done
[ ${#patches[@]} -gt 0 ] || echo "No patches in qemu/patches"
