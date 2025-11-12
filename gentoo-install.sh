#!/bin/bash
################################################################################
# Gentoo Linux Automated Installer
# Comprehensive installation script for Gentoo Linux (CLI/minimal setup)
# Supports multiple AMD64 systems with CPU auto-detection
################################################################################

set -Eeuo pipefail

# Logging setup
readonly LOG="/var/log/gentoo-install-$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
exec > >(tee -a "$LOG") 2>&1

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

################################################################################
# Helper Functions
################################################################################

die() {
    echo -e "${RED}ERROR: $*${NC}" >&2
    cleanup
    exit 1
}

step() {
    echo -e "\n${GREEN}===> $*${NC}"
}

info() {
    echo -e "${BLUE}---> $*${NC}"
}

warn() {
    echo -e "${YELLOW}WARN: $*${NC}"
}

require_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root"
}

need_cmd() {
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
    done
}

cleanup() {
    if mountpoint -q /mnt/gentoo 2>/dev/null; then
        info "Unmounting filesystems..."
        umount -R /mnt/gentoo 2>/dev/null || true
    fi
    swapoff -a 2>/dev/null || true
}

confirm() {
    local prompt="$1"
    local response
    read -p "$prompt [y/N]: " response
    [[ "$response" =~ ^[Yy]$ ]]
}

trap 'die "Command failed at line $LINENO: $BASH_COMMAND"' ERR
trap cleanup EXIT

################################################################################
# CPU Detection and Optimization
################################################################################

detect_cpu_march() {
    local cpu_info vendor model
    
    cpu_info=$(cat /proc/cpuinfo 2>/dev/null || echo "")
    vendor=$(echo "$cpu_info" | grep -m1 "vendor_id" | awk '{print $3}')
    model=$(echo "$cpu_info" | grep -m1 "model name" | cut -d: -f2 | xargs)
    
    info "Detected CPU: $model" >&2
    
    # Detect CPU architecture for optimization
    if [[ "$vendor" == "AuthenticAMD" ]]; then
        # AMD CPU detection
        if echo "$model" | grep -qi "Ryzen.*7000\|EPYC.*Genoa\|EPYC.*Bergamo"; then
            echo "znver4"  # Zen 4
        elif echo "$model" | grep -qi "Ryzen.*5000\|Ryzen.*6000\|EPYC.*Milan\|Threadripper.*5000"; then
            echo "znver3"  # Zen 3
        elif echo "$model" | grep -qi "Ryzen.*3000\|Ryzen.*4000\|EPYC.*Rome\|Threadripper.*3000"; then
            echo "znver2"  # Zen 2
        elif echo "$model" | grep -qi "Ryzen.*2000\|Ryzen.*1000\|EPYC.*Naples\|Threadripper.*[12]000"; then
            echo "znver1"  # Zen 1
        else
            echo "x86-64"  # Generic AMD64
        fi
    elif [[ "$vendor" == "GenuineIntel" ]]; then
        # Intel CPU detection
        if echo "$model" | grep -qi "13th Gen\|14th Gen\|Raptor Lake"; then
            echo "raptorlake"
        elif echo "$model" | grep -qi "12th Gen\|Alder Lake"; then
            echo "alderlake"
        elif echo "$model" | grep -qi "11th Gen\|Rocket Lake"; then
            echo "rocketlake"
        elif echo "$model" | grep -qi "10th Gen\|Comet Lake"; then
            echo "cometlake"
        elif echo "$model" | grep -qi "Ice Lake"; then
            echo "icelake-client"
        elif echo "$model" | grep -qi "Coffee Lake\|9th Gen\|8th Gen"; then
            echo "coffeelake"
        elif echo "$model" | grep -qi "Kaby Lake\|7th Gen"; then
            echo "kabylake"
        elif echo "$model" | grep -qi "Skylake\|6th Gen"; then
            echo "skylake"
        elif echo "$model" | grep -qi "Haswell\|4th Gen"; then
            echo "haswell"
        elif echo "$model" | grep -qi "Ivy Bridge\|3rd Gen"; then
            echo "ivybridge"
        elif echo "$model" | grep -qi "Sandy Bridge\|2nd Gen"; then
            echo "sandybridge"
        else
            echo "x86-64"  # Generic x86-64
        fi
    else
        echo "x86-64"  # Generic fallback
    fi
}

