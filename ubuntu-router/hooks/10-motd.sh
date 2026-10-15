#!/bin/sh
# Hooks run inside the image rootfs (chroot) in name order, after packages and
# the overlay are installed. Available variables: HOSTNAME WAN_IF LAN_IF
# ADMIN_USER PROFILES. Add your own NN-name.sh files here.
set -e

# Quiet login: drop Ubuntu's help/advertising MOTD parts, keep ours.
for f in 10-help-text 50-motd-news 50-landscape-sysinfo 88-esm-announce 91-contract-ua-esm-status; do
    rm -f "/etc/update-motd.d/$f"
done
