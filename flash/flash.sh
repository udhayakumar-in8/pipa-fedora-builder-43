#!/usr/bin/env bash
# Flash this Fedora image to a Xiaomi Pad 6 (pipa) in fastboot mode.
# Boot the tablet into fastboot (hold Volume Down + Power), connect USB, run:
#   ./flash.sh
set -e
cd "$(dirname "$0")"

die() { echo "ERROR: $*" >&2; exit 1; }

command -v fastboot >/dev/null || die "fastboot not found. Install android-tools (Linux) or platform-tools (macOS)."
[[ -f boot.img ]] || die "boot.img not found next to this script"
[[ -f root.img ]] || die "root.img not found next to this script"

echo "Waiting for a device in fastboot mode..."
product=$(fastboot getvar product 2>&1 | awk -F': *' '/^product:/{print $2; exit}')
[[ "$product" == "pipa" ]] || die "connected device is '${product:-none}', expected 'pipa' (Xiaomi Pad 6)"

echo
echo "WARNING: this ERASES the userdata partition (all Android data) and"
echo "replaces the boot image on both slots with Fedora."
read -r -p "Type YES to continue: " answer
[[ "$answer" == "YES" ]] || die "aborted"

fastboot flash boot_ab boot.img
fastboot flash userdata root.img
fastboot erase dtbo
fastboot reboot

echo
echo "Done. First boot takes a minute or two (the root filesystem is resized)."
echo "Login: udhayakumar / 147147 - you will be asked to set a new password."