################################################################################
# System Detection
################################################################################

step "Detecting system configuration..."

require_root
need_cmd parted mkfs.ext4 mkfs.vfat mkswap curl tar sha512sum lsblk blkid

# Configure DNS for installation environment
info "Configuring DNS..."
echo "nameserver 1.1.1.1" > /etc/resolv.conf
echo "nameserver 1.0.0.1" >> /etc/resolv.conf

# Detect CPU and optimal march
CPU_MARCH=$(detect_cpu_march)
info "Optimal -march flag: $CPU_MARCH"

# Detect UEFI
if [ -d /sys/firmware/efi ]; then
    DEFAULT_BOOT_MODE="UEFI"
    info "UEFI firmware detected"
else
    DEFAULT_BOOT_MODE="BIOS"
    info "BIOS firmware detected"
fi

# Detect CPU cores
NCORES=$(nproc)
info "CPU cores: $NCORES"

# Detect RAM and calculate auto swap
MEM_KIB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
MEM_GIB=$(( (MEM_KIB + 1048575) / 1048576 ))
info "RAM: ${MEM_GIB} GiB"

if (( MEM_GIB <= 2 )); then
    AUTO_SWAP_GIB=$(( MEM_GIB * 2 ))
elif (( MEM_GIB <= 8 )); then
    AUTO_SWAP_GIB=$(( (MEM_GIB * 3) / 2 ))
elif (( MEM_GIB <= 64 )); then
    AUTO_SWAP_GIB=$MEM_GIB
else
    AUTO_SWAP_GIB=$(( MEM_GIB / 2 ))
fi
[[ $AUTO_SWAP_GIB -gt 32 ]] && AUTO_SWAP_GIB=32  # Cap at 32GB

# Detect disks
echo ""
info "Available disks:"
lsblk -e7 -d -o NAME,SIZE,TYPE,MODEL | grep -v "loop\|rom"

# Suggest default disk
if [ -b /dev/nvme0n1 ]; then
    DEFAULT_DISK="/dev/nvme0n1"
elif [ -b /dev/sda ]; then
    DEFAULT_DISK="/dev/sda"
elif [ -b /dev/vda ]; then
    DEFAULT_DISK="/dev/vda"
else
    DEFAULT_DISK=""
fi

################################################################################
# Interactive Configuration
################################################################################

step "Configuration Questions"
echo "This script will install Gentoo Linux. Please answer the following questions."
echo "Defaults are shown in [brackets]. Press Enter to accept default."
echo ""

# Target disk
while true; do
    read -p "Target disk [${DEFAULT_DISK}]: " DISK
    DISK=${DISK:-$DEFAULT_DISK}
    [ -b "$DISK" ] && break
    warn "Disk $DISK does not exist. Please enter a valid block device."
done
info "Selected disk: $DISK"

# Wipe confirmation
echo ""
warn "ALL DATA ON $DISK WILL BE DESTROYED!"
echo -n "Type 'WIPE' to confirm: "
read WIPE_CONFIRM
[[ "$WIPE_CONFIRM" == "WIPE" ]] || die "Installation aborted"

# Boot mode
while true; do
    read -p "Boot mode (UEFI/BIOS) [${DEFAULT_BOOT_MODE}]: " BOOT_MODE
    BOOT_MODE=${BOOT_MODE:-$DEFAULT_BOOT_MODE}
    BOOT_MODE=$(echo "$BOOT_MODE" | tr '[:lower:]' '[:upper:]')
    [[ "$BOOT_MODE" == "UEFI" || "$BOOT_MODE" == "BIOS" ]] && break
