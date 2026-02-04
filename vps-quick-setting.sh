#!/bin/bash

# 新VPS一键设置脚本
# 用法: sudo ./vps-quick-setting.sh        # 交互式
#       sudo ./vps-quick-setting.sh --auto # 自动配置
# 详细说明见 README.md

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Mode selection
AUTO_MODE=false

# Parse command line arguments
if [ "$1" = "--auto" ]; then
    AUTO_MODE=true
fi

# Detect current SSH port from sshd config
get_ssh_port() {
    local port
    # 优先从运行的 sshd 获取配置
    port=$(sshd -T 2>/dev/null | grep "^port " | awk '{print $2}')
    # 如果获取失败，尝试从配置文件读取
    if [ -z "$port" ]; then
        port=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    fi
    # 默认值 22
    echo "${port:-22}"
}

# Global SSH port (will be set once and reused)
SSH_PORT=$(get_ssh_port)

# Print banner
print_banner() {
    echo ""
    echo -e "${GREEN}           新VPS一键设置脚本           ${NC}"
    echo -e "${YELLOW}        Make 新手的VPS 安全 Again       ${NC}"
    echo ""
}

# Check for SSH key
check_ssh_key() {
    # 获取实际用户的主目录（支持 sudo 场景）
    local user_home
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        user_home=$(eval echo ~$SUDO_USER)
    else
        user_home="$HOME"
    fi

    if [ ! -f "$user_home/.ssh/authorized_keys" ] && [ ! -f /root/.ssh/authorized_keys ]; then
        echo -e "${RED}✗ 未发现SSH authorized_keys！${NC}"
        echo -e "${YELLOW}请先配置SSH密钥:${NC}"
        echo "  1. 本地生成密钥: ssh-keygen -t ed25519"
        echo "  2. 上传到VPS:    ssh-copy-id root@服务器IP"
        echo "  3. 测试登录:     ssh root@服务器IP"
        return 1
    fi
    return 0
}

# Check if root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误: 此脚本必须以root权限或使用sudo运行${NC}"
        exit 1
    fi
}

# Detect OS
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    else
        echo -e "${RED}错误: 无法检测操作系统${NC}"
        exit 1
    fi

    if [[ "$OS" != "debian" && "$OS" != "ubuntu" ]]; then
        echo -e "${RED}错误: 此脚本仅支持 Debian/Ubuntu 系统${NC}"
        echo -e "${RED}检测到的系统: $OS${NC}"
        exit 1
    fi
}

# Update package lists
update_system() {
    echo -e "${CYAN}→ apt update${NC}"
    apt update -qq
    echo -e "${GREEN}✓ 软件包列表已更新${NC}"
}

# Set timezone
configure_timezone() {
    local current_tz=$(timedatectl | grep "Time zone" | awk '{print $3}')

    if [ "$current_tz" = "Asia/Shanghai" ]; then
        echo -e "${GREEN}✓ 时区已是 Asia/Shanghai，跳过${NC}"
        return
    fi

    echo -e "${CYAN}→ timedatectl set-timezone Asia/Shanghai${NC}"
    timedatectl set-timezone Asia/Shanghai
    echo -e "${GREEN}✓ 时区已设置为 Asia/Shanghai${NC}"
}

# Sync time with NTP
configure_time_sync() {
    echo -e "${CYAN}→ 安装并启用 chrony${NC}"

    # Check if chrony is installed
    if command -v chronyd &> /dev/null; then
        echo "  chrony 已安装"
        systemctl enable chrony >/dev/null 2>&1

        # Check if running
        if systemctl is-active --quiet chrony; then
            echo -e "${GREEN}✓ chrony 已在运行${NC}"
        else
            systemctl start chrony >/dev/null 2>&1
            echo -e "${GREEN}✓ chrony 已启动${NC}"
        fi
    else
        # Install chrony
        echo "  安装 chrony..."
        apt install -y chrony >/dev/null 2>&1
        systemctl enable chrony >/dev/null 2>&1
        systemctl start chrony >/dev/null 2>&1
        echo -e "${GREEN}✓ chrony 已安装并启动${NC}"
    fi

    # Wait for sync
    sleep 2

    # Show status
    if command -v chronyc &> /dev/null; then
        echo "  当前时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "  NTP状态: $(chronyc tracking | grep 'Reference ID' || echo '正在同步...')"
    else
        echo -e "${YELLOW}⚠ 时间同步服务状态未知${NC}"
    fi
}

