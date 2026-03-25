#!/usr/bin/env bash
set -Eeuo pipefail

# --- Color Definitions ---
G='\033[0;32m' # Green
R='\033[0;31m' # Red
Y='\033[1;33m' # Yellow
C='\033[0;36m' # Cyan
NC='\033[0m'   # Reset

LOG_FILE="/tmp/nen-install.log"
TOTAL_STEPS=10
CURRENT_STEP=0

# --- Minimalist ASCII Logo ---
print_header() {
  clear
  echo -e "${C}"
  cat <<"EOF"
    | \ | | ___ _ __  / ___|   / \   |  _ \  / ___|
    |  \| |/ _ \ '_ \ \___ \  / _ \  | |_) | \___ \
    | |\  |  __/ | | | ___) |/ ___ \ |  _ <   ___) |
    |_| \_|\___|_| |_||____//_/   \_\|_| \_\ |____/
    ------------------------------------------------
           >> CUSTOM ARCH LINUX INSTALLER <<
EOF
  echo -e "${NC}"
}

# --- Advanced Progress Bar ---
render() {
  print_header
  local width=45
  local percent=$(( CURRENT_STEP * 100 / TOTAL_STEPS ))
  local filled=$(( CURRENT_STEP * width / TOTAL_STEPS ))
  local empty=$(( width - filled ))
  
  echo -e "${Y}Status: Processing... (Do not power off!)${NC}"
  printf "Progress: ["
  printf "${G}%0.s█${NC}" $(seq 1 "$filled" 2>/dev/null || echo "")
  printf "${NC}%0.s░${NC}" $(seq 1 "$empty" 2>/dev/null || echo "")
  printf "] %d%%\n\n" "$percent"
}

log() { echo -e "${C}[$(date +%T)]${NC} $*" >>"$LOG_FILE"; }

progress_next() {
  ((CURRENT_STEP++)) || true
  render
}

# --- Hardware Detection & Disk Selection ---
detect_and_select() {
    # Environment Detection
    VIRT_TYPE=$(systemd-detect-virt)
    PKGS="base linux linux-firmware base-devel btrfs-progs networkmanager sudo git"

    if [[ "$VIRT_TYPE" != "none" ]]; then
        log "Virtualization detected: $VIRT_TYPE"
        PKGS+=" virtualbox-guest-utils"
    else
        log "Physical machine detected."
        PKGS+=" nvidia nvidia-utils nvidia-settings"
    fi

    # Disk Selection
    echo -e "${Y}Available Disks:${NC}"
    lsblk -dno NAME,SIZE,MODEL | grep -v -E "loop|sr[0-9]"
    echo ""
    read -p "Select Target Disk (e.g., sda or nvme0n1): " SELECTED_DISK < /dev/tty
    DISK="/dev/$(echo $SELECTED_DISK | xargs)"
    
    if [[ ! -b "$DISK" ]]; then echo -e "${R}Error: Invalid block device!${NC}"; exit 1; fi
}

# --- Error Handling ---
on_error() {
  echo -e "\n${R}!!! FATAL ERROR: Check $LOG_FILE for details.${NC}"
  exit 1
}
trap on_error ERR

# --- MAIN INSTALLATION PROCESS ---
detect_and_select

read -rp "Enter username: " USERNAME < /dev/tty
read -rsp "Enter password: " PASSWORD < /dev/tty; echo

render

# 1. Disk Partitioning
log "Partitioning $DISK"
sgdisk --zap-all "$DISK" >>"$LOG_FILE" 2>&1
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:EFI "$DISK" >>"$LOG_FILE" 2>&1
sgdisk -n 2:0:+8G -t 2:8200 -c 2:SWAP "$DISK" >>"$LOG_FILE" 2>&1
sgdisk -n 3:0:0    -t 3:8300 -c 3:ROOT "$DISK" >>"$LOG_FILE" 2>&1
partprobe "$DISK"
progress_next

# 2. Assigning Partition Paths
[[ "$DISK" =~ "nvme" ]] && P1="${DISK}p1" P2="${DISK}p2" P3="${DISK}p3" || P1="${DISK}1" P2="${DISK}2" P3="${DISK}3"
progress_next

# 3. Formatting & Btrfs Layout
log "Formatting partitions and creating Btrfs subvolumes"
mkfs.fat -F32 "$P1" >>"$LOG_FILE" 2>&1
mkfs.btrfs -f "$P3" >>"$LOG_FILE" 2>&1
mkswap "$P2" >>"$LOG_FILE" 2>&1
swapon "$P2" >>"$LOG_FILE" 2>&1

mount "$P3" /mnt
btrfs subvolume create /mnt/@ >>"$LOG_FILE" 2>&1
btrfs subvolume create /mnt/@home >>"$LOG_FILE" 2>&1
umount /mnt

mount -o noatime,compress=zstd:3,subvol=@ "$P3" /mnt
mkdir -p /mnt/{boot,home}
mount -o noatime,compress=zstd:3,subvol=@home "$P3" /mnt/home
mount "$P1" /mnt/boot
progress_next

# 4. Base System Installation
log "Installing core packages: $PKGS"
pacstrap /mnt $PKGS >>"$LOG_FILE" 2>&1
progress_next

# 5. System Configuration
log "Configuring fstab and chroot"
genfstab -U /mnt >> /mnt/etc/fstab

arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/Europe/Istanbul /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "nens-customs" > /etc/hostname
useradd -m -G wheel -s /bin/bash $USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd
echo "root:$PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
systemctl enable NetworkManager

# Virtualization Guest Service
if [[ "$VIRT_TYPE" == "oracle" || "$VIRT_TYPE" == "virtualbox" ]]; then
    systemctl enable vboxservice
fi

# Bootloader (systemd-boot)
bootctl install
echo -e "default arch\ntimeout 3\neditor no" > /boot/loader/loader.conf
echo -e "title Arch Linux\nlinux /vmlinuz-linux\ninitrd /initramfs-linux.img\noptions root=UUID=\$(blkid -s UUID -o value $P3) rw rootflags=subvol=@ nvidia-drm.modeset=1" > /boot/loader/entries/arch.conf
EOF
progress_next

# Finalizing
CURRENT_STEP=$TOTAL_STEPS
render
echo -e "${G}Installation Complete Successfully!${NC}"
echo "Rebooting in 5 seconds..."
sleep 5
reboot