done

# Partition layout
read -p "Partition layout (simple/custom) [simple]: " LAYOUT
LAYOUT=${LAYOUT:-simple}

# Root filesystem
while true; do
    read -p "Root filesystem (ext4/btrfs/xfs) [ext4]: " ROOT_FS
    ROOT_FS=${ROOT_FS:-ext4}
    [[ "$ROOT_FS" =~ ^(ext4|btrfs|xfs)$ ]] && break
done

# Swap size
read -p "Swap size in GiB (none/${MEM_GIB} for RAM size) [none]: " SWAP_INPUT
SWAP_INPUT=${SWAP_INPUT:-none}
if [[ "$SWAP_INPUT" == "none" ]]; then
    SWAP_SIZE_GIB=0
    info "No swap partition will be created"
elif [[ "$SWAP_INPUT" =~ ^[0-9]+$ ]]; then
    SWAP_SIZE_GIB=$SWAP_INPUT
    info "Swap size: ${SWAP_SIZE_GIB} GiB"
else
    die "Invalid swap size. Please enter a number or 'none'"
fi

# Stage3 selection
while true; do
    read -p "Init system (openrc/systemd) [openrc]: " INIT_SYSTEM
    INIT_SYSTEM=${INIT_SYSTEM:-openrc}
    INIT_SYSTEM=$(echo "$INIT_SYSTEM" | tr '[:upper:]' '[:lower:]')
    [[ "$INIT_SYSTEM" =~ ^(openrc|systemd)$ ]] && break
done

# Stage3 flavor - always minimal
STAGE3_FLAVOR="minimal"

# Kernel method
while true; do
    read -p "Kernel method (bin/genkernel/manual) [genkernel]: " KERNEL_METHOD
    KERNEL_METHOD=${KERNEL_METHOD:-genkernel}
    KERNEL_METHOD=$(echo "$KERNEL_METHOD" | tr '[:upper:]' '[:lower:]')
    [[ "$KERNEL_METHOD" =~ ^(bin|genkernel|manual)$ ]] && break
done

# CPU optimization confirmation
echo ""
info "Detected CPU optimization: -march=$CPU_MARCH"
read -p "Use this optimization? (y/n) [y]: " USE_CPU_OPT
USE_CPU_OPT=${USE_CPU_OPT:-y}
if [[ ! "$USE_CPU_OPT" =~ ^[Yy]$ ]]; then
    read -p "Enter custom -march value [x86-64]: " CUSTOM_MARCH
    CPU_MARCH=${CUSTOM_MARCH:-x86-64}
fi

# Timezone
read -p "Timezone [America/New_York]: " TIMEZONE
TIMEZONE=${TIMEZONE:-America/New_York}

# Hostname
read -p "Hostname [gentoo]: " HOSTNAME
HOSTNAME=${HOSTNAME:-gentoo}

# Root password
while true; do
    read -s -p "Root password: " ROOT_PASSWORD
    echo ""
    read -s -p "Confirm root password: " ROOT_PASSWORD2
    echo ""
    [[ "$ROOT_PASSWORD" == "$ROOT_PASSWORD2" ]] && break
    warn "Passwords do not match. Try again."
done
[[ -n "$ROOT_PASSWORD" ]] || die "Password cannot be empty"

# Bootloader
if [[ "$BOOT_MODE" == "BIOS" ]]; then
    BOOTLOADER="grub2"
    info "Bootloader: GRUB2 (required for BIOS)"
