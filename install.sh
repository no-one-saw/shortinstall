#!/usr/bin/env bash
set -Eeuo pipefail

LOG_FILE="/tmp/nen-install.log"
TOTAL_STEPS=10
CURRENT_STEP=0

print_header() {
  cat <<'H'
 _   _            _       ____          _                  
| \ | | ___ _ __ ( )___  / ___|   _ ___| |_ ___  _ __ ___ 
|  \| |/ _ \ '_ \|// __| \___ \  | / __| __/ _ \| '__/ __|
| |\  |  __/ | | | \__ \  ___) | | \__ \ || (_) | |  \__ \
|_| \_|\___|_| |_| |___/ |____/  |_|___/\__\___/|_|  |___/

                nen's customs
H
}

render() {
  clear
  print_header
  local width=40
  local percent=$(( CURRENT_STEP * 100 / TOTAL_STEPS ))
  local filled=$(( CURRENT_STEP * width / TOTAL_STEPS ))
  local empty=$(( width - filled ))
  printf "\n["
  printf "%0.s#" $(seq 1 "$filled")
  printf "%0.s-" $(seq 1 "$empty")
  printf "] %s%%\n" "$percent"
}

log() {
  printf "%s\n" "$*" >>"$LOG_FILE"
}

progress_next() {
  ((CURRENT_STEP++)) || true
  render
}

on_error() {
  tput cnorm 2>/dev/null || true
  render
  printf "\nERROR: Installation failed.\n\n"
  printf "Log: %s\n\n" "$LOG_FILE"
  tail -n 80 "$LOG_FILE" 2>/dev/null || true
}

trap on_error ERR

tput civis 2>/dev/null || true
render

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

cleanup() {
  tput cnorm 2>/dev/null || true
  umount -R /mnt 2>/dev/null || true
}
trap cleanup EXIT

for c in lsblk awk sort sgdisk mkfs.fat mkfs.btrfs mount umount \
         pacstrap genfstab arch-chroot timedatectl partprobe blkid \
         grep sed cat chmod btrfs chattr swapoff df pacman mountpoint reboot tput clear tail seq; do
  need "$c"
done

if [[ ! -d /sys/firmware/efi/efivars ]]; then
  echo "ERROR: System is not booted in UEFI mode."
  exit 1
fi

read -rp "Enter username: " USERNAME < /dev/tty
while [[ -z "$USERNAME" ]]; do
  read -rp "Username cannot be empty: " USERNAME < /dev/tty
done

render

while true; do
  read -rsp "Enter password: " PASSWORD < /dev/tty; echo
  read -rsp "Confirm password: " PASSWORD2 < /dev/tty; echo
  if [[ -z "$PASSWORD" ]]; then
    echo "Password cannot be empty. Try again."
    continue
  fi
  [[ "$PASSWORD" == "$PASSWORD2" ]] && break
  echo "Passwords do not match. Try again."
done

render
log "Starting installer"
log "Enabling NTP"
timedatectl set-ntp true >>"$LOG_FILE" 2>&1 || true
progress_next

log "Detecting target disk"
DISK="$(
  lsblk -dpno NAME,TYPE,SIZE,RM | \
    awk '$2=="disk" && $4==0 {print $1, $3}' | \
    sort -h -k2 | tail -n1 | awk '{print $1}'
)"

if [[ -z "$DISK" ]]; then
  echo "No suitable disk found."
  exit 1
fi

log "Selected disk: $DISK"
DISK_BYTES="$(lsblk -bdno SIZE "$DISK" | head -n1 || true)"
if [[ -z "$DISK_BYTES" ]]; then
  echo "ERROR: Could not determine disk size for $DISK"
  exit 1
fi

MIN_DISK_BYTES=$((30 * 1024 * 1024 * 1024))
if (( DISK_BYTES < MIN_DISK_BYTES )); then
  echo "ERROR: Disk is too small for this install (need at least 30 GiB)."
  echo "Detected size: $((DISK_BYTES / 1024 / 1024 / 1024)) GiB"
  exit 1
fi

log "All data on this disk will be destroyed in 3 seconds."
sleep 3
progress_next

if [[ "$DISK" =~ (nvme|mmcblk) ]]; then
  P1="${DISK}p1"
  P2="${DISK}p2"
else
  P1="${DISK}1"
  P2="${DISK}2"
fi

umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true

while read -r mp; do
  [[ -n "$mp" ]] || continue
  umount "$mp" 2>/dev/null || true
done < <(lsblk -nrpo MOUNTPOINT "$P1" "$P2" 2>/dev/null | awk 'NF')
log "Creating partition table"
sgdisk --zap-all "$DISK" >>"$LOG_FILE" 2>&1
sgdisk -o "$DISK" >>"$LOG_FILE" 2>&1
sgdisk -n "1:0:+${EFI_SIZE_MIB}M" -t 1:ef00 -c 1:EFI "$DISK" >>"$LOG_FILE" 2>&1
sgdisk -n "2:0:0"                 -t 2:8300 -c 2:ARCH "$DISK" >>"$LOG_FILE" 2>&1
partprobe "$DISK" >>"$LOG_FILE" 2>&1 || true
sleep 1

log "Formatting partitions"
mkfs.fat -F32 -n EFI "$P1" >>"$LOG_FILE" 2>&1
mkfs.btrfs -f -L ARCH "$P2" >>"$LOG_FILE" 2>&1
progress_next

