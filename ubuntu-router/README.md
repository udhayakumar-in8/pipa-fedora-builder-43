# Ubuntu Router (Ubuntu 22.04, x86_64, headless)

Builds a minimal, hardened Ubuntu 22.04 LTS **router appliance** image from
scratch with `debootstrap`, with no GUI and none of the stock Ubuntu bloat,
and flashes it to a disk.

- Boots on **UEFI and legacy BIOS** (GRUB, removable EFI path, no NVRAM needed)
- **Separate partitions** for `/boot`, `/` and `/var`; `/var` grows to fill the disk when flashing
- **Router stack**: nftables NAT/firewall, conntrack, tproxy, WireGuard, OpenVPN,
  IPsec (strongSwan/swanctl), BIRD 2, BIND 9, bonding/bridge/VLAN, CAKE QoS,
  vnstat, tcpdump, iperf/iperf3
- **Hardened**: SSH (keys, modern ciphers, `sshusers` group, fail2ban), default-drop firewall,
  root locked, sysctl hardening, per-device SSH host keys generated at first boot
- **Never installed** (apt pinned to -1): snapd, cloud-init, ubuntu-advantage/pro, apport,
  popularity-contest, landscape, motd-news, NetworkManager, ModemManager, avahi, cups, desktop
- **Extensible**: package profiles, `custom.list`, local `.deb`s, overlay files and hook scripts

## Disk layout

| # | Name      | Size (default) | Mount        | Notes |
|---|-----------|----------------|--------------|-------|
| 1 | bios_boot | 1 MiB          | -            | GRUB core for legacy BIOS |
| 2 | EFI       | 256 MiB        | `/boot/efi`  | FAT32, `\EFI\BOOT\BOOTX64.EFI` |
| 3 | boot      | 1 GiB          | `/boot`      | ext4, `nodev,nosuid,noexec` |
| 4 | root      | 4 GiB          | `/`          | ext4 |
| 5 | var       | 1 GiB → rest of disk | `/var` | ext4, `nodev,nosuid`; logs, DNS cache, vnstat DB, apt cache |

`/tmp` is a tmpfs. Change the sizes in `config/local.conf` (`ESP_SIZE`,
`BOOT_SIZE`, `ROOT_SIZE`, `VAR_SIZE`, all in MiB).

## Quick start

On an Ubuntu/Debian build host:

```bash
sudo apt install debootstrap gdisk util-linux e2fsprogs dosfstools rsync zstd
cd ubuntu-router

# optional: your settings + SSH key
cp ~/.ssh/id_ed25519.pub config/admin.pub
cat > config/local.conf <<'EOF'
ADMIN_SSH_KEY="config/admin.pub"
WAN_IF="eth0"
LAN_IF="eth1"
LAN_ADDR="192.168.1.1/24"
EOF

sudo ./build.sh                       # ~10-20 min the first time
ls out/
#  ubuntu-router-jammy-amd64-<version>.img.zst          the image
#  ubuntu-router-jammy-amd64-<version>.sha256           checksums
#  ubuntu-router-jammy-amd64-<version>.manifest         installed package versions
#  ubuntu-router-jammy-amd64-<version>.credentials      admin password (if not set)
```

Or in Docker (no tools needed on the host):

```bash
docker build -t ubuntu-router-builder ubuntu-router/
docker run --rm --privileged -v /dev:/dev -v "$PWD/ubuntu-router:/build" ubuntu-router-builder
```

### Test it in a VM

```bash
sudo apt install qemu-system-x86 ovmf
./run-qemu.sh out/ubuntu-router-*.img.zst          # UEFI
./run-qemu.sh --bios out/ubuntu-router-*.img.zst   # legacy BIOS
ssh -p 2222 admin@localhost                         # via the emulated LAN port
```

The serial console is on the terminal. Press `Ctrl-A X` to quit. The VM runs on a snapshot, so the image is not changed.

### Flash to the router disk

```bash
sudo ./flash.sh --list                                   # find the disk
sudo ./flash.sh out/ubuntu-router-*.img.zst /dev/sdX     # asks you to type the device name
sudo ./flash.sh --verify out/ubuntu-router-*.img.zst /dev/nvme1n1
```

`flash.sh` checks the image checksum and refuses mounted disks and the disk your
system runs from. It writes with `O_DIRECT` + `fsync`, moves the backup GPT to the
end of the disk and grows `/var` to use all the space (`--no-grow` to skip that).
`--verify` reads the data back and compares it with the image.

## First boot

- Log in on the console (VGA or serial `ttyS0` at 115200) or with SSH from the **LAN** port.
- User `admin`. The password is set at build time (`ADMIN_PASSWORD`, or random in
  `out/*.credentials`) and **must be changed at the first login**. Root login is disabled.