else
    while true; do
        read -p "Bootloader (grub2/systemd-boot) [grub2]: " BOOTLOADER
        BOOTLOADER=${BOOTLOADER:-grub2}
        BOOTLOADER=$(echo "$BOOTLOADER" | tr '[:upper:]' '[:lower:]')
        [[ "$BOOTLOADER" =~ ^(grub2|systemd-boot)$ ]] && break
    done
    if [[ "$BOOTLOADER" == "systemd-boot" && "$INIT_SYSTEM" != "systemd" ]]; then
        warn "systemd-boot requires systemd. Switching to GRUB2."
        BOOTLOADER="grub2"
    fi
fi

################################################################################
# Validation and Derived Values
################################################################################

step "Validating configuration..."

# Determine partition naming scheme
if [[ "$DISK" =~ nvme|mmcblk|loop ]]; then
    PART_PREFIX="${DISK}p"
else
    PART_PREFIX="${DISK}"
fi

# Stage3 URL mapping
case "${STAGE3_FLAVOR}_${INIT_SYSTEM}" in
    minimal_openrc)
        STAGE3_DIR="current-stage3-amd64-openrc"
        STAGE3_LATEST="stage3-amd64-openrc-current-stage3-amd64-openrc.tar.xz"
        ;;
    minimal_systemd)
        STAGE3_DIR="current-stage3-amd64-systemd"
        STAGE3_LATEST="latest-stage3-amd64-systemd.txt"
        ;;
    desktop_openrc)
        STAGE3_DIR="current-stage3-amd64-desktop-openrc"
        STAGE3_LATEST="latest-stage3-amd64-desktop-openrc.txt"
        ;;
    desktop_systemd)
        STAGE3_DIR="current-stage3-amd64-desktop-systemd"
        STAGE3_LATEST="latest-stage3-amd64-desktop-systemd.txt"
        ;;
    *)
        die "Unsupported stage3 combination"
        ;;
esac

STAGE3_BASE_URL="https://distfiles.gentoo.org/releases/amd64/autobuilds"

echo ""
info "Configuration summary:"
info "  Disk: $DISK"
info "  Boot mode: $BOOT_MODE"
info "  Layout: $LAYOUT"
info "  Root FS: $ROOT_FS"
info "  Swap: ${SWAP_SIZE_GIB} GiB"
info "  Init: $INIT_SYSTEM"
info "  Stage3: $STAGE3_FLAVOR"
info "  Kernel: $KERNEL_METHOD"
info "  CPU optimization: -march=$CPU_MARCH"
info "  Timezone: $TIMEZONE"
info "  Hostname: $HOSTNAME"
info "  Bootloader: $BOOTLOADER"
echo ""

confirm "Proceed with installation?" || die "Installation aborted by user"

################################################################################
# Partitioning
################################################################################

step "Partitioning disk $DISK..."

info "Wiping existing signatures..."
wipefs -a "$DISK"
dd if=/dev/zero of="$DISK" bs=512 count=1 conv=notrunc 2>/dev/null || true

if [[ "$BOOT_MODE" == "UEFI" ]]; then
    info "Creating GPT partition table..."
    parted -s "$DISK" mklabel gpt
    
    info "Creating EFI partition (512 MiB)..."
    parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
    parted -s "$DISK" set 1 esp on
    P_EFI="${PART_PREFIX}1"
    
    
    if [[ $SWAP_SIZE_GIB -gt 0 ]]; then
        info "Creating swap partition (${SWAP_SIZE_GIB} GiB)..."
        SWAP_END=$((513 + SWAP_SIZE_GIB * 1024))
        parted -s "$DISK" mkpart primary linux-swap 513MiB ${SWAP_END}MiB
        P_SWAP="${PART_PREFIX}2"
        
        info "Creating root partition (remaining space)..."
        parted -s "$DISK" mkpart primary $ROOT_FS ${SWAP_END}MiB 100%
        P_ROOT="${PART_PREFIX}3"
    else
        info "Skipping swap partition..."
        P_SWAP=""
        
        info "Creating root partition (remaining space)..."
        parted -s "$DISK" mkpart primary $ROOT_FS 513MiB 100%
        P_ROOT="${PART_PREFIX}2"
    fi