log "Creating BTRFS subvolumes"
mount "$P2" /mnt >>"$LOG_FILE" 2>&1
btrfs subvolume create /mnt/@ >>"$LOG_FILE" 2>&1
btrfs subvolume create /mnt/@home >>"$LOG_FILE" 2>&1
btrfs subvolume create /mnt/@log >>"$LOG_FILE" 2>&1
btrfs subvolume create /mnt/@pkg >>"$LOG_FILE" 2>&1
btrfs subvolume create /mnt/@snapshots >>"$LOG_FILE" 2>&1
btrfs subvolume create /mnt/@swap >>"$LOG_FILE" 2>&1
umount /mnt >>"$LOG_FILE" 2>&1
progress_next

log "Mounting filesystems"
mount -o noatime,compress=$BTRFS_COMPRESS,subvol=@ "$P2" /mnt >>"$LOG_FILE" 2>&1
mkdir -p /mnt/{boot,home,var/log,var/cache/pacman/pkg,.snapshots,.swap}

mount -o noatime,compress=$BTRFS_COMPRESS,subvol=@home "$P2" /mnt/home >>"$LOG_FILE" 2>&1
mount -o noatime,compress=$BTRFS_COMPRESS,subvol=@log "$P2" /mnt/var/log >>"$LOG_FILE" 2>&1
mount -o noatime,compress=$BTRFS_COMPRESS,subvol=@pkg "$P2" /mnt/var/cache/pacman/pkg >>"$LOG_FILE" 2>&1
mount -o noatime,compress=$BTRFS_COMPRESS,subvol=@snapshots "$P2" /mnt/.snapshots >>"$LOG_FILE" 2>&1
mount -o noatime,subvol=@swap "$P2" /mnt/.swap >>"$LOG_FILE" 2>&1
mount -o umask=0077 "$P1" /mnt/boot >>"$LOG_FILE" 2>&1
progress_next

log "Updating keyring"
pacman -Sy --noconfirm archlinux-keyring >>"$LOG_FILE" 2>&1 || true

if [[ "$ENABLE_MULTILIB" == "1" ]]; then
  if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
    cat >> /etc/pacman.conf <<H2

[multilib]
Include = /etc/pacman.d/mirrorlist
H2
  else
    sed -i '/\[multilib\]/{n;s/^#//;}' /etc/pacman.conf || true
  fi
  pacman -Sy --noconfirm >>"$LOG_FILE" 2>&1 || true
fi
progress_next

log "Installing base system"
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

FILTERED_PKGS=()
for p in "${PKGS[@]}"; do
  if pacman -Si "$p" >/dev/null 2>&1; then
    FILTERED_PKGS+=("$p")
  else
    log "WARNING: Package not found in current repos, skipping: $p"
  fi
done
PKGS=("${FILTERED_PKGS[@]}")

AVAIL_BYTES="$(df -B1 --output=avail /mnt | tail -n 1 | tr -d ' ' || true)"
MIN_AVAIL_BYTES=$((12 * 1024 * 1024 * 1024))
if [[ -z "$AVAIL_BYTES" ]]; then
  echo "ERROR: Could not determine free space on /mnt"
  exit 1
fi
if (( AVAIL_BYTES < MIN_AVAIL_BYTES )); then
  echo "ERROR: Not enough free disk space on /mnt for package installation."
  echo "Free: $((AVAIL_BYTES / 1024 / 1024)) MiB (need at least $((MIN_AVAIL_BYTES / 1024 / 1024)) MiB)"
  exit 1
fi

pacstrap /mnt "${PKGS[@]}" >>"$LOG_FILE" 2>&1
progress_next

log "Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab
progress_next

log "Configuring system (chroot)"
arch-chroot /mnt /bin/bash -euo pipefail >>"$LOG_FILE" 2>&1 <<EOF

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

sed -i "s/^#${LOCALE}/${LOCALE}/" /etc/locale.gen || true
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
if systemctl list-unit-files | grep -q '^bluetooth\.service'; then
  systemctl enable bluetooth
fi
if pacman -Q ly >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^ly@\.service'; then
  systemctl disable getty@tty2.service || true
  systemctl enable ly@tty2.service
  if [[ -f /etc/ly/config.ini ]]; then
    if grep -qE '^tty\s*=' /etc/ly/config.ini; then
      sed -i 's/^tty\s*=.*/tty = 2/' /etc/ly/config.ini || true
    else
      printf '\n%s\n' 'tty = 2' >> /etc/ly/config.ini
    fi
  else
    mkdir -p /etc/ly
    cat > /etc/ly/config.ini <<LYC
[main]
tty = 2
LYC
  fi
else
  echo "WARNING: ly is not installed or ly@.service not found; display manager will not be enabled."
fi

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
mkdir -p /.swap
chattr +C /.swap
btrfs filesystem mkswapfile --size $SWAP_SIZE /.swap/swapfile
chmod 600 /.swap/swapfile
swapon /.swap/swapfile
echo "/.swap/swapfile none swap defaults 0 0" >> /etc/fstab

if [[ -d /sys/firmware/efi/efivars ]] && ! mountpoint -q /sys/firmware/efi/efivars; then
  mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null || true
fi

bootctl install

ROOT_UUID=\$(blkid -s UUID -o value "$P2")
BOOT_OPTS="root=UUID=\$ROOT_UUID rootflags=subvol=@ rw"
if pacman -Q nvidia-utils >/dev/null 2>&1; then
  BOOT_OPTS+=" nvidia-drm.modeset=1"
fi

cat > /boot/loader/loader.conf <<L
default arch
timeout 2
editor no
L

cat > /boot/loader/entries/arch.conf <<L
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options \$BOOT_OPTS
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

tput cnorm 2>/dev/null || true
CURRENT_STEP=$TOTAL_STEPS
render
printf "\nInstallation completed. Rebooting in 5 seconds...\n"
sleep 5
reboot
