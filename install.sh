#!/usr/bin/env bash
set -Eeuo pipefail

LOG_FILE="/tmp/nen-install.log"
TOTAL_STEPS=10
CURRENT_STEP=0
UI_MODE="welcome"
BOOTLOADER="systemd-boot"

print_header() {
  cat <<'H'

        +++###################################################################
        +++###################################################################
        +++###################################################################
        #+++##################################################################
        ######################################################################
        ############################+++++++++++###############################
        ########################+++++++++++++++++++###########################
        ######################++++++++++++++++++++++##########################
        ####################++++++++++++++++++++++++++########################
        ###################+++++++++++++++++++++++++++++######################
        #################++++++++++++++++###++++++++++++++####################
        ###############++++++++++++#########++####++##+++++###################
        #############+++++++++++++########################++##################
        #############+++++++++++++########################++##################
        ############++++++++++++++#########################+##################
        ###########+++++++++++++++############################################
        ###########+++++++++++++++##++++######################################
        ##########+++++++++++++++++-+++++#############+-+#####################
        ##########+++++++++++++++++-+##+-+############+++#####################
        ##########++++++++++++++++#++++++##############++#####################
        #########+++++++++++++++++############################################
        ########++++++++++++++++++############################################
        ########++++++++++++++++++#######++++-+++++++++----+################++
        ########++++++++++++++++++#####++-------------------+##########+++++++
        ########++++++++++++++++++#####+++++++++++++++--+---+######+++#+######
        ########++++++++++++++++++#####################+++--+#################
        #######+++++++++++++++++++#######################++++#+###############
        #######++++++++++++++++++++########################++++###############
        #######++++++++++++++++++++######################+++++++##############
        #######++++++++++++++++++++#####################+++++++++#############
        #######++++++++++++++++++++#################++++#++++++++#############
        #######++++++++++++++-+++++++###+++#########++++##+++++++#############
        #######+++++++++++++++++++++##################++###+#+++++############
        #######+++++++++++++++++++++#################++######++#++############
        #######+##+++++++++++#+++++++##############++##+++###+###+############
        ############+++++++++#+++++++############+++#+++-++###################
        ##############++++++++++++++++++#######+++##++-----++#################
        #############++++++++++++++++++++++####+#+++---+----++################
        ############+++++++++++++++++++++++####+++++----------+###############
                                                                         
                            ▄                                                    
        ▄▄  ▄▄ ▄▄▄▄▄ ▄▄  ▄▄ ▀ ▄▄▄▄    ▄▄▄▄ ▄▄ ▄▄  ▄▄▄▄ ▄▄▄▄▄▄ ▄▄▄  ▄▄   ▄▄  ▄▄▄▄ 
        ███▄██ ██▄▄  ███▄██  ███▄▄   ██▀▀▀ ██ ██ ███▄▄   ██  ██▀██ ██▀▄▀██ ███▄▄ 
        ██ ▀██ ██▄▄▄ ██ ▀██  ▄▄██▀   ▀████ ▀███▀ ▄▄██▀   ██  ▀███▀ ██   ██ ▄▄██▀ 
                                                                         
H
}

render() {
  clear
  print_header
  if [[ "$UI_MODE" == "welcome" ]]; then
    printf "\nWelcome.\n"
    printf "\n"
    return
  fi
  printf "\nIf the progress bar is not moving, it means the installation is still running.\n"
  printf "Do NOT cut the power or turn off your computer under any circumstances!\n"
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
  trap - ERR
  set +e
  tput cnorm 2>/dev/null || true
  UI_MODE="progress"
  render
  printf "\nERROR: Installation failed.\n\n"
  printf "Log: %s\n\n" "$LOG_FILE"
  tail -n 80 "$LOG_FILE" 2>/dev/null || true
}

trap on_error ERR

HOSTNAME="archlinux"
TIMEZONE="Europe/Istanbul"
LOCALE="en_US.UTF-8"
KEYMAP="trq"

EFI_SIZE_MIB=1024
BTRFS_COMPRESS="zstd:3"

ENABLE_MULTILIB=1
SWAP_SIZE="16G"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }; }

cleanup() {
  tput cnorm 2>/dev/null || true
  umount -R /mnt 2>/dev/null || true
}
trap cleanup EXIT

tput civis 2>/dev/null || true
render

for c in lsblk awk sort sgdisk mkfs.fat mkfs.btrfs mount umount \
         pacstrap genfstab arch-chroot timedatectl partprobe blkid \
         grep sed cat chmod btrfs swapoff df pacman mountpoint reboot tput clear tail seq mkswap swapon curl; do
  need "$c"
done

if ! curl -fsSL --max-time 5 https://archlinux.org/ >/dev/null 2>&1; then
  clear
  print_header
  printf "\nInternet connection is required!\n"
  printf "Exiting in 5 seconds...\n"
  sleep 5
  exit 1
fi

if [[ ! -d /sys/firmware/efi/efivars ]]; then
  echo "ERROR: System is not booted in UEFI mode."
  exit 1
fi

read -rp "Enter username: " USERNAME < /dev/tty
while [[ -z "$USERNAME" ]]; do
  read -rp "Username cannot be empty: " USERNAME < /dev/tty
done

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

