#!/usr/bin/env bash

set -Eeuo pipefail

log() {
    printf '[mido-image] %s\n' "$*"
}

fail() {
    printf '[mido-image] Error: %s\n' "$*" >&2
    exit 1
}

if (( EUID != 0 )); then
    fail "run this script as root"
fi

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_ARTIFACTS="${KERNEL_ARTIFACTS:-$PROJECT_DIR/kernel-artifacts}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/system-artifacts}"
UCM_SOURCE_DIR="${UCM_SOURCE_DIR:-}"
DEBIAN_SUITE="${DEBIAN_SUITE:-trixie}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-https://deb.debian.org/debian}"
DESKTOP_ENVIRONMENT="${DESKTOP_ENVIRONMENT:-phosh}"

case "$DESKTOP_ENVIRONMENT" in
phosh|xfce)
    DEFAULT_ROOTFS_SIZE=6G
    ;;
none)
    DEFAULT_ROOTFS_SIZE=3G
    ;;
*)
    fail "unsupported desktop environment: $DESKTOP_ENVIRONMENT"
    ;;
esac

ROOTFS_SIZE="${ROOTFS_SIZE:-$DEFAULT_ROOTFS_SIZE}"
BOOTFS_SIZE="${BOOTFS_SIZE:-1G}"

for command in chroot debootstrap find gzip img2simg mke2fs mount mountpoint \
    openssl qemu-aarch64-static rsync sha256sum truncate umount uuidgen wc; do
    command -v "$command" >/dev/null || fail "missing required command: $command"
done

[[ -d "$PROJECT_DIR/firmware" ]] || fail "firmware directory not found"
[[ -d "$KERNEL_ARTIFACTS" ]] || fail "kernel artifacts directory not found"

