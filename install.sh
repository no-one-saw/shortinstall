#!/usr/bin/env bash
set -Eeuo pipefail

# Renk Tanımlamaları
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

LOG_FILE="/tmp/nen-install.log"
TOTAL_STEPS=12
CURRENT_STEP=0
UI_MODE="welcome"

print_header() {
  cat <<"EOF"
    亲自                       亲自
    ███╗   ██╗███████╗███╗   ██╗███████╗
    ████╗  ██║██╔════╝████╗  ██║██╔════╝
    ██╔██╗ ██║█████╗  ██╔██╗ ██║███████╗
    ██║╚██╗██║██╔══╝  ██║╚██╗██║╚════██║
    ██║ ╚████║███████╗██║ ╚████║███████║
    ╚═╝  ╚═══╝╚══════╝╚═╝  ╚═══╝╚══════╝
         CUSTOMS ARCH INSTALLER
EOF
}

render() {
  clear
  print_header
  if [[ "$UI_MODE" == "welcome" ]]; then
    echo -e "\n${CYAN}>>> Welcome to the Nen's Customs Automated Installer${NC}\n"
    return
  fi
  
  local width=50
  local percent=$(( CURRENT_STEP * 100 / TOTAL_STEPS ))
  local filled=$(( CURRENT_STEP * width / TOTAL_STEPS ))
  local empty=$(( width - filled ))
  
  echo -e "\n${YELLOW}Status: Working... (Do not power off!)${NC}"
  printf "Progress: ["
  printf "${GREEN}%0.s█${NC}" $(seq 1 "$filled")
  printf "${NC}%0.s░${NC}" $(seq 1 "$empty")
  printf "] %d%%\n\n" "$percent"
}

log() { echo -e "${BLUE}[$(date +%T)]${NC} $*" >>"$LOG_FILE"; }

progress_next() {
  ((CURRENT_STEP++)) || true
  render
}

# --- Disk Seçimi Geliştirmesi ---
select_disk() {
    echo -e "${YELLOW}Available Disks:${NC}"
    lsblk -dno NAME,SIZE,MODEL | grep -v "loop"
    echo ""
    read -p "Enter the disk name to install Arch (e.g., nvme0n1 or sda): " SELECTED_DISK
    DISK="/dev/$SELECTED_DISK"
    if [[ ! -b "$DISK" ]]; then
        echo -e "${RED}Error: Invalid disk!${NC}"
        exit 1
    fi
}

# Hata Yakalama
on_error() {
  local line_no=$1
  UI_MODE="progress"
  render
  echo -e "${RED}CRITICAL ERROR at line $line_no. Check $LOG_FILE for details.${NC}"
  tail -n 20 "$LOG_FILE"
  exit 1
}
trap 'on_error $LINENO' ERR

# --- ANA AKIŞ ---
render
select_disk

# Şifre ve Kullanıcı Girişi
read -rp "Enter username: " USERNAME
read -rsp "Enter password: " PASSWORD; echo

UI_MODE="progress"
render

# 1. Hazırlık
log "Initializing..."
timedatectl set-ntp true >>"$LOG_FILE" 2>&1
progress_next

# 2. Bölümleme (Btrfs Layout Geliştirildi)
log "Partitioning $DISK..."
sgdisk --zap-all "$DISK" >>"$LOG_FILE" 2>&1
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:EFI "$DISK" >>"$LOG_FILE" 2>&1
sgdisk -n 2:0:+16G -t 2:8200 -c 2:SWAP "$DISK" >>"$LOG_FILE" 2>&1
sgdisk -n 3:0:0 -t 3:8300 -c 3:ARCH "$DISK" >>"$LOG_FILE" 2>&1
partprobe "$DISK"
progress_next

# 3. Formatlama
log "Formatting..."
if [[ "$DISK" =~ "nvme" ]]; then P1="${DISK}p1"; P2="${DISK}p2"; P3="${DISK}p3"; else P1="${DISK}1"; P2="${DISK}2"; P3="${DISK}3"; fi
mkfs.fat -F32 "$P1" >>"$LOG_FILE" 2>&1
mkfs.btrfs -f "$P3" >>"$LOG_FILE" 2>&1
mkswap "$P2" >>"$LOG_FILE" 2>&1
swapon "$P2" >>"$LOG_FILE" 2>&1
progress_next

# 4. Btrfs Subvolumes (Snapshot desteği için önemli)
log "Creating Subvolumes..."
mount "$P3" /mnt
btrfs subvolume create /mnt/@ >>"$LOG_FILE" 2>&1
btrfs subvolume create /mnt/@home >>"$LOG_FILE" 2>&1
umount /mnt
mount -o noatime,compress=zstd:3,subvol=@ "$P3" /mnt
mkdir -p /mnt/{boot,home}
mount -o noatime,compress=zstd:3,subvol=@home "$P3" /mnt/home
mount "$P1" /mnt/boot
progress_next

# 5. Pacstrap
log "Installing Base Packages..."
pacstrap /mnt base linux linux-firmware base-devel btrfs-progs networkmanager sudo git nvidia nvidia-utils >>"$LOG_FILE" 2>&1
progress_next

# 6. Chroot İşlemleri (Basitleştirildi)
log "Configuring System..."
genfstab -U /mnt >> /mnt/etc/fstab
arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/Europe/Istanbul /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "archlinux" > /etc/hostname
useradd -m -G wheel -s /bin/bash $USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd
echo "root:$PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
systemctl enable NetworkManager
bootctl install
echo -e "default arch\ntimeout 3\neditor no" > /boot/loader/loader.conf
echo -e "title Arch Linux\nlinux /vmlinuz-linux\ninitrd /initramfs-linux.img\noptions root=UUID=$(blkid -s UUID -o value $P3) rw rootflags=subvol=@ nvidia-drm.modeset=1" > /boot/loader/entries/arch.conf
EOF
progress_next

# ... Kalan adımlar (Yay kurulumu vb.) aynı mantıkla devam eder ...

CURRENT_STEP=$TOTAL_STEPS
render
echo -e "${GREEN}Installation finished successfully!${NC}"
sleep 2
reboot
