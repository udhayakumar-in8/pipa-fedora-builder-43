#!/bin/bash
#
# Flash an Ubuntu Router image to a disk (SSD, NVMe, USB stick, ...).
#
#   - refuses mounted disks and the disk the running system lives on
#   - verifies the image checksum when the .sha256 file is next to it
#   - writes with O_DIRECT + fsync, optionally verifies the written data
#   - moves the backup GPT to the end of the disk and grows /var (last
#     partition) to fill the disk
#
# Usage: sudo ./flash.sh [options] IMAGE DEVICE
#        sudo ./flash.sh --list

set -Eeuo pipefail

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: sudo $0 [options] IMAGE DEVICE

IMAGE    .img, .img.zst, .img.xz or .img.gz built by build.sh
DEVICE   whole disk, e.g. /dev/sdb or /dev/nvme1n1 (NOT a partition)

Options:
  -y, --yes         do not ask for confirmation
      --no-grow     keep /var at its image size (do not fill the disk)
      --no-checksum skip the .sha256 check of the image file
      --verify      read the data back after writing and compare checksums
  -l, --list        list disks that can be flashed
  -h, --help        show this help
EOF
}

list_disks() {
    lsblk -d -e 7,11 -o NAME,SIZE,MODEL,SERIAL,TRAN,RM,TYPE
}

ASSUME_YES=0 GROW=1 CHECKSUM=1 VERIFY=0
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)      ASSUME_YES=1 ;;
        --no-grow)     GROW=0 ;;
        --no-checksum) CHECKSUM=0 ;;
        --verify)      VERIFY=1 ;;
        -l|--list)     list_disks; exit 0 ;;
        -h|--help)     usage; exit 0 ;;
        -*)            usage; die "unknown option: $1" ;;
        *)             ARGS+=("$1") ;;
    esac
    shift
done
[[ ${#ARGS[@]} -eq 2 ]] || { usage; exit 1; }
IMAGE="${ARGS[0]}"
DEV="${ARGS[1]}"

[[ $EUID -eq 0 ]] || die "run as root (sudo $0 ...)"
for tool in lsblk sgdisk partprobe e2fsck resize2fs dd blockdev; do
    command -v "$tool" >/dev/null || die "missing tool: $tool (apt install gdisk parted e2fsprogs util-linux)"
done

# --- image ------------------------------------------------------------------

[[ -f "$IMAGE" ]] || die "image not found: $IMAGE"
case "$IMAGE" in
    *.img.zst) DECOMP=(zstd -dc --) ;;
    *.img.xz)  DECOMP=(xz -dc --) ;;
    *.img.gz)  DECOMP=(gzip -dc --) ;;
    *.img)     DECOMP=(cat --) ;;
    *) die "unknown image type: $IMAGE" ;;
esac
command -v "${DECOMP[0]}" >/dev/null || die "missing tool: ${DECOMP[0]}"

IMG_DIR="$(dirname "$IMAGE")"
IMG_FILE="$(basename "$IMAGE")"
RAW_NAME="${IMG_FILE%.zst}"; RAW_NAME="${RAW_NAME%.xz}"; RAW_NAME="${RAW_NAME%.gz}"
SHA_FILE="$IMG_DIR/${RAW_NAME%.img}.sha256"

if [[ $CHECKSUM -eq 1 ]]; then
    if [[ -f "$SHA_FILE" ]]; then
        log "Verifying image checksum"
        (cd "$IMG_DIR" && grep "  $IMG_FILE\$" "$(basename "$SHA_FILE")" | sha256sum -c -) \
            || die "checksum mismatch, the image is corrupt"
    else
        warn "no checksum file ($SHA_FILE), skipping verification"
    fi
fi

# Uncompressed image size, to make sure it fits.
case "$IMAGE" in
    *.img)     IMG_SIZE="$(stat -c %s "$IMAGE")" ;;
    *.img.zst) IMG_SIZE="$(zstd -lv -- "$IMAGE" 2>/dev/null | sed -n 's/.*Decompressed Size:.*(\([0-9]*\) B).*/\1/p')" ;;
    *.img.xz)  IMG_SIZE="$(xz --robot -l -- "$IMAGE" | awk '/^totals/ {print $5}')" ;;
    *)         IMG_SIZE="" ;;
esac

# --- target device ----------------------------------------------------------

[[ -b "$DEV" ]] || die "not a block device: $DEV"
DEV="$(readlink -f "$DEV")"
[[ "$(lsblk -dno TYPE "$DEV")" == disk ]] || die "$DEV is not a whole disk (pass /dev/sdX, not /dev/sdX1)"