mapfile -d '' KERNEL_PACKAGES < <(
    find "$KERNEL_ARTIFACTS" -maxdepth 1 -type f \
        -name 'linux-image-*.deb' ! -name '*-dbg_*' -print0
)
(( ${#KERNEL_PACKAGES[@]} > 0 )) || fail "no non-debug linux-image package found"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/debian-on-mido.XXXXXX")"
ROOTFS_DIR="$WORK_DIR/rootfs"
BOOTFS_DIR="$WORK_DIR/bootfs"

unmount_chroot() {
    for path in dev sys proc; do
        if mountpoint -q "$ROOTFS_DIR/$path"; then
            umount -R "$ROOTFS_DIR/$path" || umount -l "$ROOTFS_DIR/$path"
        fi
    done
}

cleanup() {
    set +e
    unmount_chroot
    rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT INT TERM

mkdir -p "$ROOTFS_DIR" "$BOOTFS_DIR" "$OUTPUT_DIR"

if [[ ! -e "/usr/share/debootstrap/scripts/$DEBIAN_SUITE" ]]; then
    ln -s sid "/usr/share/debootstrap/scripts/$DEBIAN_SUITE"
fi

if [[ ! -e /proc/sys/fs/binfmt_misc/register ]]; then
    mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc || true
fi
if command -v update-binfmts >/dev/null; then
    update-binfmts --enable qemu-aarch64
fi

log "bootstrapping Debian $DEBIAN_SUITE"
debootstrap --arch=arm64 --foreign "$DEBIAN_SUITE" "$ROOTFS_DIR" "$DEBIAN_MIRROR"
install -m 0755 "$(command -v qemu-aarch64-static)" \
    "$ROOTFS_DIR/usr/bin/qemu-aarch64-static"

mount -t proc proc "$ROOTFS_DIR/proc"
mount --rbind /sys "$ROOTFS_DIR/sys"
mount --make-rslave "$ROOTFS_DIR/sys"
mount --bind /dev "$ROOTFS_DIR/dev"
mount --make-rslave "$ROOTFS_DIR/dev"
mount --bind /dev/pts "$ROOTFS_DIR/dev/pts"
mountpoint -q "$ROOTFS_DIR/proc"
mountpoint -q "$ROOTFS_DIR/sys"
mountpoint -q "$ROOTFS_DIR/dev/pts"

chroot "$ROOTFS_DIR" /debootstrap/debootstrap --second-stage
cp --dereference --remove-destination /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"

cat > "$ROOTFS_DIR/etc/apt/sources.list" <<EOF_SOURCES
deb $DEBIAN_MIRROR $DEBIAN_SUITE main contrib non-free-firmware
deb $DEBIAN_MIRROR $DEBIAN_SUITE-updates main contrib non-free-firmware
deb https://security.debian.org/debian-security $DEBIAN_SUITE-security main contrib non-free-firmware
EOF_SOURCES

printf 'xiaomi-mido\n' > "$ROOTFS_DIR/etc/hostname"
cat >> "$ROOTFS_DIR/etc/hosts" <<'EOF_HOSTS'
127.0.1.1 xiaomi-mido
EOF_HOSTS

install -d "$ROOTFS_DIR/lib/firmware"
rsync -a "$PROJECT_DIR/firmware/" "$ROOTFS_DIR/lib/firmware/"

install -d "$ROOTFS_DIR/tmp/kernel-packages"
for package in "${KERNEL_PACKAGES[@]}"; do
    install -m 0644 "$package" "$ROOTFS_DIR/tmp/kernel-packages/"
done

install -d "$ROOTFS_DIR/etc/initramfs-tools/hooks"
cat > "$ROOTFS_DIR/etc/initramfs-tools/modules" <<'EOF_MODULES'
edt_ft5x06
goodix_ts
msm
panel_xiaomi_boe_ili9885
panel_xiaomi_ebbg_r63350
panel_xiaomi_nt35532
panel_xiaomi_otm1911
panel_xiaomi_tianma_nt35596
EOF_MODULES

cat > "$ROOTFS_DIR/etc/initramfs-tools/hooks/mido-fw" <<'EOF_HOOK'
#!/bin/sh
PREREQ=""

prereqs()
{
    echo "$PREREQ"
}

case "$1" in
prereqs)
    prereqs
    exit 0
    ;;
esac

. /usr/share/initramfs-tools/hook-functions
add_firmware qcom/msm8953/xiaomi/mido/a506_zap.mdt
add_firmware qcom/msm8953/xiaomi/mido/a506_zap.elf
add_firmware qcom/msm8953/xiaomi/mido/a506_zap.b00
add_firmware qcom/msm8953/xiaomi/mido/a506_zap.b01
add_firmware qcom/msm8953/xiaomi/mido/a506_zap.b02
EOF_HOOK
chmod 0755 "$ROOTFS_DIR/etc/initramfs-tools/hooks/mido-fw"

cat > "$ROOTFS_DIR/etc/systemd/system/resizefs.service" <<'EOF_RESIZE'
[Unit]
Description=Expand root filesystem to fill partition
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/bin/bash -c 'exec /usr/sbin/resize2fs $(findmnt -nvo SOURCE /)'
ExecStartPost=/usr/bin/systemctl disable resizefs.service
RemainAfterExit=true

[Install]
WantedBy=default.target
EOF_RESIZE

cat > "$ROOTFS_DIR/etc/systemd/system/serial-getty@ttyGS0.service" <<'EOF_SERIAL'
[Unit]
Description=Serial Console Service on ttyGS0

[Service]
ExecStart=-/usr/sbin/agetty -L 115200 ttyGS0 xterm-256color
Type=idle
Restart=always
RestartSec=0

[Install]
WantedBy=multi-user.target
EOF_SERIAL

printf 'g_serial\n' >> "$ROOTFS_DIR/etc/modules"

cat > "$ROOTFS_DIR/tmp/provision-mido.sh" <<'EOF_PROVISION'
#!/bin/bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install --yes \
    alsa-ucm-conf \
    apt-transport-https \
    bash-completion \
    ca-certificates \
    console-setup \
    dbus \
    file \
    firmware-qcom-soc \
    initramfs-tools \
    iproute2 \
    iptables \
    locales \
    locales-all \
    man-db \
    micro \
    network-manager \
    openssh-server \
    python3 \
    rfkill \
    sudo \
    systemd-sysv \
    systemd-timesyncd \
    tmux \
    usbutils \
    vim \
    zstd

case "${DESKTOP_ENVIRONMENT:-phosh}" in
phosh)
    apt-get install --yes \
        alsa-utils \
        dconf-cli \
        dconf-editor \
        firefox-esr \
        firefox-esr-l10n-zh-cn \
        fonts-noto-cjk \
        gdm3 \
        gnome-text-editor \
        gnome-tweaks \
        loupe \
        nautilus \
        phosh \
        phosh-full \
        phosh-phone
    ;;
xfce)
    apt-get install --yes \
        blueman \
        fcitx5 \
        fcitx5-chinese-addons \
        firefox-esr \
        fonts-wqy-zenhei \
        lightdm \
        lightdm-gtk-greeter \
        mousepad \
        network-manager-gnome \
        onboard \
        policykit-1 \
        ristretto \
        xinput \
        xfce4 \
        xfce4-power-manager \
        xfce4-terminal \
        xorg \
        yad
    ;;
none)
    ;;
esac

apt-get install --yes /tmp/kernel-packages/linux-image-*.deb