# Set hostname
configure_hostname() {
    local hostname_input="$1"

    if [ -z "$hostname_input" ]; then
        echo -e "${YELLOW}⊘ 未指定主机名，跳过${NC}"
        return
    fi

    local current_hostname=$(hostname)

    if [ "$current_hostname" = "$hostname_input" ]; then
        echo -e "${GREEN}✓ 主机名已是 $hostname_input，跳过${NC}"
        return
    fi

    echo -e "${CYAN}→ hostnamectl set-hostname $hostname_input${NC}"

    # Use hostnamectl (updates /etc/hostname automatically)
    hostnamectl set-hostname "$hostname_input"

    # Update /etc/hosts
    # Remove old 127.0.1.1 lines
    sed -i '/^127\.0\.1\.1/d' /etc/hosts
    # Add new hostname line
    echo "127.0.1.1   $hostname_input" >> /etc/hosts

    # Show confirmation
    echo -e "${GREEN}✓ 主机名已设置为 $hostname_input${NC}"
    echo "  /etc/hostname: $(cat /etc/hostname)"
    echo "  /etc/hosts: $(grep 127.0.1.1 /etc/hosts)"
    echo ""
    echo -e "${YELLOW}提示: 执行 'exec bash' 或重新登录以显示新主机名${NC}"
}

# Install and configure fail2ban
install_fail2ban() {
    echo -e "${CYAN}→ apt install -y fail2ban${NC}"
    apt install -y fail2ban >/dev/null 2>&1

    # Create basic configuration (使用检测到的 SSH 端口)
    # bantime=43200 (12小时), findtime=600 (10分钟内), maxretry=5 (失败5次)
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 43200
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
EOF

    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban >/dev/null 2>&1
    echo -e "${GREEN}✓ fail2ban 已安装并配置 (监控端口: ${SSH_PORT})${NC}"
}

# SSH Security Hardening
configure_ssh() {
    echo -e "${CYAN}→ 配置 SSH (禁用密码登录 + 启用 fail2ban)${NC}"

    # Check for SSH key
    if ! check_ssh_key; then
        return 1
    fi

    # Check current SSH configuration
    local ssh_passwd=$(sshd -T 2>/dev/null | grep -i passwordauthentication | awk '{print $2}')
    local ssh_pubkey=$(sshd -T 2>/dev/null | grep -i pubkeyauthentication | awk '{print $2}')

    # Check if already configured correctly
    if [ "$ssh_passwd" = "no" ] && [ "$ssh_pubkey" = "yes" ]; then
        echo -e "${GREEN}✓ SSH已正确配置，跳过${NC}"
        echo "  ✓ 公钥认证: 已启用"
        echo "  ✓ 密码认证: 已禁用"

        # Still ensure fail2ban is installed
        if ! systemctl is-active --quiet fail2ban 2>/dev/null; then
            install_fail2ban
        else
            echo "  ✓ Fail2ban: 已运行"
        fi
        return 0
    fi

    # Backup config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)

    # Configure SSH - 适合新手的策略
    # 1. 启用公钥认证
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

    # 2. 禁用密码认证（关键安全措施）
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

    # 3. 不修改PermitRootLogin，保持默认（允许root密钥登录）
    #    这样新手仍然可以用root + 密钥登录

    # Validate config before restart
    if ! sshd -t; then
        echo -e "${RED}✗ SSH配置验证失败，正在回滚...${NC}"
        cp /etc/ssh/sshd_config.backup.* /etc/ssh/sshd_config 2>/dev/null || true
        return 1
    fi

    # Restart SSH
    systemctl restart sshd
    echo -e "${GREEN}✓ SSH已配置${NC}"
    echo "  ✓ 公钥认证: 已启用"
    echo "  ✓ 密码认证: 已禁用（防暴力破解）"
    echo "  ✓ Root登录: 允许密钥登录（新手友好）"
    echo ""
    echo -e "${YELLOW}提示: 如果想禁止root登录，手动编辑 /etc/ssh/sshd_config${NC}"
    echo "      设置 'PermitRootLogin no'，然后重启SSH"

    # Install fail2ban
    install_fail2ban
    return 0
}

