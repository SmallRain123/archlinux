## Arch Linux 全自动安装脚本 (UEFI + Btrfs)
一键全自动安装 Arch Linux，自动识别空闲硬盘、配置 Btrfs 优化子卷、集成国内镜像源，无需手动干预即可完成系统部署。
## 特性
- 自动识别空闲物理硬盘，兼容 SATA/NVMe 设备
- UEFI 标准分区 + Btrfs 文件系统（含 @/@home/@cache/@log/@swap/@snapshots 子卷）
- 启用 zstd 压缩提升性能，禁用 swap/cache/log 目录的 CoW 特性
- 自动配置清华 ArchLinuxCN 源与 Pacman 多线程下载
- 预装 NetworkManager、SSH、GRUB 引导等必备组件
- 安装完成自动生成初始只读快照，支持系统还原
## 前置要求
- 主板支持 UEFI 启动模式（需关闭安全启动）
- 目标硬盘为全新无分区、未挂载状态
- 安装环境需联网
- 提前备份目标硬盘所有数据（脚本会清空磁盘）
## 快速开始
**1.** 从 Arch Linux 官方镜像制作 U 盘启动盘并以 UEFI 模式启动
**2.** 在 Live 环境中下载并运行脚本：
```bash
# 一键快速安装
bash < (curl -L https://raw.githubusercontent.com/smallrain123/archlinux/main/setup.sh)
```
  
**3.** 确认磁盘识别信息，等待 10 秒倒计时后自动完成安装
**4.** 系统重启后拔掉 U 盘即可进入新系统

> **注意：** 在开始执行脚本前，需要拔掉u盘，否则会自动安装在u盘上
## 配置说明
脚本顶部 “可选项” 区域支持自定义配置：
- 时区、主机名
- root 与普通用户密码
- EFI 分区大小
- Pacman 下载线程数
  
## 默认登录信息

| 用户类型 | 用户名 | 密码 |
|:----------:|:--------:|:------:|
| 管理员 | root | password |
| 普通用户 | arch | password |

> 普通用户已加入 wheel 组，拥有完整 sudo 权限。
## 注意事项
⚠️ 脚本会清空目标硬盘所有数据，请务必提前备份

⚠️ 仅支持 UEFI 启动，不兼容传统 BIOS 模式
  
⚠️ 建议安装完成后第一时间修改默认密码