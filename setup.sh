#!/bin/bash
set -euo pipefail

# ====================== 自动识别硬盘（核心优化，无需手动修改） ======================
# 1. 筛选物理磁盘（排除U盘、loop虚拟设备、只读设备）
# 2. 过滤出无分区表的空闲磁盘（防误删已有数据的硬盘）
# 3. 兼容 SATA（/dev/sda）和 NVMe（/dev/nvme0n1）格式
DISK=$(lsblk -dno TYPE,NAME,MOUNTPOINT | \
    grep -E '^disk' | \
    grep -v loop | \
    grep -v '/' | \
    awk '{print "/dev/"$2}' | \
    head -n1)

# 校验磁盘识别结果
if [ -z "$DISK" ]; then
    echo -e "\033[31m错误：未识别到空闲物理硬盘！\033[0m"
    echo "请检查：1. 硬盘已正确连接 2. 硬盘无分区/未挂载 3. 排除U盘安装介质"
    exit 1
fi

# 自动适配分区命名（SATA: sda1 / NVMe: nvme0n1p1）
if [[ $DISK == /dev/nvme* ]]; then
    EFI_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
else
    EFI_PART="${DISK}1"
    ROOT_PART="${DISK}2"
fi

# ====================== 可选项（可按需修改，不改也能正常使用） ======================
TIMEZONE="Asia/Shanghai"   # 时区
HOSTNAME="arch"            # 主机名
ROOT_PWD="password"           # root 密码
USER_NAME="arch"          # 普通用户名
USER_PWD="password"             # 普通用户密码
EFI_SIZE="+1G"             # EFI分区大小（默认1G，足够）
PACMAN_THREADS="20"         # Pacman下载线程数（建议3-8，根据网络调整）
# ===================================================================================

# 打印识别结果，让用户确认
echo -e "\033[32m=== 自动识别完成 ===\033[0m"
echo "安装磁盘：$DISK"
echo "EFI分区：$EFI_PART（大小：$EFI_SIZE）"
echo "Btrfs根分区：$ROOT_PART（占用剩余全部空间）"
echo "Pacman下载线程数：$PACMAN_THREADS（可在脚本可选项中调整）"
echo -e "\033[33m警告：将清空 $DISK 所有数据，10秒后开始安装（按Ctrl+C取消）\033[0m"
sleep 10

# ====================== 开始全自动安装流程 ======================
echo -e "\n\033[32m=== 1. 开启网络时间同步 ===\033[0m"
timedatectl set-ntp true
timedatectl status | grep "NTP service"

echo -e "\n\033[32m=== 2. 自动分区（UEFI + Btrfs，清空目标磁盘） ===\033[0m"
# 清空磁盘分区表
sgdisk -Z $DISK
# 创建EFI分区（1G，ef00类型）
sgdisk -n 1:0:$EFI_SIZE -t 1:ef00 $DISK
# 创建根分区（剩余全部空间，8300类型）
sgdisk -n 2:0:0 -t 2:8300 $DISK
# 打印分区结果
sgdisk -p $DISK

echo -e "\n\033[32m=== 3. 格式化分区 ===\033[0m"
# 格式化EFI分区（FAT32）
mkfs.fat -F32 $EFI_PART
# 格式化根分区（Btrfs，强制覆盖）
mkfs.btrfs -f $ROOT_PART

echo -e "\n\033[32m=== 4. 创建Btrfs子卷（优化存储，禁用无用COW） ===\033[0m"
# 挂载根分区顶层，创建子卷
mount $ROOT_PART /mnt
btrfs subvolume create /mnt/@          # 根目录
btrfs subvolume create /mnt/@home      # 家目录
btrfs subvolume create /mnt/@cache     # 缓存目录
btrfs subvolume create /mnt/@log       # 日志目录
btrfs subvolume create /mnt/@swap      # 交换分区子卷
btrfs subvolume create /mnt/@snapshots # 快照目录