# Check if package is actually installed
is_package_installed() {
    dpkg -l "$1" 2>/dev/null | grep -q "^ii"
}

# Wait for apt lock to be released
wait_for_apt() {
    local timeout=300
    local waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        if [ $waited -ge $timeout ]; then
            echo -e "${RED}✗ 等待apt锁超时${NC}"
            return 1
        fi
        echo "等待其他apt进程完成..."
        sleep 5
        waited=$((waited + 5))
    done
}

# Configure Firewall
configure_firewall() {
    # Check if running in auto mode
    if [ "$AUTO_MODE" = true ]; then
        # Auto mode: silent configuration
        if is_package_installed ufw && command -v ufw &> /dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
            echo -e "${GREEN}✓ 防火墙已配置，跳过${NC}"
            return 0
        fi
    else
        # Interactive mode: show current status and ask
        echo -e "${CYAN}→ 配置 UFW 防火墙${NC}"
        echo ""

        # 显示当前状态
        if command -v ufw &> /dev/null; then
            echo -e "${YELLOW}当前状态:${NC}"
            if ufw status 2>/dev/null | grep -q "Status: active"; then
                echo "  UFW: ✓ 已启用"
                echo ""
                ufw status 2>/dev/null | head -10
                echo ""

                # 询问是否重新配置
                if ! ask_yes_no "是否重新配置防火墙？" "N"; then
                    echo -e "${YELLOW}⊘ 保持现有配置${NC}"
                    return 0
                fi
            else
                echo "  UFW: ✗ 未启用"
                echo ""
            fi
        else
            echo -e "${YELLOW}当前状态:${NC}"
            echo "  UFW: ✗ 未安装"
            echo ""
        fi

        # 询问是否配置防火墙
        if ! ask_yes_no "是否配置防火墙？" "Y"; then
            echo -e "${YELLOW}⊘ 跳过防火墙配置${NC}"
            return 0
        fi
    fi

    # Wait for apt lock
    wait_for_apt || return 1

    # Update package lists first
    echo -e "${CYAN}→ apt update${NC}"
    if ! apt update -qq; then
        echo -e "${RED}✗ apt update 失败${NC}"
        return 1
    fi

    # Install UFW
    if [ "$AUTO_MODE" != true ]; then
        echo -e "${CYAN}→ 安装 UFW 防火墙${NC}"
    fi

    # 清理可能存在的残留配置
    if dpkg -l ufw 2>/dev/null | grep -q "^rc"; then
        echo "清理残留的UFW配置..."
        dpkg --purge ufw >/dev/null 2>&1 || true
    fi

    # 安装ufw并捕获输出
    local install_output install_exit_code
    install_output=$(apt install -y ufw 2>&1)
    install_exit_code=$?

    if [ $install_exit_code -ne 0 ]; then
        echo -e "${RED}✗ UFW 安装失败 (exit code: $install_exit_code)${NC}"
        echo "安装输出："
        echo "$install_output"
        return 1
    fi

    # 验证ufw是否真的安装了
    if ! is_package_installed ufw; then
        echo -e "${RED}✗ UFW 包未正确安装${NC}"
        echo "尝试手动排查问题..."
        echo "当前ufw包状态："
        dpkg -l ufw 2>&1 || true
        return 1
    fi

    # 验证ufw命令可用
    if ! command -v ufw &> /dev/null; then
        echo -e "${RED}✗ UFW 命令不可用，尝试重新安装${NC}"
        apt install --reinstall -y ufw 2>&1 || {
            echo -e "${RED}✗ UFW 重新安装失败${NC}"
            return 1
        }
    fi

    # Configure default policies
    echo -e "${CYAN}→ 配置防火墙策略${NC}"
    if ! ufw default deny incoming; then
        echo -e "${RED}✗ 配置入站策略失败${NC}"
        return 1
    fi
    ufw default deny routed >/dev/null 2>&1 || true
    if ! ufw default allow outgoing; then
        echo -e "${RED}✗ 配置出站策略失败${NC}"
        return 1
    fi

    # Allow SSH, HTTP, HTTPS
    echo -e "${CYAN}→ 放行必要端口${NC}"
    if ! ufw allow ${SSH_PORT}/tcp comment 'SSH'; then
        echo -e "${RED}✗ 放行SSH端口失败${NC}"
        return 1
    fi
    if ! ufw allow 80/tcp comment 'HTTP'; then
        echo -e "${RED}✗ 放行HTTP端口失败${NC}"
        return 1
    fi
    if ! ufw allow 443/tcp comment 'HTTPS'; then
        echo -e "${RED}✗ 放行HTTPS端口失败${NC}"
        return 1
    fi

    # Enable
    echo -e "${CYAN}→ 启用防火墙${NC}"
    if ! echo "y" | ufw enable; then
        echo -e "${RED}✗ 启用防火墙失败${NC}"
        return 1
    fi

    # 验证配置结果
    echo -e "${CYAN}→ 验证防火墙配置${NC}"
    if ! ufw status 2>/dev/null | grep -q "Status: active"; then
        echo -e "${RED}✗ 防火墙未能正常启用${NC}"
        return 1
    fi

    echo -e "${GREEN}✓ 防火墙已配置${NC}"
    echo "  默认策略: 入站拒绝 | 转发拒绝 | 出站允许"
    echo "  已放行: SSH (${SSH_PORT}), HTTP (80), HTTPS (443)"
    echo ""
    ufw status verbose | head -10
}

