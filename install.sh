#!/usr/bin/env bash
set -euo pipefail

#############################################
# ARCH LINUX AUTOMATIC INSTALLER
# Hyprland + Ly + BTRFS + NVIDIA + prime-run
# Swap: 16G
#
# Asks ONLY:
#   - username
#   - password (same for user and root)
#
# Hostname is always: archlinux
# UEFI only
#############################################

HOSTNAME="archlinux"
TIMEZONE="Europe/Istanbul"
LOCALE="en_US.UTF-8"
KEYMAP="trq"

EFI_SIZE_MIB=1024
BTRFS_COMPRESS="zstd:3"

ENABLE_MULTILIB=1
INSTALL_NVIDIA=1
SWAP_SIZE="16G"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }; }

for c in lsblk awk sort sgdisk mkfs.fat mkfs.btrfs mount umount \
         pacstrap genfstab arch-chroot timedatectl partprobe blkid \
         grep sed cat chmod; do
  need "$c"
done

if [[ ! -d /sys/firmware/efi/efivars ]]; then
  echo "ERROR: System is not booted in UEFI mode."
  exit 1
fi

echo
read -rp "Enter username: " USERNAME
while [[ -z "$USERNAME" ]]; do
  read -rp "Username cannot be empty: " USERNAME
done

while true; do
  read -rsp "Enter password: " PASSWORD; echo
  read -rsp "Confirm password: " PASSWORD2; echo
  [[ "$PASSWORD" == "$PASSWORD2" ]] && break
  echo "Passwords do not match. Try again."
done

echo "Enabling NTP"
timedatectl set-ntp true || true

echo "Detecting target disk"
DISK="$(
  lsblk -dpno NAME,TYPE,SIZE,RM | \
    awk '$2=="disk" && $4==0 {print $1, $3}' | \
    sort -h -k2 | tail -n1 | awk '{print $1}'
)"

if [[ -z "$DISK" ]]; then
  echo "No suitable disk found."
  exit 1
fi

echo "Selected disk: $DISK"
echo "All data on this disk will be destroyed in 3 seconds."
sleep 3

if [[ "$DISK" =~ (nvme|mmcblk) ]]; then
  P1="${DISK}p1"
  P2="${DISK}p2"
else
  P1="${DISK}1"
  P2="${DISK}2"
fi

umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true

echo "Creating partition table"
sgdisk --zap-all "$DISK"
sgdisk -o "$DISK"
sgdisk -n "1:0:+${EFI_SIZE_MIB}M" -t 1:ef00 -c 1:EFI "$DISK"
sgdisk -n "2:0:0"                 -t 2:8300 -c 2:ARCH "$DISK"
partprobe "$DISK"
sleep 1

echo "Formatting partitions"
mkfs.fat -F32 -n EFI "$P1"
mkfs.btrfs -f -L ARCH "$P2"

echo "Creating BTRFS subvolumes"
mount "$P2" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@pkg
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@swap
umount /mnt

echo "Mounting filesystems"
mount -o noatime,compress=$BTRFS_COMPRESS,subvol=@ "$P2" /mnt
mkdir -p /mnt/{boot,home,var/log,var/cache/pacman/pkg,.snapshots,.swap}

mount -o noatime,compress=$BTRFS_COMPRESS,subvol=@home "$P2" /mnt/home
mount -o noatime,compress=$BTRFS_COMPRESS,subvol=@log "$P2" /mnt/var/log
mount -o noatime,compress=$BTRFS_COMPRESS,subvol=@pkg "$P2" /mnt/var/cache/pacman/pkg
mount -o noatime,compress=$BTRFS_COMPRESS,subvol=@snapshots "$P2" /mnt/.snapshots
mount -o noatime,subvol=@swap "$P2" /mnt/.swap
mount "$P1" /mnt/boot

echo "Updating keyring"
pacman -Sy --noconfirm archlinux-keyring >/dev/null || true

echo "Installing base system"
PKGS=(
  base linux linux-firmware
  sudo nano vim
  networkmanager
  git curl wget
  btrfs-progs
  hyprland ly waybar foot
  pipewire pipewire-pulse wireplumber
  xdg-desktop-portal xdg-desktop-portal-hyprland
  bluez bluez-utils
  polkit
  wl-clipboard grim slurp brightnessctl playerctl
  nautilus
  mesa vulkan-icd-loader
)

if [[ "$INSTALL_NVIDIA" == "1" ]]; then
  PKGS+=(nvidia nvidia-utils nvidia-settings)
  if [[ "$ENABLE_MULTILIB" == "1" ]]; then
    PKGS+=(lib32-nvidia-utils)
  fi
fi

pacstrap /mnt "${PKGS[@]}"

echo "Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab

echo "Configuring system (chroot)"
arch-chroot /mnt /bin/bash -euo pipefail <<EOF

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

sed -i 's/^#\\($LOCALE\\)/\\1/' /etc/locale.gen || true
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<H
127.0.0.1 localhost
::1 localhost
127.0.1.1 $HOSTNAME.localdomain $HOSTNAME
H

if [[ "$ENABLE_MULTILIB" == "1" ]]; then
  if ! grep -q '^\\[multilib\\]' /etc/pacman.conf; then
    cat >> /etc/pacman.conf <<H2

[multilib]
Include = /etc/pacman.d/mirrorlist
H2
  else
    sed -i '/\\[multilib\\]/{n;s/^#//;}' /etc/pacman.conf || true
  fi
  pacman -Sy --noconfirm
fi

useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd
echo "root:$PASSWORD" | chpasswd

sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

systemctl enable NetworkManager
systemctl enable bluetooth
systemctl disable getty@tty2.service
systemctl enable ly@tty2.service

echo "Creating prime-run"
cat > /usr/bin/prime-run <<'PR'
#!/bin/bash
export __NV_PRIME_RENDER_OFFLOAD=1
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export __VK_LAYER_NV_optimus=NVIDIA_only
exec "\$@"
PR
chmod +x /usr/bin/prime-run

echo "Creating swapfile (16G)"
chattr +C /.swap
btrfs filesystem mkswapfile --size $SWAP_SIZE /.swap/swapfile
chmod 600 /.swap/swapfile
swapon /.swap/swapfile
echo "/.swap/swapfile none swap defaults 0 0" >> /etc/fstab

bootctl install

ROOT_UUID=\$(blkid -s UUID -o value "$P2")

cat > /boot/loader/loader.conf <<L
default arch
timeout 2
editor no
L

cat > /boot/loader/entries/arch.conf <<L
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=UUID=\$ROOT_UUID rootflags=subvol=@ rw nvidia-drm.modeset=1
L

mkdir -p "/home/$USERNAME/.config/hypr"
cat > "/home/$USERNAME/.config/hypr/hyprland.conf" <<'HC'
monitor=,preferred,auto,1
exec-once=waybar

input {
  kb_layout=tr
}

bind=SUPER,Return,exec,foot
bind=SUPER,Q,killactive
bind=SUPER,M,exit
HC

chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.config"

EOF

echo
echo "Installation completed."
echo "You can reboot with:"
echo "  umount -R /mnt && reboot"