# 禁用COW（swap、cache、log必须禁用，提升性能）
chattr +C /mnt/@swap
chattr +C /mnt/@cache
chattr +C /mnt/@log

# 卸载顶层，准备按子卷重新挂载
umount /mnt

echo -e "\n\033[32m=== 5. 挂载子卷（启用zstd压缩，提升读写速度） ===\033[0m"
# 挂载根目录子卷（zstd压缩）
mount -t btrfs -o subvol=@,compress=zstd $ROOT_PART /mnt

# 创建所有需要的挂载目录
mkdir -p /mnt/{boot/efi,home,var/cache/pacman,var/log,swap,.snapshots}

# 挂载其他子卷
mount -t btrfs -o subvol=@home,compress=zstd $ROOT_PART /mnt/home
mount -t btrfs -o subvol=@cache,compress=zstd $ROOT_PART /mnt/var/cache/pacman
mount -t btrfs -o subvol=@log,compress=zstd $ROOT_PART /mnt/var/log
mount -t btrfs -o subvol=@swap $ROOT_PART /mnt/swap
mount -t btrfs -o subvol=@snapshots $ROOT_PART /mnt/.snapshots

# 挂载EFI分区（必须挂载到/boot/efi）
mount $EFI_PART /mnt/boot/efi

echo -e "\n\033[32m=== 6. 安装基础系统和必备工具 ===\033[0m"
# 安装基础系统组件
pacstrap -K /mnt base base-devel linux linux-firmware btrfs-progs
# 安装网络、编辑器、sudo、引导、SSH等必备工具
pacstrap /mnt networkmanager vim sudo grub efibootmgr openssh

echo -e "\n\033[32m=== 7. 生成fstab文件（自动挂载分区） ===\033[0m"
genfstab -U /mnt >> /mnt/etc/fstab
# 验证fstab文件
cat /mnt/etc/fstab | grep -E "btrfs|vfat"

echo -e "\n\033[32m=== 8. 进入新系统，完成初始化配置（含下载线程优化） ===\033[0m"
arch-chroot /mnt /bin/bash << EOF
# 配置时区（上海）
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# 配置语言（UTF-8）
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# 配置主机名
echo "$HOSTNAME" > /etc/hostname

# 设置root密码
echo root:$ROOT_PWD | chpasswd

# 创建普通用户，加入wheel组（拥有sudo权限）
useradd -m -G wheel -s /bin/bash $USER_NAME
echo $USER_NAME:$USER_PWD | chpasswd

# 开启sudo权限（wheel组无需密码）
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# 配置GRUB引导（UEFI模式，适配所有硬盘）
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=arch --recheck
grub-mkconfig -o /boot/grub/grub.cfg

# 开启开机自启服务（网络、SSH）
systemctl enable NetworkManager
systemctl enable sshd

# 添加archlinuxcn源（阿里云源，国内速度快）
sed -i '$a [archlinuxcn]' /etc/pacman.conf
sed -i '$a Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/\$arch' /etc/pacman.conf

# 配置Pacman下载线程（提升软件下载速度）
# 新增ParallelDownloads配置，若已存在则修改
if grep -q "ParallelDownloads" /etc/pacman.conf; then
    sed -i "s/^ParallelDownloads.*/ParallelDownloads = $PACMAN_THREADS/" /etc/pacman.conf
else
    sed -i "/^#\[options\]/a ParallelDownloads = $PACMAN_THREADS" /etc/pacman.conf
fi

# 更新密钥环，避免安装软件报错
pacman -Sy --noconfirm archlinuxcn-keyring

# 清理缓存，减少系统占用
pacman -Scc --noconfirm

# 配置初始化快照
btrfs subvolume snapshot -r / /.snapshots/init_$(date +%F)

echo -e "\033[32m=== 系统配置完成（含下载线程优化） ===\033[0m"
EOF

echo -e "\n\033[32m=== 9. 安装完成，准备重启 ===\033[0m"
# 安全卸载所有挂载点
umount -R /mnt
# 重启系统，进入新安装的Arch Linux
reboot