# Create Swap
create_swap() {
    local size=$1

    if [ -f /swapfile ]; then
        echo -e "${YELLOW}⚠ Swap文件已存在，跳过${NC}"
        return
    fi

    # Parse size and calculate count (in MB)
    local count_mb
    case "$size" in
        *G|*g)
            local num=$(echo "$size" | tr -d 'Gg')
            count_mb=$((num * 1024))
            ;;
        *M|m)
            count_mb=$(echo "$size" | tr -d 'Mm')
            ;;
        *)
            count_mb=1024  # Default 1GB
            ;;
    esac

    # Create swap file
    dd if=/dev/zero of=/swapfile bs=1M count=$count_mb iflag=fullblock >/dev/null 2>&1
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1
    swapon /swapfile

    # Add to fstab
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    echo -e "${GREEN}✓ Swap已配置完成 (${size})${NC}"
}

# Memory Optimization - Interactive Mode
ask_yes_no() {
    local prompt="$1"
    local default="$2"
    local response

    if [ "$default" = "Y" ]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi

    while true; do
        read -p "$(echo -e "${YELLOW}?${NC}" "$prompt")" response
        response=${response:-$default}

        case "$response" in
            [Yy]|[Yy][Ee][Ss])
                return 0
                ;;
            [Nn]|[Nn][Oo])
                return 1
                ;;
            *)
                echo -e "${RED}请输入 yes 或 no${NC}"
                ;;
        esac
    done
}

# Format MB to human readable size
fmt_mb() {
    local v=$1
    if [ $v -ge 1024 ]; then
        echo "$(awk "BEGIN {printf \"%.1f\", $v/1024}")GB"
    else
        echo "${v}MB"
    fi
}