while true; do
  echo
  echo "Bootloader selection:"
  echo "  1) systemd-boot"
  echo "  2) GRUB"
  read -rp "Select [1-2] (default: 1): " BOOT_CHOICE < /dev/tty
  BOOT_CHOICE="${BOOT_CHOICE:-1}"
  case "$BOOT_CHOICE" in
    1) BOOTLOADER="systemd-boot"; break ;;
    2) BOOTLOADER="grub"; break ;;
    *) echo "Invalid selection. Try again." ;;
  esac
done

UI_MODE="progress"
render
log "Starting installer"
log "Bootloader selected: $BOOTLOADER"
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
  P3="${DISK}p3"
else
  P1="${DISK}1"
  P2="${DISK}2"
  P3="${DISK}3"
fi

umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true

while read -r mp; do
  [[ -n "$mp" ]] || continue
  umount "$mp" 2>/dev/null || true
done < <(lsblk -nrpo MOUNTPOINT "$P1" "$P2" "$P3" 2>/dev/null | awk 'NF')
log "Creating partition table"
sgdisk --zap-all "$DISK" >>"$LOG_FILE" 2>&1
sgdisk -o "$DISK" >>"$LOG_FILE" 2>&1
sgdisk -n "1:0:+${EFI_SIZE_MIB}M" -t 1:ef00 -c 1:EFI "$DISK" >>"$LOG_FILE" 2>&1
sgdisk -n "2:0:+${SWAP_SIZE}"      -t 2:8200 -c 2:SWAP "$DISK" >>"$LOG_FILE" 2>&1
sgdisk -n "3:0:0"                  -t 3:8300 -c 3:ARCH "$DISK" >>"$LOG_FILE" 2>&1
partprobe "$DISK" >>"$LOG_FILE" 2>&1 || true
sleep 1

log "Formatting partitions"
mkfs.fat -F32 -n EFI "$P1" >>"$LOG_FILE" 2>&1
mkfs.btrfs -f -L ARCH "$P3" >>"$LOG_FILE" 2>&1
mkswap -L SWAP "$P2" >>"$LOG_FILE" 2>&1
swapon "$P2" >>"$LOG_FILE" 2>&1 || true
progress_next

log "Mounting filesystems"
mount -o noatime,compress=$BTRFS_COMPRESS "$P3" /mnt >>"$LOG_FILE" 2>&1
mkdir -p /mnt/boot
mount -o umask=0077 "$P1" /mnt/boot >>"$LOG_FILE" 2>&1
progress_next

log "Updating keyring"
pacman -Sy --noconfirm archlinux-keyring >>"$LOG_FILE" 2>&1 || true

progress_next

log "Installing base system"
PKGS=(
  base linux linux-firmware
  intel-ucode
  btrfs-progs
  sudo
  base-devel
  git
  go
  networkmanager
  bluez bluez-utils
  pipewire pipewire-pulse wireplumber
  nvidia nvidia-utils nvidia-settings
)

if [[ "$BOOTLOADER" == "grub" ]]; then
  PKGS+=(grub efibootmgr)
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

useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd
echo "root:$PASSWORD" | chpasswd

sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

if systemctl list-unit-files | grep -q '^NetworkManager\.service'; then
  systemctl enable NetworkManager
fi
if systemctl list-unit-files | grep -q '^bluetooth\.service'; then
  systemctl enable bluetooth
fi

mkdir -p /etc/sudoers.d
chmod 750 /etc/sudoers.d
printf '%s\n' "$USERNAME ALL=(ALL) NOPASSWD: /usr/bin/pacman" > /etc/sudoers.d/99-yay
chmod 440 /etc/sudoers.d/99-yay

runuser -u "$USERNAME" -- /bin/bash -euo pipefail <<'YAY'
cd /tmp
rm -rf yay
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si --noconfirm
YAY

rm -f /etc/sudoers.d/99-yay

ROOT_UUID=\$(blkid -s UUID -o value "$P3")
BOOT_OPTS="root=UUID=\$ROOT_UUID rw"
if pacman -Q nvidia-utils >/dev/null 2>&1; then
  BOOT_OPTS+=" nvidia-drm.modeset=1"
fi

if [[ "$BOOTLOADER" == "systemd-boot" ]]; then
  if [[ -d /sys/firmware/efi/efivars ]] && ! mountpoint -q /sys/firmware/efi/efivars; then
    mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null || true
  fi
  bootctl install
  cat > /boot/loader/loader.conf <<L
default arch
timeout 2
editor no
L
  cat > /boot/loader/entries/arch.conf <<L
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options \$BOOT_OPTS
L
else
  if pacman -Q nvidia-utils >/dev/null 2>&1; then
    if grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
      sed -i 's/^GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 nvidia-drm.modeset=1"/' /etc/default/grub || true
    else
      printf '%s\n' 'GRUB_CMDLINE_LINUX="nvidia-drm.modeset=1"' >> /etc/default/grub
    fi
  fi
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
  grub-mkconfig -o /boot/grub/grub.cfg
fi

EOF

tput cnorm 2>/dev/null || true
CURRENT_STEP=$TOTAL_STEPS
render
printf "\nInstallation completed. Rebooting in 5 seconds...\n"
sleep 5
reboot
