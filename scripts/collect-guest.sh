#!/bin/bash
# Collect guest-side IGD state over ssh (read-only commands only).
#
#   scripts/collect-guest.sh SSH_TARGET
#
# Needs root (or passwordless sudo) and intel-gpu-tools in the guest.
set -euo pipefail

TARGET=${1:?usage: $0 SSH_TARGET}

ssh -o BatchMode=yes "$TARGET" bash -s <<'EOF'
section() { printf '\n### %s\n' "$*"; }
SUDO=; [ "$(id -u)" = 0 ] || SUDO=sudo

section versions
uname -r
uptime

section "IGD 00:02.0 config"
echo "GGC(50) BDSM(c0) BDSM_HI(c4) ASLS(fc):"
$SUDO setpci -s 00:02.0 50.L c0.L c4.L fc.L | tr '\n' ' '; echo

section "IGD BAR0 MMIO"
for r in 0x1080c0 0x1080c4 0x108100 0x108104 0x1082c0 0x1082c4; do
    printf '%s: ' "$r"
    $SUDO intel_reg read "$r" 2>/dev/null | awk '{print $NF}'
done

section "stolen in /proc/iomem"
$SUDO grep -iE 'stolen|^[0-9a-f]+-[0-9a-f]+ : Reserved' /proc/iomem | head -10

section "i915 kernel log (this boot)"
$SUDO journalctl -b -k --no-pager -o short-iso \
    | grep -Ei 'stolen|\bfault\b|flip_done|DSB|gpu hang|\breset|i915.*(error|warn)|GuC|HuC' \
    | grep -v 'Power-on or device reset' | head -40
echo "PLANE fault lines: $($SUDO journalctl -b -k --no-pager | grep -ci 'PLANE.*fault' || true)"
EOF