# Memory Optimization - Interactive Mode
configure_memory_interactive() {
    echo ""
    echo -e "${CYAN}═══ 内存优化配置 ═══${NC}"

    # Show current memory status
    local total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local total_mem_mb=$((total_mem_kb / 1024))
    local current_swap=$(free -h | grep Swap | awk '{print $2}')

    echo "当前内存状态:"
    echo "  物理内存: ${total_mem_mb}MB"
    echo "  当前Swap: ${current_swap}"
    echo ""

    # Check if swap already exists
    if [ "$current_swap" != "0B" ] && swapon --show | grep -q '/swapfile\|zram'; then
        echo -e "${YELLOW}⚠ 检测到已配置虚拟内存${NC}"
        if ! ask_yes_no "是否要重新配置？" "N"; then
            echo -e "${YELLOW}⊘ 跳过内存优化${NC}"
            return
        fi
    fi

    echo "请选择虚拟内存方案:"
    echo -e "  ${CYAN}1${NC}) 跳过 - 不配置虚拟内存"
    echo -e "  ${CYAN}2${NC}) Swap - 把磁盘当额外内存（磁盘性能远低于内存，仅作应急）"
    echo ""
    read -p "$(echo -e "${YELLOW}?${NC}" "请输入选项 [1-2]: ")" mem_choice

    case "$mem_choice" in
        1)
            echo -e "${YELLOW}⊘ 跳过内存优化${NC}"
            return
            ;;
        2)
            # Swap
            echo ""
            echo "Swap文件大小建议:"
            if [ $total_mem_mb -lt 512 ]; then
                echo "  • 低内存 (<512MB): 建议 512MB-1GB"
            elif [ $total_mem_mb -lt 1024 ]; then
                echo "  • 中等内存 (512MB-1GB): 建议 1-2GB"
            else
                echo "  • 充足内存 (>1GB): 建议 1-2GB 或不需要"
            fi
            echo ""
            read -p "$(echo -e "${YELLOW}?${NC}" "输入Swap大小 (例如: 1G, 2G, 默认1G): ")" swap_size
            swap_size=${swap_size:-1G}

            create_swap "$swap_size"
            ;;
        *)
            echo -e "${RED}无效选项，跳过内存优化${NC}"
            return
            ;;
    esac
}

# Show System Status
show_system_status() {
    echo -e "${CYAN}═══ 系统状态 ═══${NC}"
    echo ""

    # 系统信息
    echo -e "${YELLOW}系统信息:${NC}"
    echo "  OS:       $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
    echo "  内核:     $(uname -r)"
    echo "  运行时间: $(uptime -p)"
    echo ""

    # 主机配置
    echo -e "${YELLOW}主机配置:${NC}"
    echo "  主机名:   $(hostname)"
    echo "  时区:     $(timedatectl | grep "Time zone" | awk '{print $3}')"

    # Check NTP sync
    if command -v chronyc &> /dev/null; then
        local ntp_status=$(chronyc tracking | grep 'Reference ID' | awk '{print $4}')
        if [ "$ntp_status" != "00000000" ] && [ -n "$ntp_status" ]; then
            echo "  NTP同步:  ✓ 已同步"
        else
            echo "  NTP同步:  ✗ 未同步"
        fi
    else
        echo "  NTP同步:  ✗ 未安装"
    fi
    echo ""

    # 内存使用
    echo -e "${YELLOW}内存使用:${NC}"
    local mem_info=$(free -h | grep Mem)
    echo "  物理内存: $(echo $mem_info | awk '{print $3 "/" $2}')"

    local swap_info=$(free -h | grep Swap)
    local swap_used=$(echo $swap_info | awk '{print $3}')
    if [ "$swap_used" != "0B" ]; then
        echo "  Swap:     $(echo $swap_info | awk '{print $3 "/" $2}')"
    else
        echo "  Swap:     未配置"
    fi
    echo ""

    # 硬盘使用
    echo -e "${YELLOW}硬盘使用:${NC}"
    df -h | grep -E '^/dev/' | awk '{printf "  %-10s %4s / %4s  %s\n", $6, $3, $2, $5}'
    echo ""

    # SSH配置（合并 Fail2ban）
    echo -e "${YELLOW}SSH配置:${NC}"
    # 检测实际用户的密钥（支持 sudo 场景）
    local ssh_user_home
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        ssh_user_home=$(eval echo ~$SUDO_USER)
    else
        ssh_user_home="$HOME"
    fi
    if [ -f "$ssh_user_home/.ssh/authorized_keys" ] || [ -f /root/.ssh/authorized_keys ]; then
        echo "  密钥认证: ✓ 已配置"
    else
        echo "  密钥认证: ✗ 未配置"
    fi

    local ssh_passwd=$(sshd -T 2>/dev/null | grep -i passwordauthentication | awk '{print $2}')
    if [ "$ssh_passwd" = "no" ]; then
        echo "  密码登录: ✗ 已禁用"
    else
        echo "  密码登录: ✓ 已启用"
    fi

    local ssh_root=$(sshd -T 2>/dev/null | grep -i permitrootlogin | awk '{print $2}')
    # 转换显示：without-password/prohibit-password → 强制使用密钥
    case "$ssh_root" in
        without-password|prohibit-password)
            echo "  Root登录: 强制使用密钥"
            ;;
        yes)
            echo "  Root登录: 允许"
            ;;
        no)
            echo "  Root登录: 禁止"
            ;;
        *)
            echo "  Root登录: $ssh_root"
            ;;
    esac

    # Fail2ban 状态
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        echo "  Fail2ban: ✓ 运行中"
        local banned=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $4}')
        if [ -n "$banned" ]; then
            echo "    当前封禁: $banned 个IP"
        fi
    else
        echo "  Fail2ban: ✗ 未运行"
    fi
    echo ""

    # 防火墙配置
    echo -e "${YELLOW}防火墙配置:${NC}"
    if is_package_installed ufw && command -v ufw &> /dev/null; then
        # 状态
        local ufw_status=$(ufw status 2>/dev/null | head -1)
        echo "  UFW状态: $ufw_status"

        # 策略
        local default_line=$(ufw status verbose 2>/dev/null | grep "Default:")
        local incoming=$(echo "$default_line" | sed -n 's/.*\(deny\|allow\).*(incoming).*/\1/p')
        local outgoing=$(echo "$default_line" | sed -n 's/.*\(deny\|allow\).*(outgoing).*/\1/p')
        local routed=$(echo "$default_line" | sed -n 's/.*\(deny\|allow\|disabled\).*(routed).*/\1/p')
        # 统一格式：disabled 映射为 deny
        [ "$routed" = "disabled" ] && routed="deny"
        echo "  策略: 入站${incoming} / 出站${outgoing} / 转发${routed}"
    else
        echo "  UFW: ✗ 未安装"
    fi
    echo ""

    # Listening Ports
    echo -e "${YELLOW}当前正在监听的端口:${NC}"
    ss -tulpn 2>/dev/null | grep LISTEN | awk '{print "  " $5}' | head -10
    echo ""
}