else
    info "Creating MBR partition table..."
    parted -s "$DISK" mklabel msdos
    
    info "Creating boot partition (1 GiB)..."
    parted -s "$DISK" mkpart primary ext4 1MiB 1025MiB
    parted -s "$DISK" set 1 boot on
    P_BOOT="${PART_PREFIX}1"
    
    if [[ $SWAP_SIZE_GIB -gt 0 ]]; then
        info "Creating swap partition (${SWAP_SIZE_GIB} GiB)..."
        SWAP_END=$((1025 + SWAP_SIZE_GIB * 1024))
        parted -s "$DISK" mkpart primary linux-swap 1025MiB ${SWAP_END}MiB
        P_SWAP="${PART_PREFIX}2"
        
        info "Creating root partition (remaining space)..."
        parted -s "$DISK" mkpart primary $ROOT_FS ${SWAP_END}MiB 100%
        P_ROOT="${PART_PREFIX}3"
    else
        info "Skipping swap partition..."
        P_SWAP=""
        
        info "Creating root partition (remaining space)..."
        parted -s "$DISK" mkpart primary $ROOT_FS 1025MiB 100%
        P_ROOT="${PART_PREFIX}2"
    fi
fi

partprobe "$DISK"
sleep 3
udevadm settle 2>/dev/null || sleep 2

info "Partitions created successfully"
lsblk "$DISK"

################################################################################
# Filesystem Creation
################################################################################

step "Creating filesystems..."

if [[ "$BOOT_MODE" == "UEFI" ]]; then
    info "Formatting EFI partition..."
    mkfs.vfat -F 32 -n EFI "$P_EFI"
else
    info "Formatting boot partition..."
    mkfs.ext4 -F -L boot "$P_BOOT"
fi

info "Formatting root partition with $ROOT_FS..."
case "$ROOT_FS" in
    ext4)
        mkfs.ext4 -F -L root "$P_ROOT"
        ROOT_MOUNT_OPTS="defaults,noatime"
        ;;
    btrfs)
        mkfs.btrfs -f -L root "$P_ROOT"
        ROOT_MOUNT_OPTS="noatime,compress=zstd"
        ;;
    xfs)
        mkfs.xfs -f -L root "$P_ROOT"
        ROOT_MOUNT_OPTS="noatime,inode64"
        ;;
esac

if [[ $SWAP_SIZE_GIB -gt 0 ]]; then
    info "Creating swap..."
    mkswap -L swap "$P_SWAP"
    swapon "$P_SWAP"
fi

################################################################################
# Mounting
################################################################################

step "Mounting filesystems..."

mkdir -p /mnt/gentoo
mount -o "$ROOT_MOUNT_OPTS" "$P_ROOT" /mnt/gentoo

mkdir -p /mnt/gentoo/boot
if [[ "$BOOT_MODE" == "UEFI" ]]; then
    mount "$P_EFI" /mnt/gentoo/boot
else
    mount "$P_BOOT" /mnt/gentoo/boot
fi

info "Filesystems mounted"
df -h | grep /mnt/gentoo

################################################################################
# Stage3 Download and Verification
################################################################################

step "Downloading stage3 tarball..."

cd /tmp

STAGE3_FILE="stage3-amd64-openrc-20250302T170343Z.tar.xz"
STAGE3_FULL_URL="$STAGE3_BASE_URL/20250302T170343Z/$STAGE3_FILE"
info "Downloading $STAGE3_FILE..."
curl -f -L -o "$STAGE3_FILE" "$STAGE3_FULL_URL" || die "Failed to download stage3 tarball"

info "Downloading DIGESTS..."
curl -f -L -o "${STAGE3_FILE}.DIGESTS" "${STAGE3_FULL_URL}.DIGESTS" || die "Failed to download DIGESTS"

