#!/bin/bash
#
# Ubuntu 22.04 router image builder (x86_64, headless).
#
# Produces a raw GPT disk image that boots on both UEFI and legacy BIOS:
#   p1 bios_boot (1M) | p2 ESP -> /boot/efi | p3 /boot | p4 / | p5 /var
#
# Usage: sudo ./build.sh [options]   (see --help)

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: sudo $0 [options]

Options:
  -c, --config FILE     extra config file (loaded after config/build.conf and config/local.conf)
  -p, --profiles LIST   package profiles, e.g. "base router" (packages/<name>.list)
  -a, --add PKGS        extra packages, e.g. "htop pppoe"
  -v, --version VER     image version (default: date based)
  -o, --output DIR      output directory (default: out)
      --no-cache        re-run debootstrap instead of using the cached base tarball
      --keep-work       keep the work directory (rootfs) after the build
  -h, --help            show this help

Files:
  config/build.conf     defaults           packages/*.list    package profiles
  config/local.conf     your overrides     packages/debs/     local .deb files
  overlay/              files copied into the rootfs
  hooks/*.sh            scripts run inside the rootfs (in name order)
EOF
}

# Mounts and loop devices, released in reverse order by cleanup().
MOUNTS=()
LOOPS=()
CREATED_LINKS=()

cleanup() {
    local rc=$?
    set +e
    local i
    for ((i = ${#MOUNTS[@]} - 1; i >= 0; i--)); do
        umount "${MOUNTS[i]}" 2>/dev/null || umount -l "${MOUNTS[i]}" 2>/dev/null
    done
    for l in "${CREATED_LINKS[@]}"; do rm -f "$l"; done
    for l in "${LOOPS[@]}"; do losetup -d "$l" 2>/dev/null; done
    if [[ $rc -eq 0 && "${KEEP_WORK:-0}" != 1 && -n "${WORK_DIR:-}" ]]; then
        rm -rf "$WORK_DIR"
    fi
    [[ $rc -ne 0 ]] && printf '\033[1;31mBuild failed (exit %s). Work dir kept: %s\033[0m\n' "$rc" "${WORK_DIR:-}" >&2
    exit $rc
}
trap cleanup EXIT

do_mount() {   # do_mount [mount args...] TARGET
    mount "$@"
    MOUNTS+=("${*: -1}")
}

do_umount() {  # unmount everything at or below $1
    local i
    for ((i = ${#MOUNTS[@]} - 1; i >= 0; i--)); do
        if [[ "${MOUNTS[i]}" == "$1" || "${MOUNTS[i]}" == "$1"/* ]]; then
            umount "${MOUNTS[i]}"
            unset 'MOUNTS[i]'
        fi
    done
    MOUNTS=("${MOUNTS[@]}")
}

chroot_mount() {
    local root="$1"
    do_mount --bind /dev "$root/dev"
    do_mount -t devpts devpts "$root/dev/pts" -o gid=5,mode=620,ptmxmode=666
    do_mount -t proc proc "$root/proc"
    do_mount -t sysfs sysfs "$root/sys"
    do_mount -t tmpfs tmpfs "$root/run"
    do_mount -t tmpfs tmpfs "$root/tmp"
}

in_chroot() {  # in_chroot ROOT CMD...
    local root="$1"; shift
    LANG=C.UTF-8 LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
        ROUTER_BUILD=1 PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        chroot "$root" "$@"
}

apt_chroot() {
    in_chroot "$ROOTFS" apt-get -y -q \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

read_list() {  # print the package names of a .list file
    sed -e 's/#.*//' -e 's/[[:space:]]\+/\n/g' "$1" | sed '/^$/d'
}

# Random string from CHARSET (no pipefail: head closing the pipe is expected).
random_str() {  # random_str LENGTH CHARSET
    (set +o pipefail; LC_ALL=C tr -dc "$2" </dev/urandom | head -c "$1")
}