# Show Main Menu
show_main_menu() {
    # Get status summary
    local os_name=$(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2 | cut -d' ' -f1)
    local hostname=$(hostname)
    local timezone=$(timedatectl | grep "Time zone" | awk '{print $3}')

    # SSH status（支持 sudo 场景）
    local ssh_status=""
    local menu_user_home
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        menu_user_home=$(eval echo ~$SUDO_USER)
    else
        menu_user_home="$HOME"
    fi
    if [ -f "$menu_user_home/.ssh/authorized_keys" ] || [ -f /root/.ssh/authorized_keys ]; then
        ssh_status="SSH:密钥✓"
    else
        ssh_status="SSH:未配置"
    fi

    # Firewall status
    local fw_status=""
    if is_package_installed ufw && command -v ufw &> /dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        fw_status="防火墙:✓"
    else
        fw_status="防火墙:✗"
    fi

    # 只在有TTY时清屏，避免在管道/CI环境中出错
    if [ -t 1 ]; then
        clear
    fi
    print_banner

    # Status summary line
    echo -e "${GREEN}当前系统状态:${NC}"
    echo -e "  ${YELLOW}OS: $os_name | 主机名: $hostname | 时区: $timezone${NC}"
    echo -e "  ${YELLOW}$ssh_status | $fw_status${NC}"
    echo ""

    # Menu options
    echo "请选择操作:"
    echo -e "  ${CYAN}1${NC}) 查看系统状态 (详细信息)"
    echo -e "  ${CYAN}2${NC}) 更改主机名"
    echo -e "  ${CYAN}3${NC}) 时区和时间同步"
    echo -e "  ${CYAN}4${NC}) SSH安全 (密钥登录 + Fail2ban)"
    echo -e "  ${CYAN}5${NC}) 安装防火墙（ufw）"
    echo -e "  ${CYAN}6${NC}) 添加虚拟内存（swap）"
    echo -e "  ${CYAN}7${NC}) 保存当前系统状态(~/baseline/目录下)"
    echo -e "  ${CYAN}8${NC}) 退出"
    echo ""
}