if ! id debian >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash debian
fi
for group in audio bluetooth input netdev plugdev render sudo video; do
    if getent group "$group" >/dev/null; then
        usermod -aG "$group" debian
    fi
done

systemctl enable NetworkManager.service
systemctl enable resizefs.service
systemctl enable serial-getty@ttyGS0.service
systemctl enable ssh.service
systemctl enable systemd-timesyncd.service

case "${DESKTOP_ENVIRONMENT:-phosh}" in
phosh)
    systemctl enable gdm3.service
    systemctl set-default graphical.target
    install -d /etc/dconf/db/local.d
    cat > /etc/dconf/db/local.d/00-mido <<'EOF_DCONF'
[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-timeout=0
sleep-inactive-ac-type='nothing'
EOF_DCONF
    dconf update
    ;;
xfce)
    systemctl enable lightdm.service
    systemctl set-default graphical.target
    install -d /etc/lightdm/lightdm.conf.d
    cat > /etc/lightdm/lightdm.conf.d/50-mido.conf <<'EOF_LIGHTDM'
[Seat:*]
greeter-hide-users=false
EOF_LIGHTDM
    cat > /etc/lightdm/lightdm-gtk-greeter.conf <<'EOF_GREETER'
[greeter]
font-name=Monospace 24
keyboard=onboard -l Phone -e
a11y-states=+keyboard;+font
position=50%,center 35%,center
keyboard-position=50%,center -0;100% 40%
EOF_GREETER
    printf 'MOZ_USE_XINPUT2 DEFAULT=1\n' >> /etc/security/pam_env.conf
    printf 'QT_FONT_DPI=192\n' >> /etc/environment
    ;;
none)
    ;;
esac

update-initramfs -u -k all
apt-get clean
EOF_PROVISION
chmod 0755 "$ROOTFS_DIR/tmp/provision-mido.sh"

log "installing system packages and kernel"
DESKTOP_ENVIRONMENT="$DESKTOP_ENVIRONMENT" \
    chroot "$ROOTFS_DIR" /tmp/provision-mido.sh

PASSWORD_HEX="$(openssl rand -hex 4)"
INITIAL_PASSWORD="$(printf '%08d' "$(( 0x$PASSWORD_HEX % 100000000 ))")"
printf 'root:%s\ndebian:%s\n' "$INITIAL_PASSWORD" "$INITIAL_PASSWORD" |
    chroot "$ROOTFS_DIR" /usr/sbin/chpasswd

if [[ "$DESKTOP_ENVIRONMENT" == phosh ]]; then
    SQUEEKBOARD_DIR="$ROOTFS_DIR/home/debian/.local/share/squeekboard/keyboards/terminal"
    install -d "$SQUEEKBOARD_DIR"
    rsync -a "$PROJECT_DIR/squeekboard-layouts/terminal/" "$SQUEEKBOARD_DIR/"
    chroot "$ROOTFS_DIR" /bin/chown -R debian:debian \
        /home/debian/.local/share/squeekboard
fi

if [[ -n "$UCM_SOURCE_DIR" ]]; then
    [[ -d "$UCM_SOURCE_DIR" ]] || fail "ALSA UCM source directory not found"
    install -d "$ROOTFS_DIR/usr/share/alsa/ucm2"
    rsync -a "$UCM_SOURCE_DIR/" "$ROOTFS_DIR/usr/share/alsa/ucm2/"
fi

mapfile -t KERNEL_VERSIONS < <(find "$ROOTFS_DIR/lib/modules" -mindepth 1 \
    -maxdepth 1 -type d -printf '%f\n' | sort -V)
