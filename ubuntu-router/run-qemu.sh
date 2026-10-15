#!/bin/bash
#
# Boot a built image in QEMU for testing (the image itself is not modified).
#
#   eth0 (WAN): QEMU user network, DHCP from QEMU
#   eth1 (LAN): QEMU user network 192.168.1.0/24, host port 2222 -> router 192.168.1.1:22
#
# Usage: ./run-qemu.sh [--bios] IMAGE      (UEFI by default; Ctrl-A X quits)

set -euo pipefail

FIRMWARE=uefi
[[ "${1:-}" == --bios ]] && { FIRMWARE=bios; shift; }
IMAGE="${1:?usage: $0 [--bios] IMAGE(.img|.img.zst)}"
SSH_PORT="${SSH_PORT:-2222}"

if [[ "$IMAGE" == *.zst ]]; then
    raw="${TMPDIR:-/tmp}/$(basename "${IMAGE%.zst}")"
    [[ -f "$raw" ]] || zstd -dc "$IMAGE" > "$raw"
    IMAGE="$raw"
fi

# shellcheck disable=SC2054  # commas are QEMU option syntax
args=(
    -m 1024 -smp 2
    -nographic
    -drive "file=$IMAGE,format=raw,if=virtio,snapshot=on"
    -netdev user,id=wan
    -device virtio-net-pci,netdev=wan
    -netdev "user,id=lan,net=192.168.1.0/24,host=192.168.1.254,dhcpstart=192.168.1.100,hostfwd=tcp::${SSH_PORT}-192.168.1.1:22"
    -device virtio-net-pci,netdev=lan
)
[[ -e /dev/kvm ]] && args+=(-enable-kvm -cpu host)

if [[ $FIRMWARE == uefi ]]; then
    ovmf=""
    for f in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/qemu/OVMF.fd; do
        [[ -f "$f" ]] && { ovmf="$f"; break; }
    done
    [[ -n "$ovmf" ]] || { echo "OVMF not found (apt install ovmf)" >&2; exit 1; }
    args+=(-bios "$ovmf")
fi

echo "Booting $IMAGE ($FIRMWARE). SSH: ssh -p $SSH_PORT admin@localhost"
exec qemu-system-x86_64 "${args[@]}"
