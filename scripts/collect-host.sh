#!/bin/bash
# Collect host-side IGD state from a PVE host over ssh (read-only).
#
#   scripts/collect-host.sh SSH_HOST VMID [SINCE]
#
# SINCE is passed to journalctl --since for the DMAR fault summary
# (default: start time of the running VM).
set -euo pipefail

HOST=${1:?usage: $0 SSH_HOST VMID [SINCE]}
VMID=${2:?usage: $0 SSH_HOST VMID [SINCE]}
SINCE=${3:-}

ssh -o BatchMode=yes "$HOST" VMID="$VMID" SINCE="'$SINCE'" bash -s <<'EOF'
section() { printf '\n### %s\n' "$*"; }

section versions
pveversion | head -1
dpkg-query -W -f '${Package} ${Version}\n' pve-qemu-kvm pve-edk2-firmware-ovmf 2>/dev/null
uname -r
cat /proc/cmdline

section "qm status / config"
qm status "$VMID"
qm config "$VMID"

section "romfile sha256"
rom=$(qm config "$VMID" | sed -n 's/^hostpci0:.*romfile=\([^,]*\).*/\1/p')
[ -n "$rom" ] && sha256sum "/usr/share/kvm/$rom"

section "IGD 00:02.0"
lspci -nnk -s 00:02.0
echo "GGC(50) BDSM(c0) BDSM_HI(c4) ASLS(fc):"
setpci -s 00:02.0 50.L c0.L c4.L fc.L | tr '\n' ' '; echo
cat /sys/kernel/iommu_groups/"$(basename "$(readlink /sys/bus/pci/devices/0000:00:02.0/iommu_group)")"/reserved_regions

section "DMAR faults from 00:02.0"
if [ -z "$SINCE" ]; then
    pid=$(cat /var/run/qemu-server/"$VMID".pid 2>/dev/null || true)
    [ -n "$pid" ] && SINCE=$(date -d "$(ps -o lstart= -p "$pid")" '+%Y-%m-%d %H:%M:%S')
fi
echo "since: ${SINCE:-boot}"
faults=$(journalctl -k --no-pager -o short-iso ${SINCE:+--since "$SINCE"} \
    | grep 'Request device \[00:02.0\]' \
    | sed -E 's/^([^ ]+) .*fault addr (0x[0-9a-f]+) \[fault reason (0x[0-9a-f]+)\].*/\1 \2 \3/' || true)
echo "total: $(grep -c . <<< "$faults")"
awk 'NF {print $2}' <<< "$faults" | sort | uniq -c | sort -rn | head -20
head -3 <<< "$faults"
EOF