info "Verifying checksum..."
DIGEST_LINE=$(grep -A1 "# SHA512 HASH" "${STAGE3_FILE}.DIGESTS" | grep "^[0-9a-f]" | grep "${STAGE3_FILE}" | head -1)
EXPECTED_SHA512=$(echo "$DIGEST_LINE" | awk '{print $1}')
ACTUAL_SHA512=$(sha512sum "$STAGE3_FILE" | awk '{print $1}')

if [[ "$EXPECTED_SHA512" != "$ACTUAL_SHA512" ]]; then
    die "Checksum verification failed! Expected: $EXPECTED_SHA512, Got: $ACTUAL_SHA512"
fi

info "Stage3 verified successfully"

################################################################################
# Extract Stage3
################################################################################

step "Extracting stage3 to /mnt/gentoo..."

umask 022
tar xpf "$STAGE3_FILE" -C /mnt/gentoo --xattrs-include='*.*' --numeric-owner || die "Failed to extract stage3"

info "Stage3 extracted successfully"

################################################################################
# Configure make.conf
################################################################################

step "Configuring make.conf..."

cat >> /mnt/gentoo/etc/portage/make.conf << EOF

# CPU-optimized compilation flags
CFLAGS="-march=${CPU_MARCH} -O2 -pipe"
CXXFLAGS="\${CFLAGS}"
MAKEOPTS="-j${NCORES}"

# Additional useful settings
ACCEPT_LICENSE="*"
ACCEPT_KEYWORDS="~amd64"
EOF

info "make.conf configured with -march=$CPU_MARCH"

################################################################################
# Prepare Chroot
################################################################################

step "Preparing chroot environment..."

info "Copying DNS configuration..."
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/

info "Mounting pseudo-filesystems..."
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --rbind /run /mnt/gentoo/run 2>/dev/null || mount --bind /run /mnt/gentoo/run
mount --make-rslave /mnt/gentoo/run 2>/dev/null || true

################################################################################
# Generate Chroot Script
################################################################################

step "Generating chroot installation script..."

# Get UUIDs for fstab
if [[ "$BOOT_MODE" == "UEFI" ]]; then
    BOOT_UUID=$(blkid -s UUID -o value "$P_EFI")
else
    BOOT_UUID=$(blkid -s UUID -o value "$P_BOOT")
fi
ROOT_UUID=$(blkid -s UUID -o value "$P_ROOT")
if [[ -z "$P_SWAP" ]]; then
    SWAP_UUID=""
else
    SWAP_UUID=$(blkid -s UUID -o value "$P_SWAP")
fi

cat > /mnt/gentoo/root/chroot-install.sh << 'CHROOT_SCRIPT_START'
#!/bin/bash
set -Eeuo pipefail

echo "===> Entering chroot environment..."

source /etc/profile
export PS1="(chroot) \$PS1"

echo "===> Syncing Gentoo repository..."
emerge-webrsync || { echo "emerge-webrsync failed, trying fallback..."; emerge --sync; }

echo "===> Selecting system profile..."
CHROOT_SCRIPT_START

# Add variables to chroot script
cat >> /mnt/gentoo/root/chroot-install.sh << CHROOT_VARS
INIT_SYSTEM="$INIT_SYSTEM"
STAGE3_FLAVOR="$STAGE3_FLAVOR"
HOSTNAME="$HOSTNAME"
TIMEZONE="$TIMEZONE"
ROOT_UUID="$ROOT_UUID"
BOOT_UUID="$BOOT_UUID"
SWAP_UUID="$SWAP_UUID"
ROOT_FS="$ROOT_FS"
ROOT_MOUNT_OPTS="$ROOT_MOUNT_OPTS"
BOOT_MODE="$BOOT_MODE"
KERNEL_METHOD="$KERNEL_METHOD"
BOOTLOADER="$BOOTLOADER"
DISK="$DISK"
CHROOT_VARS