# Refuse the disk that holds the running system.
for mp in / /boot /usr /var; do
    src="$(findmnt -no SOURCE "$mp" 2>/dev/null || true)"
    [[ -b "$src" ]] || continue
    for parent in $(lsblk -srno NAME,TYPE "$src" | awk '$2 == "disk" {print $1}'); do
        [[ "/dev/$parent" == "$DEV" ]] && die "$DEV holds the running system ($mp)"
    done
done
# Refuse mounted / swap / in-use partitions.
if lsblk -nro MOUNTPOINT "$DEV" | grep -q .; then
    lsblk -o NAME,SIZE,MOUNTPOINT "$DEV"
    die "$DEV has mounted partitions, unmount them first"
fi
grep -q "^$DEV" /proc/swaps && die "$DEV is used as swap"

DEV_SIZE="$(blockdev --getsize64 "$DEV")"
if [[ -n "$IMG_SIZE" ]] && (( IMG_SIZE > DEV_SIZE )); then
    die "image ($((IMG_SIZE / 1048576)) MiB) is larger than $DEV ($((DEV_SIZE / 1048576)) MiB)"
fi

log "Target"
lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,FSTYPE,LABEL "$DEV"
echo
echo "Image:  $IMAGE${IMG_SIZE:+ ($((IMG_SIZE / 1048576)) MiB)}"
echo "Target: $DEV ($((DEV_SIZE / 1048576)) MiB) -- ALL DATA ON IT WILL BE DESTROYED"
if [[ $ASSUME_YES -eq 0 ]]; then
    read -r -p "Type the device name ($(basename "$DEV")) to continue: " answer
    [[ "$answer" == "$(basename "$DEV")" ]] || die "aborted"
fi

# --- write ------------------------------------------------------------------

log "Wiping old signatures"
wipefs -a -q "$DEV" || true
# Old GPT backup header at the end of the disk.
dd if=/dev/zero of="$DEV" bs=1M count=1 seek=$(( DEV_SIZE / 1048576 - 1 )) conv=fsync status=none

log "Writing image"
"${DECOMP[@]}" "$IMAGE" | dd of="$DEV" bs=4M iflag=fullblock oflag=direct conv=fsync status=progress
sync

if [[ $VERIFY -eq 1 ]]; then
    log "Verifying written data"
    [[ -n "$IMG_SIZE" ]] || IMG_SIZE="$("${DECOMP[@]}" "$IMAGE" | wc -c)"
    want="$("${DECOMP[@]}" "$IMAGE" | sha256sum | cut -d' ' -f1)"
    blockdev --flushbufs "$DEV"
    got="$(head -c "$IMG_SIZE" "$DEV" | sha256sum | cut -d' ' -f1)"
    [[ "$want" == "$got" ]] || die "verification failed: written data differs from the image"
    echo "OK ($want)"
fi

# --- grow /var -----------------------------------------------------------------

part_dev() {  # part_dev N -> /dev/sdb5 or /dev/nvme0n1p5
    if [[ "$DEV" =~ [0-9]$ ]]; then echo "${DEV}p$1"; else echo "${DEV}$1"; fi
}

reread() {
    partprobe "$DEV" 2>/dev/null || blockdev --rereadpt "$DEV" 2>/dev/null || true
    command -v udevadm >/dev/null && udevadm settle || sleep 2
}

log "Fixing GPT (backup header to end of disk)"
sgdisk -e "$DEV" >/dev/null
reread

if [[ $GROW -eq 1 ]]; then
    log "Growing /var (partition 5) to fill the disk"
    info="$(sgdisk -i 5 "$DEV")"
    start="$(awk '/^First sector:/ {print $3}' <<<"$info")"
    guid="$(awk '/^Partition unique GUID:/ {print $4}' <<<"$info")"
    type="$(awk '/^Partition GUID code:/ {print $4}' <<<"$info")"
    [[ -n "$start" && -n "$guid" && -n "$type" ]] || die "cannot read partition 5 on $DEV"
    sgdisk -d 5 -n "5:$start:0" -t "5:$type" -u "5:$guid" -c 5:var "$DEV" >/dev/null
    reread
    var_part="$(part_dev 5)"
    [[ -b "$var_part" ]] || die "partition $var_part did not appear"
    e2fsck -f -p "$var_part" || [[ $? -le 1 ]]
    resize2fs "$var_part"
fi

sync
log "Done"
sgdisk -p "$DEV" | sed -n '/^Number/,$p'
lsblk -o NAME,SIZE,FSTYPE,LABEL "$DEV"
echo
echo "You can now remove $DEV and boot the router from it."
