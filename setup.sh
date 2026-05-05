#!/bin/bash
set -euo pipefail
clear

# ====================== 日志函数 ======================
info() {
    echo -e "\033[32m[INFO]  $1\033[0m"
}
warn() {
    echo -e "\033[33m[WARN]  $1\033[0m"
}
err() {
    echo -e "\033[31m[ERROR] $1\033[0m"
    exit 1
}

# ====================== 新增：检查 /mnt 是否已有挂载 ======================
info "前置检查：检测 /mnt 目录是否已挂载..."
if mount | grep -qs '/mnt'; then
    err "检测到 /mnt 已存在挂载，请先执行：umount -R /mnt 再重新运行脚本"
fi

# ====================== 强制卸载函数 ======================
force_unmount() {
    local dev="$1"
    if grep -qs "$dev" /proc/mounts; then
        warn "强制卸载：$dev"
        umount -lf "$dev" 2>/dev/null || true
    fi
}

# ====================== CPU 检测 ======================
info "检测 CPU 类型..."
if grep -q "Intel" /proc/cpuinfo; then
    MICROCODE="intel-ucode"
    info "检测到 Intel CPU"
elif grep -q "AMD" /proc/cpuinfo; then
    MICROCODE="amd-ucode"
    info "检测到 AMD CPU"
else
    MICROCODE=""
    warn "未知 CPU，跳过微码"
fi

# ====================== 显卡检测 ======================
info "检测显卡类型..."
GPU="none"
while read -r line; do
    if [[ "$line" =~ Intel|intel ]]; then
        GPU="intel"
    elif [[ "$line" =~ NVIDIA|nvidia ]]; then
        GPU="nvidia"
    elif [[ "$line" =~ AMD|ati|ATI ]]; then
        GPU="amd"
    fi
done < <(lspci | grep -E 'VGA|3D|Display')
info "显卡类型：$GPU"

# ====================== 磁盘扫描 ======================
info "扫描可安装磁盘..."
DISK=""
for disk in $(lsblk -dno NAME,TYPE,MOUNTPOINT | awk '/disk/ && !/loop/ && $3=="" {print $1}'); do
    if [[ -z "$DISK" ]]; then
        DISK="/dev/$disk"
    fi
done

if [[ -z "$DISK" ]]; then
    err "未找到可安装磁盘"
fi
info "选定磁盘：$DISK"

# ====================== 分区命名 ======================
if [[ $DISK == *nvme* ]]; then
    EFI_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
else
    EFI_PART="${DISK}1"
    ROOT_PART="${DISK}2"
fi

# ====================== 配置 ======================
TIMEZONE="Asia/Shanghai"
HOSTNAME="arch"
ROOT_PWD="root"
USER_NAME="arch"
USER_PWD="arch"
EFI_SIZE="+1G"
PACMAN_THREADS="15"

# ====================== 安全确认 ======================
warn "⚠️  磁盘 $DISK 将会被清空，5秒后开始（Ctrl+C 取消）"
sleep 5

# 强制卸载所有分区
force_unmount "$EFI_PART"
force_unmount "$ROOT_PART"
sleep 1

# ====================== 彻底清空分区表 ======================
info "开始分区（清空旧分区表）"
sgdisk -Z "$DISK"
partprobe "$DISK"
sleep 1

# 创建新分区
sgdisk -n 1:0:$EFI_SIZE -t 1:ef00 "$DISK"
sgdisk -n 2:0:0 -t 2:8300 "$DISK"

# 双刷新分区表
partprobe "$DISK"
udevadm settle
sleep 2

# ====================== 格式化 ======================
info "格式化 EFI & 根分区"
mkfs.fat -F32 "$EFI_PART"
mkfs.btrfs -f "$ROOT_PART"
sleep 1

# ====================== Btrfs 子卷 ======================
info "批量创建 Btrfs 子卷"
mount "$ROOT_PART" /mnt
SUBVOLUMES=("@" "@home" "@cache" "@log" "@swap" "@snapshots")
for subvol in "${SUBVOLUMES[@]}"; do
    btrfs subvolume create /mnt/$subvol
done

NO_COW=("@swap" "@cache" "@log")
for dir in "${NO_COW[@]}"; do
    chattr +C /mnt/$dir
done

umount /mnt
sleep 1

# ====================== 挂载 ======================
info "批量挂载子卷"
mount -o subvol=@,compress=zstd "$ROOT_PART" /mnt

mkdir -p /mnt/{boot/efi,home,var/cache/pacman,var/log,swap,.snapshots}

mount -o subvol=@home,compress=zstd "$ROOT_PART" /mnt/home
mount -o subvol=@cache "$ROOT_PART" /mnt/var/cache/pacman
mount -o subvol=@log "$ROOT_PART" /mnt/var/log
mount -o subvol=@swap "$ROOT_PART" /mnt/swap
mount -o subvol=@snapshots "$ROOT_PART" /mnt/.snapshots
mount "$EFI_PART" /mnt/boot/efi

# ====================== 安装系统 ======================
info "安装基础系统"
pacstrap -K /mnt base base-devel linux linux-firmware btrfs-progs
pacstrap /mnt networkmanager grub efibootmgr sudo vim openssh

if [[ -n "$MICROCODE" ]]; then
    info "安装 CPU 微码：$MICROCODE"
    pacstrap /mnt "$MICROCODE"
fi

if [[ "$GPU" == "intel" ]]; then
    pacstrap /mnt mesa intel-media-driver
elif [[ "$GPU" == "amd" ]]; then
    pacstrap /mnt mesa vulkan-radeon
elif [[ "$GPU" == "nvidia" ]]; then
    pacstrap /mnt nvidia
fi

# ====================== fstab ======================
info "生成 fstab"
genfstab -U /mnt > /mnt/etc/fstab

# ====================== 系统配置 ======================
info "进入 chroot 配置系统"
arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "$HOSTNAME" > /etc/hostname

echo root:$ROOT_PWD | chpasswd
useradd -m -G wheel -s /bin/bash $USER_NAME
echo $USER_NAME:$USER_PWD | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

sed -i 's/#Color/Color/' /etc/pacman.conf
sed -i 's/#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
sed -i "s/ParallelDownloads = 5/ParallelDownloads = $PACMAN_THREADS/" /etc/pacman.conf

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=arch --recheck
grub-mkconfig -o /boot/grub/grub.cfg

systemctl enable NetworkManager sshd
btrfs subvolume snapshot -r / /.snapshots/init-\$(date +%Y%m%d)
EOF

# ====================== 一键回滚脚本 ======================
info "创建系统快照恢复工具"
cat > /mnt/rollback.sh <<'EOF'
#!/bin/bash
set -e
root_part=$(findmnt / -o SOURCE -n)
disk=$(lsblk -no pkname "$root_part" | head -n1)
disk="/dev/$disk"

if [[ $disk == *nvme* ]]; then
    rootfs="${disk}p2"
else
    rootfs="${disk}2"
fi

mount -t btrfs -o subvol=/ $rootfs /mnt
btrfs subvolume del /mnt/@
btrfs subvolume snap /mnt/.snapshots/init-* /mnt/@
btrfs subvolume set-default $(btrfs sub list /mnt | grep -w @ | awk '{print $2}') /mnt
umount -R /mnt

echo "恢复完成，重启生效"
reboot
EOF
chmod +x /mnt/rollback.sh

# ====================== 完成 ======================
info "安装完成！重启后即可使用"
info "恢复系统命令：sudo /rollback.sh"
umount -R /mnt
sleep 2
reboot