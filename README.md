# 新 VPS 一键设置脚本

Make 新手的 VPS 安全 Again

## 从GitHub下载并运行脚本

**方式一：下载后执行**（推荐新手，可以先查看文件内容）
```bash
curl -fsSL -o vps-quick-setting.sh https://github.com/chzzfly/vps-quick-setting/raw/main/vps-quick-setting.sh
chmod +x vps-quick-setting.sh
sudo ./vps-quick-setting.sh
```

**方式二：一行命令下载并执行**（交互式）
```bash
curl -fsSL -o vps-quick-setting.sh https://github.com/chzzfly/vps-quick-setting/raw/main/vps-quick-setting.sh && chmod +x vps-quick-setting.sh && sudo ./vps-quick-setting.sh
```

**方式三：一行命令下载并执行**（自动配置）
```bash
curl -fsSL -o vps-quick-setting.sh https://github.com/chzzfly/vps-quick-setting/raw/main/vps-quick-setting.sh && chmod +x vps-quick-setting.sh && sudo ./vps-quick-setting.sh --auto
```

## 用法

```bash
# 交互式执行
sudo ./vps-quick-setting.sh

# 自动配置模式
sudo ./vps-quick-setting.sh --auto
```

## 自动配置内容

- ✅ **主机名**: 可选设置（会询问一次，直接按回车跳过）
- ✅ **时区**: Asia/Shanghai (UTC+8)
- ✅ **时间同步**: chrony 自动同步
- ✅ **SSH安全**:
  - 端口修改: 交互模式可选修改，自动配置则不修改
  - 密钥认证: 启用
  - 密码认证: 禁用（防暴力破解）
  - Root登录: 强制密钥登录
  - Fail2ban: 10分钟内失败5次，封禁IP12小时
- ✅ **防火墙**: 入站拒绝 | 转发拒绝 | 出站允许；放行SSH（自动检测端口）/80/443端口
- ✅ **内存优化**: Swap（自动跳过）
- ✅ **生成基线文档**: ~/baseline/YYMMDDHHMM-system-baseline.txt


## 手动设置密钥登录

> 运行脚本前必须先配置SSH密钥登录，否则禁用密码后将无法登录！

### 1. 生成SSH密钥（在本地电脑执行）

```bash
ssh-keygen -t ed25519
```
按回车使用默认路径，密码可留空。

### 2. 上传公钥到VPS（在本地电脑执行，需输入VPS密码）

```bash
ssh-copy-id root@你的VPS_IP
```
这条命令会自动把你的公钥复制到VPS上。

### 3. 测试密钥登录（不应再需要密码）

```bash
ssh root@你的VPS_IP
```
如果直接登录成功（没有要求输入密码），说明密钥配置正确，可以运行脚本了。

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

## 故障排除

### 被锁定SSH外？

- 用VPS提供商控制台登录
- `sudo vim /etc/ssh/sshd_config`
- 改为: `PasswordAuthentication yes`
- `sudo systemctl restart sshd`