# Continue chroot script
cat >> /mnt/gentoo/root/chroot-install.sh << 'CHROOT_SCRIPT_CONT'

# Profile selection
if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    PROFILE_PATTERN="systemd"
else
    PROFILE_PATTERN="default/linux/amd64/17"
fi

PROFILE_NUM=$(eselect profile list | grep -i "$PROFILE_PATTERN" | grep -v "no-multilib\|hardened\|musl\|x32" | head -1 | awk '{print $1}' | tr -d '[]') || true

if [[ -n "$PROFILE_NUM" ]]; then
    eselect profile set "$PROFILE_NUM" || echo "WARN: Failed to set profile $PROFILE_NUM"
    echo "---> Profile set to: $(eselect profile show | tail -1)"
else
    echo "WARN: Could not auto-detect profile, using current default"
    eselect profile show
fi

source /etc/profile

echo "===> Configuring timezone..."
echo "$TIMEZONE" > /etc/timezone
emerge --config sys-libs/timezone-data

echo "===> Configuring locale..."
grep -q "en_US.UTF-8 UTF-8" /etc/locale.gen || echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set en_US.utf8 || eselect locale set C.UTF-8
env-update && source /etc/profile

echo "===> Configuring hostname and networking..."
if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    echo "$HOSTNAME" > /etc/hostname
else
    echo "hostname=\"$HOSTNAME\"" > /etc/conf.d/hostname
fi

cat > /etc/hosts << 'HOSTS_EOF'
127.0.0.1    localhost
::1          localhost ip6-localhost ip6-loopback
HOSTS_EOF
echo "127.0.1.1    $HOSTNAME" >> /etc/hosts

echo "===> Installing dhcpcd..."
emerge --quiet net-misc/dhcpcd || emerge net-misc/dhcpcd

if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    systemctl enable dhcpcd || systemctl enable systemd-networkd
else
    rc-update add dhcpcd default
fi


echo "===> Resolving Python dependencies..."
emerge --quiet --update --deep --newuse @world || emerge --update --deep --newuse @world

echo "===> Installing kernel ($KERNEL_METHOD method)..."
case "$KERNEL_METHOD" in
    bin)
        emerge --quiet sys-kernel/gentoo-kernel-bin sys-kernel/linux-firmware || \
        emerge sys-kernel/gentoo-kernel-bin sys-kernel/linux-firmware
        ;;
    genkernel)
        emerge --quiet sys-kernel/gentoo-sources sys-kernel/genkernel sys-kernel/linux-firmware || \
        emerge sys-kernel/gentoo-sources sys-kernel/genkernel sys-kernel/linux-firmware
        eselect kernel set 1
        genkernel --install all
        ;;
    manual)
        emerge --quiet sys-kernel/gentoo-sources sys-kernel/linux-firmware bc bison flex elfutils dev-libs/openssl || \
        emerge sys-kernel/gentoo-sources sys-kernel/linux-firmware bc bison flex elfutils dev-libs/openssl
        cd /usr/src/linux
        make defconfig
        make olddefconfig
        make -j$(nproc) || make
        make modules_install
        make install
        ;;
esac

echo "===> Generating /etc/fstab..."
cat > /etc/fstab << 'FSTAB_EOF'
# <fs>          <mountpoint>  <type>  <opts>              <dump/pass>
FSTAB_EOF

echo "UUID=$ROOT_UUID  /      $ROOT_FS  $ROOT_MOUNT_OPTS  0 1" >> /etc/fstab

if [[ "$BOOT_MODE" == "UEFI" ]]; then
    echo "UUID=$BOOT_UUID  /boot  vfat     defaults,noatime  0 2" >> /etc/fstab
else
    echo "UUID=$BOOT_UUID  /boot  ext4     defaults,noatime  0 2" >> /etc/fstab
fi