- If `ADMIN_SSH_KEY` was set, SSH accepts keys only.
- Interfaces are named `eth0`, `eth1`, ... (`net.ifnames=0`).
  By default `eth0` is the WAN (DHCP) and `eth1` is the LAN (`192.168.1.1/24`).
- See which NIC is which with `ip -br link` and `ethtool -P ethX` (MAC address).

## Configuration on the router

| What | Where | Apply |
|------|-------|-------|
| Interfaces, bonds, bridges, VLANs | `/etc/netplan/*.yaml` ([example](overlay/etc/router/examples/netplan-bond-bridge-vlan.yaml)) | `netplan try` |
| Firewall / NAT / port forwards | `/etc/nftables.conf`, `/etc/nftables.d/*.nft` | `nft -c -f /etc/nftables.conf && systemctl reload nftables` |
| TPROXY | [`/etc/router/examples/tproxy.nft`](overlay/etc/router/examples/tproxy.nft) | copy to `/etc/nftables.d/` |
| DNS resolver | `/etc/bind/named.conf.options` | `named-checkconf && systemctl reload named` |
| WireGuard | `/etc/wireguard/wg0.conf` ([example](overlay/etc/router/examples/wireguard-wg0.conf)) | `systemctl enable --now wg-quick@wg0` |
| OpenVPN | `/etc/openvpn/server/NAME.conf` | `systemctl enable --now openvpn-server@NAME` |
| IPsec | `/etc/swanctl/conf.d/*.conf` | `systemctl enable --now strongswan && swanctl --load-all` |
| BGP / OSPF | `/etc/bird/bird.conf` ([example](overlay/etc/router/examples/bird.conf)) | `systemctl enable --now bird` |
| QoS (CAKE) | `/etc/default/router-qos` | `systemctl enable --now router-qos` |
| Kernel / sysctl | `/etc/sysctl.d/90-router.conf` | `sysctl --system` |
| SSH | `/etc/ssh/sshd_config.d/50-hardening.conf` | `sshd -t && systemctl reload ssh` |

VPN, BIRD, QoS and the iperf3 server are installed but **disabled** until you
configure them. Automatic apt timers are off: update with
`apt update && apt upgrade` in a maintenance window. Kernel upgrades regenerate
`grub.cfg` automatically. To reinstall the bootloader, run `router-install-bootloader`.

## Customizing the build

All settings are in [`config/build.conf`](config/build.conf). Put your changes in
`config/local.conf` (git-ignored) or a separate file passed with `-c`.

| I want to... | Do this |
|--------------|---------|
| add packages to every build | add them to `packages/custom.list` |
| add packages to one build | `sudo ./build.sh -a "htop pppoe"` |
| a new package set (e.g. `dhcp`) | create `packages/dhcp.list`, then `PROFILES="base router dhcp"` or `-p "base router dhcp"` |
| install my own `.deb` files | put them in `packages/debs/` |
| add or replace config files | put them in `overlay/` (same path as on the router). `@WAN_IF@`, `@LAN_IF@`, `@HOSTNAME@`, ... are substituted |
| run commands in the image | add `hooks/NN-name.sh` (runs in the image chroot, in name order) |
| block a package forever | add it to `packages/blocklist.list` |
| enable / disable services | `ENABLE_SERVICES`, `DISABLE_SERVICES`, `MASK_SERVICES` |
| use the 5.15 GA kernel | `KERNEL_PACKAGE="linux-image-generic"` |
| set the version | `sudo ./build.sh -v 1.2.0` |

The debootstrap base system is cached in `cache/`, so rebuilds are faster
(`--no-cache` refreshes it). Each build records the exact package versions in
`*.manifest` and `/etc/router-release`, so you can always tell what is on a box.

### Build stages

`bootstrap → apt (sources, no-recommends, blocklist pins) → packages → overlay →
system (users, locale, services) → hooks → cleanup → disk image → GRUB → compress + checksums`

## Files

```
ubuntu-router/
├── build.sh               image builder
├── flash.sh               safe disk flasher (+ grow /var)
├── run-qemu.sh            boot an image in QEMU (UEFI or BIOS)
├── Dockerfile             reproducible build environment
├── config/build.conf      all settings (override in config/local.conf)
├── packages/
│   ├── base.list          minimal server base
│   ├── router.list        router stack
│   ├── custom.list        your packages
│   ├── blocklist.list     never installed (apt pin -1)
│   └── debs/              your local .deb files
├── hooks/                 scripts run inside the image
└── overlay/               files copied into the image (firewall, sysctl, ssh, bind, ...)
```