(( ${#KERNEL_VERSIONS[@]} > 0 )) || fail "installed kernel version not found"
KERNEL_VERSION="${KERNEL_VERSIONS[-1]}"

DTB_DIR="$ROOTFS_DIR/usr/lib/linux-image-$KERNEL_VERSION/qcom"
[[ -d "$DTB_DIR" ]] || fail "installed kernel DTB directory not found"
mapfile -d '' MIDO_DTBS < <(find "$DTB_DIR" -maxdepth 1 -type f \
    -name '*mido*.dtb' -print0)
(( ${#MIDO_DTBS[@]} > 0 )) || fail "no mido DTB found in kernel package"
for dtb in "${MIDO_DTBS[@]}"; do
    install -m 0644 "$dtb" "$ROOTFS_DIR/boot/"
done

ROOTFS_UUID="$(uuidgen)"
BOOTFS_UUID="$(uuidgen)"
install -d "$ROOTFS_DIR/boot/extlinux"
cat > "$ROOTFS_DIR/boot/extlinux/extlinux.conf" <<EOF_EXTLINUX
timeout 1
default Debian
menu title Debian on mido

label Debian
    kernel /vmlinuz-$KERNEL_VERSION
    fdtdir /
    initrd /initrd.img-$KERNEL_VERSION
    append console=tty0 root=UUID=$ROOTFS_UUID rw loglevel=3 splash
EOF_EXTLINUX

cat > "$ROOTFS_DIR/etc/fstab" <<EOF_FSTAB
UUID=$ROOTFS_UUID / ext4 defaults 0 1
UUID=$BOOTFS_UUID /boot ext2 defaults 0 2
EOF_FSTAB

INITRAMFS="$ROOTFS_DIR/boot/initrd.img-$KERNEL_VERSION"
[[ -f "$INITRAMFS" ]] || fail "initramfs was not generated"
INITRAMFS_SIZE="$(stat -c '%s' "$INITRAMFS")"
KERNEL_IMAGE="$ROOTFS_DIR/boot/vmlinuz-$KERNEL_VERSION"
[[ -f "$KERNEL_IMAGE" ]] || fail "compressed kernel image was not generated"
KERNEL_UNCOMPRESSED_SIZE="$(gzip -cd "$KERNEL_IMAGE" | wc -c)"
LK2ND_BOOT_MEM_SIZE="${LK2ND_BOOT_MEM_SIZE:-$((64 * 1024 * 1024))}"
LK2ND_RAMDISK_SIZE="$(( (INITRAMFS_SIZE + 4095) / 4096 * 4096 ))"
LK2ND_KERNEL_MAX_SIZE="$((LK2ND_BOOT_MEM_SIZE - LK2ND_RAMDISK_SIZE - 2 * 1024 * 1024 - 512 * 1024))"
if (( LK2ND_KERNEL_MAX_SIZE <= 0 || KERNEL_UNCOMPRESSED_SIZE > LK2ND_KERNEL_MAX_SIZE )); then
    fail "kernel and initramfs exceed lk2nd boot memory: kernel=$KERNEL_UNCOMPRESSED_SIZE max=$LK2ND_KERNEL_MAX_SIZE"
fi

rsync -a "$ROOTFS_DIR/boot/" "$BOOTFS_DIR/"
find "$ROOTFS_DIR/boot" -mindepth 1 -delete
rm -rf "$ROOTFS_DIR/tmp/kernel-packages" "$ROOTFS_DIR/tmp/provision-mido.sh"
find "$ROOTFS_DIR/var/lib/apt/lists" -mindepth 1 -delete
rm -f "$ROOTFS_DIR/usr/bin/qemu-aarch64-static"

unmount_chroot

log "creating filesystem images"
ROOTFS_RAW="$WORK_DIR/rootfs.img"
BOOTFS_RAW="$WORK_DIR/bootfs.img"
truncate -s "$ROOTFS_SIZE" "$ROOTFS_RAW"
truncate -s "$BOOTFS_SIZE" "$BOOTFS_RAW"
mke2fs -q -t ext4 -F -U "$ROOTFS_UUID" -L rootfs -d "$ROOTFS_DIR" "$ROOTFS_RAW"
mke2fs -q -t ext2 -F -U "$BOOTFS_UUID" -L bootfs -d "$BOOTFS_DIR" "$BOOTFS_RAW"

img2simg "$ROOTFS_RAW" "$OUTPUT_DIR/rootfs-simg.img"
img2simg "$BOOTFS_RAW" "$OUTPUT_DIR/bootfs-simg.img"

cat > "$OUTPUT_DIR/credentials.txt" <<EOF_CREDENTIALS
username=debian
password=$INITIAL_PASSWORD
root_password=$INITIAL_PASSWORD
EOF_CREDENTIALS
chmod 0600 "$OUTPUT_DIR/credentials.txt"

cat > "$OUTPUT_DIR/build-info.txt" <<EOF_INFO
debian_suite=$DEBIAN_SUITE
desktop_environment=$DESKTOP_ENVIRONMENT
kernel_version=$KERNEL_VERSION
rootfs_uuid=$ROOTFS_UUID
bootfs_uuid=$BOOTFS_UUID
initramfs_size=$INITRAMFS_SIZE
kernel_uncompressed_size=$KERNEL_UNCOMPRESSED_SIZE
lk2nd_boot_mem_size=$LK2ND_BOOT_MEM_SIZE
lk2nd_kernel_max_size=$LK2ND_KERNEL_MAX_SIZE
EOF_INFO

(
    cd "$OUTPUT_DIR"
    sha256sum bootfs-simg.img rootfs-simg.img > SHA256SUMS
)

log "system images created in $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR"
