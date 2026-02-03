# 新 VPS 一键设置脚本

Make 新手的 VPS 安全 Again

## 用法

```bash
# 交互式执行
sudo ./vps-quick-setting.sh

# 快速自动配置模式
sudo ./vps-quick-setting.sh --auto
```

## 自动配置内容

- ✅ **主机名**: 可选设置（会询问一次，直接按回车跳过）
- ✅ **时区**: Asia/Shanghai (UTC+8)
- ✅ **时间同步**: chrony 自动同步
- ✅ **SSH安全**:
  - 密钥认证: 启用
  - 密码认证: 禁用（防暴力破解）
  - Root登录: 强制密钥登录
  - Fail2ban: 5次失败封禁1小时
- ✅ **防火墙**: 入站拒绝 | 转发拒绝 | 出站允许；放行22/80/443端口（已配置则跳过）
- ✅ **内存优化**: Swap（自动跳过）
- ✅ **生成基线文档**: ~/baseline/YYMMDDHHMM-system-baseline.txt

## 从GitHub下载并运行脚本

**方式一：下载后执行**（推荐新手，可以先查看文件内容）
```bash
curl -fsSL -o vps-quick-setting.sh https://github.com/chzzfly/vps-quick-setting/raw/main/vps-quick-setting.sh
chmod +x vps-quick-setting.sh
sudo bash vps-quick-setting.sh
```

**方式二：一行命令下载并执行**
```bash
curl -fsSL -o vps-quick-setting.sh https://github.com/chzzfly/vps-quick-setting/raw/main/vps-quick-setting.sh && chmod +x vps-quick-setting.sh && sudo bash vps-quick-setting.sh
```

**方式三：直接执行，不保存文件**
```bash
curl -fsSL https://github.com/chzzfly/vps-quick-setting/raw/main/vps-quick-setting.sh | sudo bash
```

## 手动设置密钥登录

### 1. 设置SSH密钥（在本地电脑）

```bash
ssh-keygen -t ed25519
cat ~/.ssh/id_ed25519.pub    # 复制公钥
```

### 2. 登录VPS并添加公钥

```bash
ssh root@你的VPS_IP           # 首次密码登录
mkdir -p ~/.ssh
echo "粘贴公钥" >> ~/.ssh/authorized_keys
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
exit
```

### 3. 测试密钥登录（应该不需要密码）

```bash
ssh root@你的VPS_IP
```

## 验证配置

```bash
timedatectl status                 # 查看时区和时间同步
chronyc tracking                   # 查看NTP同步详情
hostname                           # 查看主机名
sudo ufw status verbose            # 查看防火墙
sudo systemctl status fail2ban    # 查看fail2ban
free -h                            # 查看内存
ls ~/baseline/                     # 列出所有基线文件
cat ~/baseline/最新文件名.txt       # 查看指定基线文件
```

## 开放其他端口（示例）

```bash
sudo ufw allow 8080/tcp            # 备用HTTP
sudo ufw allow 3306/tcp           # MySQL
sudo ufw allow 5432/tcp           # PostgreSQL
```

## 故障排除

### 被锁定SSH外？

- 用VPS提供商控制台登录
- `sudo vim /etc/ssh/sshd_config`
- 改为: `PasswordAuthentication yes`
- `sudo systemctl restart sshd`

### 想禁止root登录？

- `sudo vim /etc/ssh/sshd_config`
- 改为: `PermitRootLogin no`
- 创建普通用户: `adduser user`
- 配置sudo: `usermod -aG sudo user`
- 重启SSH: `sudo systemctl restart sshd`