# Generate Baseline
generate_baseline() {
    # 确定正确的用户主目录（sudo 运行时 $HOME 可能不正确）
    local user_home
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        user_home=$(eval echo ~$SUDO_USER)
    else
        user_home="$HOME"
    fi

    echo -e "${CYAN}→ 生成系统基线文档 ($user_home/baseline/)${NC}"

    BASELINE_DIR="$user_home/baseline"
    mkdir -p "$BASELINE_DIR"

    TIMESTAMP=$(date +%y%m%d%H%M)
    OUTPUT_FILE="$BASELINE_DIR/${TIMESTAMP}-system-baseline.txt"

    # Write to file directly instead of using redirection
    cat > "$OUTPUT_FILE" <<EOF
===============================================
VPS 系统基线
===============================================
生成时间: $(date '+%Y-%m-%d %H:%M:%S %Z')
主机名: $(hostname)
===============================================

=== 系统信息 ===

操作系统: $(cat /etc/os-release | grep '^PRETTY_NAME=' | cut -d'"' -f2)
内核版本: $(uname -r)
运行时间: $(uptime -p)
系统负载: $(uptime | awk -F'load average:' '{print $2}')

=== 时间和时区 ===

$(timedatectl)

=== 内存 ===

$(free -h)

$(swapon --show 2>/dev/null || echo "未配置swap")

=== 磁盘 ===

$(df -h)

=== 防火墙 ===

$(if is_package_installed ufw && command -v ufw &> /dev/null; then ufw status verbose 2>/dev/null; else echo "UFW未安装"; fi)

=== SSH配置 ===

$(sshd -T 2>/dev/null | egrep '^(permitrootlogin|passwordauthentication|pubkeyauthentication|port) ')

=== 监听端口 ===

$(ss -tulpn 2>/dev/null | head -20 || netstat -tulpn 2>/dev/null | head -20)

EOF

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ 基线已保存到: $OUTPUT_FILE${NC}"
    else
        echo -e "${RED}✗ 基线生成失败${NC}"
    fi
}

# Interactive Mode Main Loop
run_interactive_mode() {
    local choice

    while true; do
        show_main_menu
        read -p "$(echo -e "${YELLOW}?${NC}" "请输入选项 [1-8]: ")" choice

        case "$choice" in
            1)
                show_system_status
                echo ""
                read -p "$(echo -e "${YELLOW}?${NC}" "按回车返回菜单...")"
                ;;
            2)
                read -p "$(echo -e "${YELLOW}?${NC}" "请输入主机名: ")" hostname_input
                configure_hostname "$hostname_input"
                echo ""
                read -p "$(echo -e "${YELLOW}?${NC}" "按回车返回菜单...")"
                ;;
            3)
                update_system
                configure_timezone
                configure_time_sync
                echo ""
                read -p "$(echo -e "${YELLOW}?${NC}" "按回车返回菜单...")"
                ;;
            4)
                configure_ssh
                echo ""
                read -p "$(echo -e "${YELLOW}?${NC}" "按回车返回菜单...")"
                ;;
            5)
                configure_firewall
                echo ""
                read -p "$(echo -e "${YELLOW}?${NC}" "按回车返回菜单...")"
                ;;
            6)
                configure_memory_interactive
                echo ""
                read -p "$(echo -e "${YELLOW}?${NC}" "按回车返回菜单...")"
                ;;
            7)
                generate_baseline
                echo ""
                read -p "$(echo -e "${YELLOW}?${NC}" "按回车返回菜单...")"
                ;;
            8|q|Q|exit)
                echo -e "${GREEN}再见！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项，请重新选择${NC}"
                ;;
        esac
    done
}