# Replace @VAR@ placeholders in a file with the values of the shell variables.
render() {
    local file="$1" content var
    content="$(<"$file")"
    for var in HOSTNAME DOMAIN WAN_IF LAN_IF LAN_ADDR KERNEL_CMDLINE GRUB_TIMEOUT \
               SSH_PASSWORD_AUTH SSH_WAN_RULE IMAGE_NAME VERSION SUITE BUILD_DATE GIT_COMMIT; do
        content="${content//@${var}@/"${!var:-}"}"
    done
    printf '%s\n' "$content" > "$file"
}

# ---------------------------------------------------------------------------
# configuration
# ---------------------------------------------------------------------------

parse_args() {
    CLI_CONFIG="" CLI_PROFILES="" CLI_ADD="" CLI_VERSION="" CLI_OUTPUT="" NO_CACHE=0 KEEP_WORK=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--config)   CLI_CONFIG="$2"; shift ;;
            -p|--profiles) CLI_PROFILES="$2"; shift ;;
            -a|--add)      CLI_ADD="$2"; shift ;;
            -v|--version)  CLI_VERSION="$2"; shift ;;
            -o|--output)   CLI_OUTPUT="$2"; shift ;;
            --no-cache)    NO_CACHE=1 ;;
            --keep-work)   KEEP_WORK=1 ;;
            -h|--help)     usage; exit 0 ;;
            *) usage; die "unknown option: $1" ;;
        esac
        shift
    done
}

load_config() {
    # shellcheck source=config/build.conf
    source config/build.conf
    [[ -f config/local.conf ]] && source config/local.conf
    if [[ -n "$CLI_CONFIG" ]]; then
        [[ -f "$CLI_CONFIG" ]] || die "config file not found: $CLI_CONFIG"
        # shellcheck disable=SC1090
        source "$CLI_CONFIG"
    fi
    [[ -n "$CLI_PROFILES" ]] && PROFILES="$CLI_PROFILES"
    [[ -n "$CLI_ADD" ]]      && EXTRA_PACKAGES="$EXTRA_PACKAGES $CLI_ADD"
    [[ -n "$CLI_VERSION" ]]  && VERSION="$CLI_VERSION"
    [[ -n "$CLI_OUTPUT" ]]   && OUTPUT_DIR="$CLI_OUTPUT"

    [[ "$ARCH" == amd64 ]] || die "only ARCH=amd64 is supported"
    [[ "$COMPRESS" =~ ^(zstd|xz|none)$ ]] || die "COMPRESS must be zstd, xz or none"
    [[ -n "$ADMIN_SSH_KEY" && ! -f "$ADMIN_SSH_KEY" ]] && die "ADMIN_SSH_KEY not found: $ADMIN_SSH_KEY"

    BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [[ -z "$VERSION" ]] && VERSION="$(date -u +%Y.%m.%d-%H%M)"
    GIT_COMMIT="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    IMAGE_BASENAME="${IMAGE_NAME}-${SUITE}-${ARCH}-${VERSION}"

    OUTPUT_DIR="$(mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" && pwd)"
    CACHE_DIR="$SCRIPT_DIR/cache"
    WORK_DIR="$SCRIPT_DIR/work/$IMAGE_BASENAME"
    ROOTFS="$WORK_DIR/rootfs"
    MNT="$WORK_DIR/mnt"
    IMAGE="$OUTPUT_DIR/$IMAGE_BASENAME.img"

    # shellcheck disable=SC2034  # used by render() via ${!var}
    if [[ -n "$ADMIN_SSH_KEY" ]]; then SSH_PASSWORD_AUTH="no"; else SSH_PASSWORD_AUTH="yes"; fi
    # shellcheck disable=SC2034
    if [[ "$SSH_ON_WAN" == yes ]]; then
        SSH_WAN_RULE='iifname $WAN tcp dport 22 ct state new limit rate 6/minute burst 10 packets accept comment "SSH from WAN"'
    else
        SSH_WAN_RULE='# SSH from WAN disabled (SSH_ON_WAN=no)'
    fi
}