if [[ -n "$SWAP_UUID" ]]; then
    echo "UUID=$SWAP_UUID  none   swap     sw                0 0" >> /etc/fstab
fi

echo "---> /etc/fstab created"
cat /etc/fstab

echo "===> Installing bootloader ($BOOTLOADER)..."
if [[ "$BOOTLOADER" == "grub2" ]]; then
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        emerge --quiet sys-boot/grub:2 sys-boot/efibootmgr || emerge sys-boot/grub:2 sys-boot/efibootmgr
        grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Gentoo --recheck
        grub-mkconfig -o /boot/grub/grub.cfg
    else
        emerge --quiet sys-boot/grub:2 || emerge sys-boot/grub:2
        grub-install --target=i386-pc "$DISK"
        grub-mkconfig -o /boot/grub/grub.cfg
    fi
elif [[ "$BOOTLOADER" == "systemd-boot" ]]; then
    bootctl --path=/boot install
    
    mkdir -p /boot/loader/entries
    
    cat > /boot/loader/loader.conf << 'LOADER_EOF'
default gentoo.conf
timeout 3
console-mode max
editor no
LOADER_EOF
    
    KERNEL_VER=$(ls /boot/vmlinuz-* 2>/dev/null | head -1 | sed 's|/boot/vmlinuz-||' || echo "")
    INITRD_FILE=$(ls /boot/initramfs-*.img 2>/dev/null | head -1 | xargs basename || echo "")
    
    cat > /boot/loader/entries/gentoo.conf << ENTRY_EOF
title   Gentoo Linux
linux   /vmlinuz-${KERNEL_VER}
ENTRY_EOF
    
    if [[ -n "$INITRD_FILE" ]]; then
        echo "initrd  /$INITRD_FILE" >> /boot/loader/entries/gentoo.conf
    fi
    
    echo "options root=UUID=$ROOT_UUID rw" >> /boot/loader/entries/gentoo.conf
fi

echo "===> Installing essential services..."
emerge --quiet app-admin/sysklogd sys-process/cronie app-portage/gentoolkit || \
emerge app-admin/sysklogd sys-process/cronie app-portage/gentoolkit

if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    systemctl enable cronie 2>/dev/null || true
else
    rc-update add sysklogd default
    rc-update add cronie default
fi

echo "===> Chroot installation complete!"
CHROOT_SCRIPT_CONT

# Add root password to chroot script
cat >> /mnt/gentoo/root/chroot-install.sh << CHROOT_PASSWORD
echo "===> Setting root password..."
echo "root:$ROOT_PASSWORD" | chpasswd
CHROOT_PASSWORD

chmod +x /mnt/gentoo/root/chroot-install.sh

################################################################################
# Execute Chroot Script
################################################################################

step "Executing chroot installation..."

chroot /mnt/gentoo /bin/bash /root/chroot-install.sh || die "Chroot installation failed"

################################################################################
# Finalization
################################################################################

step "Installation complete!"

info "Cleaning up..."
cleanup

cat << FINAL_MSG

${GREEN}╔════════════════════════════════════════════════════════════════╗
║             Gentoo Linux Installation Complete!               ║
╚════════════════════════════════════════════════════════════════╝${NC}

${BLUE}Installation Summary:${NC}
  • Disk: $DISK
  • Boot Mode: $BOOT_MODE
  • Filesystem: $ROOT_FS
  • Init System: $INIT_SYSTEM
  • Kernel: $KERNEL_METHOD
  • Bootloader: $BOOTLOADER
  • Hostname: $HOSTNAME
  • CPU Optimization: -march=$CPU_MARCH

${YELLOW}Next Steps:${NC}
  1. Review the installation log: $LOG
  2. Reboot your system: ${GREEN}reboot${NC}
  3. Remove the installation media
  4. Log in with root and your configured password

${GREEN}Your Gentoo system is ready to boot!${NC}

FINAL_MSG

exit 0