# Print summary
print_summary() {
    local hostname_result="$1"
    local ssh_result="$2"
    local show_all=${3:-0}

    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}          ${GREEN}配置完成！${NC}                                ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${GREEN}✓ 系统配置成功${NC}"
    echo ""
    echo "已应用的配置:"
    [ "$show_all" = "1" ] && echo "  ✓ 时区: Asia/Shanghai"
    [ "$show_all" = "1" ] && echo "  ✓ 时间同步: chrony已启用"
    [ -n "$hostname_result" ] && echo "  ✓ 主机名: $hostname_result"
    [ "$show_all" = "1" -o "$ssh_result" != "" ] && echo "  ✓ SSH: 仅密钥登录，fail2ban已启用（10分钟5次失败封禁12小时）"
    [ "$show_all" = "1" ] && echo "  ✓ 防火墙: 入站拒绝 | 转发拒绝 | 出站允许"
    echo "  ✓ 基线文档: 已生成"
    echo ""
    echo -e "${YELLOW}下一步:${NC}"
    echo -e "  1. ${YELLOW}在新终端中测试SSH访问，确认成功后再关闭当前会话！${NC}"
    echo -e "  2. 查看时间同步: ${CYAN}timedatectl status${NC}"
    echo -e "  3. 查看防火墙: ${CYAN}sudo ufw status verbose${NC}"
    echo -e "  4. 检查服务: ${CYAN}systemctl status fail2ban${NC}"
    echo -e "  5. 查看基线: ${CYAN}ls ~/baseline/${NC}"
    echo ""
}

# Run Auto Mode
run_auto_mode() {
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║${NC}  ${YELLOW}⚠ 快速自动配置模式${NC}                                  ${RED}║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Ask for hostname FIRST (before anything else)
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    read -p "$(echo -e "${YELLOW}?${NC}" "请输入新主机名（直接按回车跳过）: ")" hostname_input
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if [ -n "$hostname_input" ]; then
        echo ""
        echo -e "${CYAN}→ hostnamectl set-hostname $hostname_input${NC}"
    else
        echo ""
        echo -e "${YELLOW}⊘ 跳过主机名设置${NC}"
    fi

    echo ""
    echo -e "${YELLOW}即将执行以下操作:${NC}"
    echo "  ✓ apt update"
    echo "  ✓ timedatectl set-timezone Asia/Shanghai"
    echo "  ✓ 启用 chrony 时间同步"
    if [ -n "$hostname_input" ]; then
        echo "  ✓ 主机名: $hostname_input"
    else
        echo "  ⊘ 主机名: 跳过"
    fi
    echo "  ✓ SSH: 禁用密码登录 + 启用Fail2ban"
    echo "  ✓ ufw: 允许 SSH(${SSH_PORT})/HTTP/HTTPS"
    echo "  ⊘ 内存优化: 自动跳过"
    echo "  ✓ 生成系统状态文档"
    echo ""

    # Check for SSH key
    if ! check_ssh_key; then
        exit 1
    fi

    echo ""
    echo -e "${CYAN}═══ 开始自动配置 ═══${NC}"
    echo ""

    # Run system configurations
    update_system
    configure_timezone
    configure_time_sync

    # Configure hostname (if provided)
    if [ -n "$hostname_input" ]; then
        configure_hostname "$hostname_input"
    fi

    # SSH, Firewall (no prompt needed)
    configure_ssh
    local ssh_success=$?

    # Check if firewall already configured
    if is_package_installed ufw && command -v ufw &> /dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo ""
        echo -e "${GREEN}✓ 防火墙已配置且运行正常，跳过${NC}"
    else
        configure_firewall || {
            echo -e "${RED}✗ 防火墙配置失败${NC}"
            echo -e "${YELLOW}⚠ 请手动检查系统防火墙状态${NC}"
        }
    fi

    # Skip memory optimization in auto mode
    echo ""
    echo -e "${YELLOW}⊘ 内存优化: 已跳过${NC}"

    # Generate baseline (no prompt needed)
    generate_baseline

    print_summary "$hostname_input" "" 1
}

##############################################################################
# Main Execution
##############################################################################

main() {
    print_banner

    check_root
    detect_os

    echo -e "${GREEN}检测到系统: $OS $OS_VERSION${NC}"
    echo ""

    # Auto mode or Interactive mode
    if [ "$AUTO_MODE" = true ]; then
        run_auto_mode
    else
        run_interactive_mode
    fi
}

# Run main function
main