preflight() {
    [[ $EUID -eq 0 ]] || die "run as root (sudo $0)"
    local tool missing=()
    for tool in debootstrap sgdisk partx losetup rsync mount chroot; do
        command -v "$tool" >/dev/null || missing+=("$tool")
    done
    [[ "$COMPRESS" == zstd ]] && ! command -v zstd >/dev/null && missing+=(zstd)
    [[ "$COMPRESS" == xz ]]   && ! command -v xz   >/dev/null && missing+=(xz)
    [[ ${#missing[@]} -eq 0 ]] || die "missing tools: ${missing[*]} (apt install debootstrap gdisk util-linux rsync zstd xz-utils)"
    [[ -e "$IMAGE" ]] && die "image already exists: $IMAGE (use another --version)"

    log "Building $IMAGE_BASENAME"
    info "profiles:   $PROFILES"
    info "extra:      ${EXTRA_PACKAGES:-none}"
    info "kernel:     $KERNEL_PACKAGE"
    info "layout:     ESP ${ESP_SIZE}M  /boot ${BOOT_SIZE}M  / ${ROOT_SIZE}M  /var ${VAR_SIZE}M"
    info "output:     $OUTPUT_DIR"

    rm -rf "$WORK_DIR"
    mkdir -p "$ROOTFS" "$MNT" "$CACHE_DIR"
}

# ---------------------------------------------------------------------------
# rootfs
# ---------------------------------------------------------------------------

stage_bootstrap() {
    local tarball="$CACHE_DIR/debootstrap-${SUITE}-${ARCH}.tar.zst"
    if [[ -f "$tarball" && $NO_CACHE -eq 0 ]]; then
        log "Extracting cached base system ($(basename "$tarball"))"
        tar --zstd -xpf "$tarball" -C "$ROOTFS" --numeric-owner
    else
        log "Bootstrapping Ubuntu $SUITE ($ARCH, minbase)"
        debootstrap --arch="$ARCH" --variant=minbase \
            --components="${COMPONENTS// /,}" \
            "$SUITE" "$ROOTFS" "$MIRROR"
        tar --zstd -cpf "$tarball.tmp" -C "$ROOTFS" --numeric-owner . && mv "$tarball.tmp" "$tarball"
    fi
    chroot_mount "$ROOTFS"
}

stage_apt() {
    log "Configuring apt"
    cat > "$ROOTFS/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE $COMPONENTS
deb $MIRROR $SUITE-updates $COMPONENTS
deb $SECURITY_MIRROR $SUITE-security $COMPONENTS
EOF
    # Lean installs, also later on the device.
    cat > "$ROOTFS/etc/apt/apt.conf.d/90-router" <<'EOF'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::Languages "none";
EOF
    # Keep docs/man pages/translations out of the image (copyright files stay).
    cat > "$ROOTFS/etc/dpkg/dpkg.cfg.d/01-router-nodoc" <<'EOF'
path-exclude=/usr/share/doc/*
path-include=/usr/share/doc/*/copyright
path-exclude=/usr/share/man/*
path-exclude=/usr/share/info/*
path-exclude=/usr/share/locale/*
path-include=/usr/share/locale/locale.alias
path-exclude=/usr/share/lintian/*
EOF
    # Packages that must never be installed.
    {
        echo "# Generated by ubuntu-router build.sh from packages/blocklist.list"
        local pkg
        while read -r pkg; do
            printf 'Package: %s\nPin: release *\nPin-Priority: -1\n\n' "$pkg"
        done < <(read_list packages/blocklist.list)
    } > "$ROOTFS/etc/apt/preferences.d/router-blocklist"

    # Never start services inside the build chroot.
    printf '#!/bin/sh\nexit 101\n' > "$ROOTFS/usr/sbin/policy-rc.d"
    chmod 755 "$ROOTFS/usr/sbin/policy-rc.d"
    cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf.build"
    rm -f "$ROOTFS/etc/resolv.conf"
    cp "$ROOTFS/etc/resolv.conf.build" "$ROOTFS/etc/resolv.conf"

    # Preseed debconf questions.
    in_chroot "$ROOTFS" debconf-set-selections <<EOF
iperf3 iperf3/start_daemon boolean false
tzdata tzdata/Areas select Etc
tzdata tzdata/Zones/Etc select UTC
EOF

    apt_chroot update
    apt_chroot dist-upgrade
}

stage_packages() {
    local profile list pkgs=()
    for profile in $PROFILES custom; do
        list="packages/$profile.list"
        [[ -f "$list" ]] || die "profile not found: $list"
        mapfile -t -O "${#pkgs[@]}" pkgs < <(read_list "$list")
    done
    # shellcheck disable=SC2206
    pkgs+=($KERNEL_PACKAGE $EXTRA_PACKAGES)
    mapfile -t pkgs < <(printf '%s\n' "${pkgs[@]}" | awk 'NF && !seen[$0]++')

    log "Installing ${#pkgs[@]} packages"
    info "${pkgs[*]}"
    apt_chroot install "${pkgs[@]}"

    local debs=(packages/debs/*.deb)
    if [[ -e "${debs[0]}" ]]; then
        log "Installing ${#debs[@]} local .deb file(s)"
        mkdir -p "$ROOTFS/tmp/debs"
        cp "${debs[@]}" "$ROOTFS/tmp/debs/"
        apt_chroot install /tmp/debs/*.deb
    fi

    # Fail loudly if a blocked package slipped in.
    local blocked
    # shellcheck disable=SC2046
    blocked="$(in_chroot "$ROOTFS" dpkg-query -W -f='${Package} ${Status}\n' $(read_list packages/blocklist.list) 2>/dev/null \
               | awk '/install ok installed/ {print $1}')" || true
    [[ -z "$blocked" ]] || die "blocked packages got installed: $blocked"
}

stage_overlay() {
    log "Applying overlay"
    rsync -rlptD --chown=root:root overlay/ "$ROOTFS/"
    # Executable bits can get lost (zip downloads, web uploads): set them explicitly.
    local f
    while IFS= read -r -d '' f; do
        f="$ROOTFS/${f#overlay/}"
        if grep -q '@[A-Z_]\+@' "$f"; then render "$f"; fi
    done < <(find overlay -type f -print0)
    chmod 600 "$ROOTFS"/etc/netplan/*.yaml
    chmod 755 "$ROOTFS"/usr/local/sbin/* "$ROOTFS"/etc/kernel/postinst.d/* "$ROOTFS"/etc/kernel/postrm.d/* \
        "$ROOTFS"/etc/update-motd.d/05-router
}

stage_system() {
    log "Configuring system"
    echo "$HOSTNAME" > "$ROOTFS/etc/hostname"
    cat > "$ROOTFS/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME.$DOMAIN $HOSTNAME
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

    # locale, timezone, keyboard
    sed -i "s/^# *\($LOCALE\)/\1/" "$ROOTFS/etc/locale.gen"
    in_chroot "$ROOTFS" locale-gen
    echo "LANG=$LOCALE" > "$ROOTFS/etc/default/locale"
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$ROOTFS/etc/localtime"
    echo "$TIMEZONE" > "$ROOTFS/etc/timezone"
    printf 'XKBLAYOUT="%s"\n' "$KEYMAP" > "$ROOTFS/etc/default/keyboard"

    # /etc/router-release
    cat > "$ROOTFS/etc/router-release" <<EOF
NAME="$IMAGE_NAME"
VERSION="$VERSION"
SUITE="$SUITE"
ARCH="$ARCH"
PROFILES="$PROFILES"
BUILD_DATE="$BUILD_DATE"
GIT_COMMIT="$GIT_COMMIT"
EOF

    # DNS: bind is the local resolver, systemd-resolved is masked.
    rm -f "$ROOTFS/etc/resolv.conf.build"
    cat > "$ROOTFS/etc/resolv.conf.router" <<EOF
# Local BIND resolver (see /etc/bind/named.conf.options)
nameserver 127.0.0.1
nameserver ::1
search $DOMAIN
options edns0 trust-ad
EOF

    # Users: root locked, admin with sudo + ssh access.
    in_chroot "$ROOTFS" groupadd -f -r sshusers
    in_chroot "$ROOTFS" useradd -m -s /bin/bash -G sudo,adm,sshusers "$ADMIN_USER"
    local password="$ADMIN_PASSWORD"
    if [[ -z "$password" ]]; then
        password="$(random_str 16 'A-HJ-NP-Za-km-z2-9')"
        umask 077
        printf 'user: %s\npassword: %s\n(the password must be changed at first login)\n' \
            "$ADMIN_USER" "$password" > "$OUTPUT_DIR/$IMAGE_BASENAME.credentials"
        umask 022
        info "admin password written to $OUTPUT_DIR/$IMAGE_BASENAME.credentials"
    fi
    printf '%s:%s\n' "$ADMIN_USER" "$password" | in_chroot "$ROOTFS" chpasswd
    in_chroot "$ROOTFS" chage -d 0 "$ADMIN_USER"
    in_chroot "$ROOTFS" passwd -l root
    if [[ -n "$ADMIN_SSH_KEY" ]]; then
        install -d -m 700 "$ROOTFS/home/$ADMIN_USER/.ssh"
        install -m 600 "$ADMIN_SSH_KEY" "$ROOTFS/home/$ADMIN_USER/.ssh/authorized_keys"
        in_chroot "$ROOTFS" chown -R "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
    fi

    # SSH: drop weak Diffie-Hellman moduli.
    if [[ -f "$ROOTFS/etc/ssh/moduli" ]]; then
        awk '$5 >= 3071' "$ROOTFS/etc/ssh/moduli" > "$ROOTFS/etc/ssh/moduli.safe"
        mv "$ROOTFS/etc/ssh/moduli.safe" "$ROOTFS/etc/ssh/moduli"
    fi

    # Services
    local unit
    for unit in $ENABLE_SERVICES;  do in_chroot "$ROOTFS" systemctl enable "$unit"  || die "cannot enable $unit"; done
    for unit in $DISABLE_SERVICES; do in_chroot "$ROOTFS" systemctl disable "$unit" 2>/dev/null || warn "cannot disable $unit (not installed?)"; done
    for unit in $MASK_SERVICES;    do in_chroot "$ROOTFS" systemctl mask "$unit"; done
    in_chroot "$ROOTFS" systemctl set-default multi-user.target
}

stage_hooks() {
    local hook
    for hook in hooks/*.sh; do
        [[ -e "$hook" ]] || continue
        log "Running hook $(basename "$hook")"
        install -m 755 "$hook" "$ROOTFS/tmp/hook.sh"
        in_chroot "$ROOTFS" env HOSTNAME="$HOSTNAME" WAN_IF="$WAN_IF" LAN_IF="$LAN_IF" \
            ADMIN_USER="$ADMIN_USER" PROFILES="$PROFILES" /tmp/hook.sh
        rm -f "$ROOTFS/tmp/hook.sh"
    done
}

stage_cleanup_rootfs() {
    log "Cleaning rootfs"
    apt_chroot autoremove --purge
    apt_chroot clean
    in_chroot "$ROOTFS" dpkg-query -W -f='${Package}\t${Version}\n' > "$OUTPUT_DIR/$IMAGE_BASENAME.manifest"

    rm -f "$ROOTFS/usr/sbin/policy-rc.d"
    rm -rf "$ROOTFS"/var/lib/apt/lists/* "$ROOTFS"/var/cache/apt/*.bin "$ROOTFS"/var/cache/debconf/*-old
    rm -f "$ROOTFS"/etc/ssh/ssh_host_*            # regenerated by router-firstboot
    : > "$ROOTFS/etc/machine-id"                   # generated at first boot
    rm -f "$ROOTFS/var/lib/dbus/machine-id"
    ln -s /etc/machine-id "$ROOTFS/var/lib/dbus/machine-id"
    rm -f "$ROOTFS/var/lib/systemd/random-seed"
    rm -rf "$ROOTFS"/tmp/* "$ROOTFS"/var/tmp/* "$ROOTFS"/root/.bash_history
    find "$ROOTFS/var/log" -type f -exec truncate -s 0 {} +
    mv "$ROOTFS/etc/resolv.conf.router" "$ROOTFS/etc/resolv.conf"

    do_umount "$ROOTFS"
}

# ---------------------------------------------------------------------------
# disk image
# ---------------------------------------------------------------------------

# Attach one loop device for partition N of the image (works without udev or
# kernel partition scanning, e.g. inside containers).
loop_part() {
    local n="$1" start sectors dev
    read -r start sectors < <(partx -g -o START,SECTORS -n "$n" "$IMAGE")
    dev="$(losetup -f --show -o $((start * 512)) --sizelimit $((sectors * 512)) "$IMAGE")"
    LOOPS+=("$dev")
    echo "$dev"
}

stage_image() {
    log "Creating disk image"
    local total=$((1 + 1 + ESP_SIZE + BOOT_SIZE + ROOT_SIZE + VAR_SIZE + 1))
    truncate -s "${total}M" "$IMAGE"
    sgdisk --zap-all \
        -n 1:1M:+1M          -t 1:EF02 -c 1:bios_boot \
        -n 2:0:+"$ESP_SIZE"M  -t 2:EF00 -c 2:EFI \
        -n 3:0:+"$BOOT_SIZE"M -t 3:8300 -c 3:boot \
        -n 4:0:+"$ROOT_SIZE"M -t 4:8304 -c 4:root \
        -n 5:0:0             -t 5:8310 -c 5:var \
        "$IMAGE" >/dev/null
    sgdisk -p "$IMAGE" | sed -n '/^Number/,$p' | sed 's/^/    /'

    DISK_LOOP="$(losetup -f --show "$IMAGE")"; LOOPS+=("$DISK_LOOP")
    ESP_DEV="$(loop_part 2)"
    BOOT_DEV="$(loop_part 3)"
    ROOT_DEV="$(loop_part 4)"
    VAR_DEV="$(loop_part 5)"

    ESP_UUID="$(random_str 8 'A-F0-9')"
    ESP_UUID="${ESP_UUID:0:4}-${ESP_UUID:4:4}"
    BOOT_UUID="$(cat /proc/sys/kernel/random/uuid)"
    ROOT_UUID="$(cat /proc/sys/kernel/random/uuid)"
    VAR_UUID="$(cat /proc/sys/kernel/random/uuid)"

    # Use the target's own mkfs (jammy e2fsprogs/grub 2.06 do not understand
    # ext4 features enabled by newer host versions, e.g. orphan_file).
    do_mount --bind /dev "$ROOTFS/dev"
    in_chroot "$ROOTFS" mkfs.vfat -F 32 -n EFI -i "${ESP_UUID//-/}" "$ESP_DEV" >/dev/null
    in_chroot "$ROOTFS" mkfs.ext4 -q -F -L boot -U "$BOOT_UUID" "$BOOT_DEV"
    in_chroot "$ROOTFS" mkfs.ext4 -q -F -L root -U "$ROOT_UUID" "$ROOT_DEV"
    in_chroot "$ROOTFS" mkfs.ext4 -q -F -L var  -U "$VAR_UUID"  "$VAR_DEV"
    do_umount "$ROOTFS/dev"

    cat > "$ROOTFS/etc/fstab" <<EOF
# <file system>    <mount point>  <type>  <options>                                <dump> <pass>
UUID=$ROOT_UUID    /              ext4    defaults,noatime,errors=remount-ro        0 1
UUID=$BOOT_UUID    /boot          ext4    defaults,noatime,nodev,nosuid,noexec      0 2
UUID=$ESP_UUID     /boot/efi      vfat    umask=0077,nodev,nosuid,noexec            0 2
UUID=$VAR_UUID     /var           ext4    defaults,noatime,nodev,nosuid             0 2
tmpfs              /tmp           tmpfs   defaults,nodev,nosuid,mode=1777,size=25%  0 0
EOF

    log "Copying rootfs into partitions"
    do_mount "$ROOT_DEV" "$MNT"
    mkdir -p "$MNT/boot" "$MNT/var"
    do_mount "$BOOT_DEV" "$MNT/boot"
    mkdir -p "$MNT/boot/efi"
    do_mount "$ESP_DEV" "$MNT/boot/efi"
    do_mount "$VAR_DEV" "$MNT/var"
    rsync -aHAX --info=stats1 "$ROOTFS/" "$MNT/"
    rm -rf "$MNT/var/lost+found" "$MNT/boot/lost+found"
    df -h "$MNT" "$MNT/boot" "$MNT/boot/efi" "$MNT/var" | sed 's/^/    /'
}

stage_bootloader() {
    log "Installing GRUB (UEFI + legacy BIOS)"
    chroot_mount "$MNT"

    # grub-mkconfig only writes root=UUID=... when /dev/disk/by-uuid/<uuid>
    # exists; without udev (containers) create the links ourselves.
    local uuid dev
    mkdir -p /dev/disk/by-uuid
    for pair in "$ROOT_UUID:$ROOT_DEV" "$BOOT_UUID:$BOOT_DEV" "$VAR_UUID:$VAR_DEV" "$ESP_UUID:$ESP_DEV"; do
        uuid="${pair%%:*}" dev="${pair#*:}"
        if [[ ! -e "/dev/disk/by-uuid/$uuid" ]]; then
            ln -s "$dev" "/dev/disk/by-uuid/$uuid"
            CREATED_LINKS+=("/dev/disk/by-uuid/$uuid")
        fi
    done

    in_chroot "$MNT" /usr/local/sbin/router-install-bootloader "$DISK_LOOP" "$BOOT_UUID"
    in_chroot "$MNT" update-initramfs -u -k all
    in_chroot "$MNT" update-grub
    grep -q "root=UUID=$ROOT_UUID" "$MNT/boot/grub/grub.cfg" || die "grub.cfg does not boot root=UUID=$ROOT_UUID"

    do_umount "$MNT"
    for dev in "${LOOPS[@]}"; do losetup -d "$dev"; done
    LOOPS=()
}

stage_finalize() {
    log "Finalizing"
    local raw_sha out="$IMAGE"
    raw_sha="$(sha256sum "$IMAGE" | cut -d' ' -f1)"
    case "$COMPRESS" in
        zstd) zstd -T0 -10 --rm -q "$IMAGE"; out="$IMAGE.zst" ;;
        xz)   xz -T0 -6 "$IMAGE";            out="$IMAGE.xz" ;;
    esac
    (
        cd "$OUTPUT_DIR"
        sha256sum "$(basename "$out")"
        if [[ "$out" != "$IMAGE" ]]; then printf '%s  %s\n' "$raw_sha" "$(basename "$IMAGE")"; fi
    ) > "$OUTPUT_DIR/$IMAGE_BASENAME.sha256"

    log "Done"
    info "image:     $out ($(du -h "$out" | cut -f1))"
    info "checksums: $OUTPUT_DIR/$IMAGE_BASENAME.sha256"
    info "packages:  $OUTPUT_DIR/$IMAGE_BASENAME.manifest"
    [[ -f "$OUTPUT_DIR/$IMAGE_BASENAME.credentials" ]] && info "login:     $OUTPUT_DIR/$IMAGE_BASENAME.credentials"
    info "flash:     sudo ./flash.sh $out /dev/sdX"
}

main() {
    parse_args "$@"
    load_config
    preflight
    stage_bootstrap
    stage_apt
    stage_packages
    stage_overlay
    stage_system
    stage_hooks
    stage_cleanup_rootfs
    stage_image
    stage_bootloader
    stage_finalize
}

main "$@"; exit  # on one line: editing this file during a build is safe
