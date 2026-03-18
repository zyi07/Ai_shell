#!/bin/bash
#===============================================================================
# 脚本名称: init_server.sh
# 版本: 1.1.2 + Fixed SELinux (Strict Base on v1.1.2)
# 描述: 通用 Linux 服务器初始化脚本 (CentOS, Rocky, Alma, Ubuntu, Debian, Kylin, UOS)
# 作者: AI Assistant
# 许可: MIT License
#
# 更新日志:
# [Current]:  [修复] 仅在 v1.1.2 基础上替换了 SELinux 逻辑，确保从 Disabled 恢复必须重启的提示。
# v1.1.2:     [新增] 时间同步模块支持手动输入自定义 NTP 服务器地址。
# v1.1.1:     [修复] 修复 confirm_action 函数中 [y/n] 重复显示的 UI Bug。
# v1.1.0:     [优化] 增加 IP 预展示、缓存更新可选、优化项拆分、报告增强端口展示。
# v1.0.0:     初始版本发布。
#===============================================================================

#-------------------------------------------------------------------------------
# 全局配置与变量定义
#-------------------------------------------------------------------------------
readonly SCRIPT_NAME="init_server.sh"
readonly LOG_FILE="/var/log/server_init.log"
readonly BACKUP_DIR="/root/init_backups_$(date +%Y%m%d_%H%M%S)"
readonly REPORT_FILE="/root/server_init_report_$(date +%Y%m%d_%H%M%S).txt"

# --- 颜色定义 ---
COLOR_RESET="\e[0m"
COLOR_RED="\e[31m"
COLOR_GREEN="\e[32m"
COLOR_YELLOW="\e[33m"
COLOR_BLUE="\e[34m"
COLOR_CYAN="\e[36m"
COLOR_BOLD="\e[1m"

# --- 运行时状态标记 ---
declare -a FAILED_PACKAGES=()
declare -A CONFIG_STATUS=()
declare -a OPEN_PORTS=()

# --- 默认配置变量 ---
NEW_SSH_PORT=22
ADMIN_USER=""
STATIC_IP_MODE="no"
DATA_DISK_MOUNTED="none"
CURRENT_IFACE=""
CURRENT_IP=""
CURRENT_GW=""

# --- 默认 NTP 服务器 (阿里云) ---
DEFAULT_NTP_SERVERS="ntp.aliyun.com ntp1.aliyun.com ntp2.aliyun.com"

#-------------------------------------------------------------------------------
# 工具函数库
#-------------------------------------------------------------------------------

log() {
    local level="$1"
    local msg="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE"
    
    local color=$COLOR_RESET
    local icon=""
    case "$level" in
        INFO)    color=$COLOR_BLUE;  icon="ℹ️" ;;
        SUCCESS) color=$COLOR_GREEN; icon="✅" ;;
        WARN)    color=$COLOR_YELLOW; icon="⚠️" ;;
        ERROR)   color=$COLOR_RED;   icon="❌" ;;
    esac
    echo -e "${color}${COLOR_BOLD}[$icon] [$level]${COLOR_RESET} $msg"
}

backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        mkdir -p "$BACKUP_DIR"
        local basename=$(basename "$file")
        cp "$file" "$BACKUP_DIR/${basename}.bak"
        log INFO "已备份文件: $file"
    elif [[ -d "$file" ]] && [[ "$file" == *.repo ]]; then
         mkdir -p "$BACKUP_DIR"
         cp -r "$file" "$BACKUP_DIR/" 2>/dev/null
         log INFO "已备份目录/文件组: $file"
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log ERROR "非 Root 用户运行！请使用 'sudo $0' 或切换到 root 用户。"
        exit 1
    fi
}

# 优化的二次确认函数 (避免重复提示)
confirm_action() {
    local prompt="$1"
    local default="${2:-y}"
    local response
    
    while true; do
        echo -ne "${COLOR_BOLD}$prompt [y/n]: ${COLOR_RESET}"
        read response
        if [[ -z "$response" ]]; then
            response=$default
        fi
        case "$response" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo -e "${COLOR_YELLOW}无效输入，请输入 y (是) 或 n (否)。${COLOR_RESET}";;
        esac
    done
}

get_input() {
    local prompt="$1"
    local default="$2"
    local input
    if [[ -n "$default" ]]; then
        read -rp "$prompt [默认: $default]: " input
        echo "${input:-$default}"
    else
        read -rp "$prompt: " input
        echo "$input"
    fi
}

#-------------------------------------------------------------------------------
# 2.1 环境检测与预处理
#-------------------------------------------------------------------------------

detect_os() {
    log INFO "正在检测操作系统..."
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_ID=$ID
        OS_VERSION=$VERSION_ID
        OS_NAME=$PRETTY_NAME
    elif [[ -f /etc/centos-release ]]; then
        OS_ID="centos"
        OS_VERSION=$(cat /etc/centos-release | grep -oP '\d+' | head -1)
        OS_NAME=$(cat /etc/centos-release)
    else
        log ERROR "无法识别操作系统类型。"
        exit 1
    fi
    
    if [[ "$OS_ID" == "kylin" || "$OS_ID" == "uos" || ("$OS_ID" == "ubuntu" && "$OS_NAME" == *"UnionTech"*) ]]; then
        log INFO "🇨🇳 检测到国产化系统: $OS_NAME"
    fi

    log SUCCESS "操作系统: $OS_NAME (ID: $OS_ID, Version: $OS_VERSION)"
    
    if command -v dnf &> /dev/null; then
        PKG_MGR="dnf"
    elif command -v yum &> /dev/null; then
        PKG_MGR="yum"
    elif command -v apt &> /dev/null; then
        PKG_MGR="apt"
        export DEBIAN_FRONTEND=noninteractive
    else
        log ERROR "未找到支持的包管理器 (yum/dnf/apt)。"
        exit 1
    fi
    log INFO "包管理器: $PKG_MGR"
}

init_logging() {
    mkdir -p "$(dirname $LOG_FILE)"
    touch "$LOG_FILE"
    echo "========================================" >> "$LOG_FILE"
    echo "Init Start: $(date)" >> "$LOG_FILE"
    echo "OS: $OS_NAME" >> "$LOG_FILE"
    echo "========================================" >> "$LOG_FILE"
}

#-------------------------------------------------------------------------------
# 2.2 网络与主机身份配置
#-------------------------------------------------------------------------------

config_hostname() {
    log INFO "--- 🖥️ 主机名配置 ---"
    local current_hostname=$(hostname)
    log INFO "当前主机名: $current_hostname"
    
    local new_hostname=$(get_input "请输入新主机名" "$current_hostname")
    
    if [[ "$new_hostname" != "$current_hostname" ]]; then
        backup_file /etc/hostname
        backup_file /etc/hosts
        
        hostnamectl set-hostname "$new_hostname"
        
        if grep -q "127.0.0.1.*localhost" /etc/hosts; then
            sed -i "s/127.0.0.1.*localhost.*/127.0.0.1   localhost $new_hostname/" /etc/hosts
        else
            echo "127.0.0.1   localhost $new_hostname" >> /etc/hosts
        fi
        
        log SUCCESS "主机名已修改为: $new_hostname"
        CONFIG_STATUS[HOSTNAME]="$new_hostname"
    else
        CONFIG_STATUS[HOSTNAME]="$current_hostname (未变)"
    fi
}

config_network() {
    log INFO "--- 🌐 网络配置 ---"
    
    CURRENT_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    if [[ -z "$CURRENT_IFACE" ]]; then
        CURRENT_IFACE=$(ip link show | awk -F: '$0 !~ "lo|vir|docker|br" {print $2; exit}' | tr -d ' ')
    fi
    
    if [[ -n "$CURRENT_IFACE" ]]; then
        CURRENT_IP=$(ip -4 addr show $CURRENT_IFACE 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n1)
        CURRENT_GW=$(ip route | grep default | awk '{print $3}' | head -n1)
        CURRENT_PREFIX=$(ip -4 addr show $CURRENT_IFACE 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f2 | head -n1)
        
        log INFO "📡 当前网络状态:"
        log INFO "   网卡接口：$CURRENT_IFACE"
        log INFO "   当前 IP  : ${CURRENT_IP:-未获取到}"
        log INFO "   子网前缀 : ${CURRENT_PREFIX:-未知}"
        log INFO "   默认网关 : ${CURRENT_GW:-未获取到}"
    else
        log WARN "未检测到有效的主网卡接口。"
    fi

    if confirm_action "是否设置静态 IP? (选 n 保持 DHCP/现状)"; then
        STATIC_IP_MODE="yes"
        
        local static_ip=$(get_input "请输入静态 IP 地址" "$CURRENT_IP")
        local prefix_len=$(get_input "请输入子网前缀长度 (如 24)" "${CURRENT_PREFIX:-24}")
        local gateway=$(get_input "请输入网关地址" "$CURRENT_GW")
        local dns1=$(get_input "请输入主 DNS" "8.8.8.8")
        local dns2=$(get_input "请输入备 DNS" "1.1.1.1")

        if [[ -z "$static_ip" || -z "$gateway" ]]; then
            log ERROR "IP 或网关不能为空，配置失败。"
            CONFIG_STATUS[IP_MODE]="配置失败"
            return
        fi

        backup_file "/etc/sysconfig/network-scripts/ifcfg-$CURRENT_IFACE" 2>/dev/null
        backup_file "/etc/netplan/00-installer-config.yaml" 2>/dev/null
        backup_file "/etc/network/interfaces" 2>/dev/null

        log INFO "正在应用静态 IP: $static_ip/$prefix_len, GW: $gateway"

        if [[ "$OS_ID" =~ ^(centos|rocky|almalinux|kylin|uos)$ ]] || [[ -f /etc/redhat-release ]]; then
            local ifcfg_file="/etc/sysconfig/network-scripts/ifcfg-$CURRENT_IFACE"
            if [[ ! -f "$ifcfg_file" ]]; then
                cat > "$ifcfg_file" <<EOF
TYPE=Ethernet
BOOTPROTO=none
DEFROUTE=yes
NAME=$CURRENT_IFACE
DEVICE=$CURRENT_IFACE
ONBOOT=yes
EOF
            fi

            sed -i "s/^BOOTPROTO=.*/BOOTPROTO=none/" "$ifcfg_file"
            sed -i "s/^ONBOOT=.*/ONBOOT=yes/" "$ifcfg_file"
            sed -i '/^IPADDR/d' "$ifcfg_file"
            sed -i '/^PREFIX/d' "$ifcfg_file"
            sed -i '/^GATEWAY/d' "$ifcfg_file"
            sed -i '/^DNS/d' "$ifcfg_file"
            
            cat >> "$ifcfg_file" <<EOF
IPADDR=$static_ip
PREFIX=$prefix_len
GATEWAY=$gateway
DNS1=$dns1
DNS2=$dns2
EOF
            systemctl restart NetworkManager 2>/dev/null || service network restart 2>/dev/null || true
            
        elif [[ "$OS_ID" =~ ^(ubuntu|debian)$ ]]; then
            if command -v netplan &> /dev/null && ls /etc/netplan/*.yaml &>/dev/null; then
                local netplan_file=$(ls /etc/netplan/*.yaml | head -n1)
                cat > "$netplan_file" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $CURRENT_IFACE:
      dhcp4: no
      addresses: [$static_ip/$prefix_len]
      routes:
        - to: default
          via: $gateway
      nameservers:
        addresses: [$dns1, $dns2]
EOF
                netplan apply
            else
                log WARN "未检测到 Netplan，跳过自动配置。"
            fi
        fi

        sleep 3
        if ping -c 1 -W 2 $gateway &> /dev/null; then
            log SUCCESS "网络配置成功！新 IP 已生效。"
            CONFIG_STATUS[IP_MODE]="静态 ($static_ip)"
            CONFIG_STATUS[GATEWAY]="$gateway"
        else
            log ERROR "⚠️ 网络配置后无法 Ping 通网关！请检查物理连接或配置。"
            CONFIG_STATUS[IP_MODE]="静态 (可能失败)"
        fi
    else
        log INFO "跳过静态 IP 配置，保持现状。"
        STATIC_IP_MODE="no"
        CONFIG_STATUS[IP_MODE]="DHCP/动态"
    fi
}

#-------------------------------------------------------------------------------
# 2.3 软件源管理
#-------------------------------------------------------------------------------

config_repos() {
    log INFO "--- 📦 软件源配置 ---"
    
    if confirm_action "是否配置本地/内网源？"; then
        log INFO "进入内网源配置模式..."
        local mode
        PS3="请选择源类型 [1-3]: "
        select mode in "ISO 镜像挂载" "HTTP 内网源" "取消"; do
            case $mode in
                "ISO 镜像挂载")
                    local iso_path=$(get_input "请输入 ISO 镜像路径 (如 /dev/sr0)" "/dev/sr0")
                    local mount_point=$(get_input "请输入挂载点" "/mnt/cdrom")
                    mkdir -p "$mount_point"
                    if mount "$iso_path" "$mount_point" 2>/dev/null || mount -o loop "$iso_path" "$mount_point" 2>/dev/null; then
                        if ! grep -q "$mount_point" /etc/fstab; then
                            echo "$iso_path $mount_point iso9660 defaults 0 0" >> /etc/fstab
                        fi
                        if [[ "$PKG_MGR" =~ yum|dnf ]]; then
                            cat > /etc/yum.repos.d/local.repo <<EOF
[Local-Repo]
name=Local ISO Repo
baseurl=file://$mount_point
enabled=1
gpgcheck=0
EOF
                            log SUCCESS "ISO 源已挂载并配置。"
                        fi
                    else
                        log ERROR "挂载失败。"
                    fi
                    break
                    ;;
                "HTTP 内网源")
                    local http_url=$(get_input "请输入内网 HTTP 源地址" "")
                    if [[ -n "$http_url" ]]; then
                        if [[ "$PKG_MGR" =~ yum|dnf ]]; then
                             for repo in /etc/yum.repos.d/*.repo; do
                                [[ -f "$repo" ]] || continue
                                sed -i "s|^baseurl=.*|baseurl=$http_url|g" "$repo"
                            done
                        elif [[ "$PKG_MGR" == "apt" ]]; then
                            echo "deb $http_url \$(lsb_release -cs) main" > /etc/apt/sources.list
                        fi
                        log SUCCESS "HTTP 内网源已配置。"
                    fi
                    break
                    ;;
                "取消") break ;;
                *) log WARN "无效选项，请输入数字 1-3";;
            esac
        done
    else
        if confirm_action "是否重写在线源地址 (如阿里云/清华源)?"; then
            log INFO "请输入新的在线源 BaseURL (无默认值，需手填):"
            local custom_url=$(get_input "BaseURL" "")
            if [[ -n "$custom_url" ]]; then
                backup_file /etc/yum.repos.d/*.repo 2>/dev/null
                backup_file /etc/apt/sources.list 2>/dev/null
                
                if [[ "$PKG_MGR" =~ yum|dnf ]]; then
                    for repo in /etc/yum.repos.d/*.repo; do
                        [[ -f "$repo" ]] || continue
                        sed -i "s|^baseurl=.*|baseurl=$custom_url|g" "$repo"
                        sed -i "s|^mirrorlist=.*|#mirrorlist=disabled|g" "$repo"
                        sed -i "s|^metalink=.*|#metalink=disabled|g" "$repo"
                    done
                    log SUCCESS "YUM/DNF 源已更新。"
                elif [[ "$PKG_MGR" == "apt" ]]; then
                    echo "deb $custom_url \$(lsb_release -cs) main" > /etc/apt/sources.list
                    log SUCCESS "APT 源已更新。"
                fi
            fi
        else
            log INFO "保持原有在线源配置。"
        fi
    fi

    if confirm_action "是否立即更新软件包缓存 (makecache/apt update)?"; then
        log INFO "正在更新软件包缓存..."
        if [[ "$PKG_MGR" == "apt" ]]; then
            apt update
        else
            $PKG_MGR makecache -y
        fi
        log SUCCESS "缓存更新完成。"
    else
        log INFO "跳过缓存更新，您可稍后手动执行。"
    fi
}

#-------------------------------------------------------------------------------
# 2.4 基础组件安装
#-------------------------------------------------------------------------------

install_packages() {
    log INFO "--- 🛠️ 基础组件安装 ---"
    
    if ! confirm_action "是否安装基础组件 (vim, wget, curl 等)?"; then
        log INFO "跳过基础组件安装。"
        CONFIG_STATUS[PACKAGES]="未安装"
        return
    fi

    if ! ping -c 1 -W 2 8.8.8.8 &> /dev/null; then
        log WARN "外网不通 (Ping 8.8.8.8 失败)。若无本地源，安装可能会失败。"
        if ! confirm_action "是否继续尝试安装？"; then
            CONFIG_STATUS[PACKAGES]="跳过 (网络不通)"
            return
        fi
    fi

    local packages=(vim wget curl net-tools bash-completion telnet unzip tar gzip chrony)
    if [[ "$PKG_MGR" =~ yum|dnf ]]; then
        packages+=(policycoreutils-python-utils) 
    else
        packages+=(openssh-server) 
    fi

    log INFO "正在安装: ${packages[*]}"
    
    for pkg in "${packages[@]}"; do
        if [[ "$PKG_MGR" == "apt" ]]; then
            if ! apt install -y "$pkg" &>> /tmp/install_$pkg.log; then
                log WARN "安装失败: $pkg"
                FAILED_PACKAGES+=("$pkg")
            else
                log SUCCESS "安装成功: $pkg"
            fi
        else
            if ! $PKG_MGR install -y "$pkg" &>> /tmp/install_$pkg.log; then
                log WARN "安装失败: $pkg"
                FAILED_PACKAGES+=("$pkg")
            else
                log SUCCESS "安装成功: $pkg"
            fi
        fi
    done

    if [[ ${#FAILED_PACKAGES[@]} -eq 0 ]]; then
        CONFIG_STATUS[PACKAGES]="全部成功"
    else
        CONFIG_STATUS[PACKAGES]="部分失败 (${FAILED_PACKAGES[*]})"
    fi
}

#-------------------------------------------------------------------------------
# 2.5 安全加固 (SSH)
#-------------------------------------------------------------------------------

harden_ssh() {
    log INFO "--- 🔒 SSH 安全加固 ---"
    
    if ! confirm_action "是否进行 SSH 安全加固？"; then
        log INFO "跳过 SSH 加固。"
        CONFIG_STATUS[SSH_HARDENING]="未启用"
        return
    fi

    ADMIN_USER=$(get_input "请输入新管理员用户名" "admin")
    
    if id "$ADMIN_USER" &>/dev/null; then
        log WARN "用户 $ADMIN_USER 已存在，跳过创建。"
    else
        useradd -m -s /bin/bash "$ADMIN_USER"
        echo "请为用户 $ADMIN_USER 设置密码:"
        passwd "$ADMIN_USER"
        echo "$ADMIN_USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/$ADMIN_USER
        chmod 440 /etc/sudoers.d/$ADMIN_USER
        log SUCCESS "管理员 $ADMIN_USER 创建成功并配置 sudo。"
    fi

    local sshd_config="/etc/ssh/sshd_config"
    backup_file "$sshd_config"
    
    NEW_SSH_PORT=$(get_input "请输入新的 SSH 端口" "22")
    OPEN_PORTS+=("$NEW_SSH_PORT")
    
    sed -i "s/^#Port .*/#Port old_config/" "$sshd_config"
    sed -i "s/^Port .*/#Port old_config/" "$sshd_config"
    echo "Port $NEW_SSH_PORT" >> "$sshd_config"
    
    if confirm_action "是否禁止 Root 远程登录 (PermitRootLogin no)?"; then
        sed -i "s/^#PermitRootLogin .*/PermitRootLogin no/" "$sshd_config"
        sed -i "s/^PermitRootLogin .*/PermitRootLogin no/" "$sshd_config"
        CONFIG_STATUS[ROOT_LOGIN]="禁止"
    else
        CONFIG_STATUS[ROOT_LOGIN]="允许"
    fi
    
    if confirm_action "是否禁止密码认证 (强制密钥登录)?"; then
        sed -i "s/^#PasswordAuthentication .*/PasswordAuthentication no/" "$sshd_config"
        sed -i "s/^PasswordAuthentication .*/PasswordAuthentication no/" "$sshd_config"
        CONFIG_STATUS[PWD_AUTH]="禁止 (仅密钥)"
    else
        CONFIG_STATUS[PWD_AUTH]="允许"
    fi
    
    sed -i "s/^#ClientAliveInterval .*/ClientAliveInterval 300/" "$sshd_config"
    sed -i "s/^#ClientAliveCountMax .*/ClientAliveCountMax 3/" "$sshd_config"

    log SUCCESS "SSH 配置文件已更新 (端口: $NEW_SSH_PORT)。服务将在防火墙配置后统一重启。"
    CONFIG_STATUS[SSH_PORT]="$NEW_SSH_PORT"
    CONFIG_STATUS[SSH_HARDENING]="已启用"
}

#-------------------------------------------------------------------------------
# 2.6 防火墙配置
#-------------------------------------------------------------------------------

config_firewall() {
    log INFO "--- 🛡️ 防火墙配置 ---"
    
    local fw_choice
    PS3="请选择防火墙类型 [1-4]: "
    select fw_choice in "firewalld (CentOS/Rocky)" "ufw (Ubuntu/Debian)" "iptables (原生)" "跳过"; do
        case $fw_choice in
            "firewalld (CentOS/Rocky)")
                if ! command -v firewall-cmd &> /dev/null; then
                    if [[ "$PKG_MGR" =~ yum|dnf ]]; then
                        $PKG_MGR install -y firewalld
                    else
                        log ERROR "当前系统不支持或未安装 firewalld。"
                        break
                    fi
                fi
                systemctl stop ufw &>/dev/null; systemctl disable ufw &>/dev/null
                systemctl enable firewalld --now
                
                firewall-cmd --permanent --add-port=${NEW_SSH_PORT}/tcp
                firewall-cmd --permanent --remove-service=ssh 2>/dev/null
                
                local extra_ports=$(get_input "请输入额外开放的业务端口 (空格分隔，如 80 443)" "")
                if [[ -n "$extra_ports" ]]; then
                    for port in $extra_ports; do
                        firewall-cmd --permanent --add-port=${port}/tcp
                        OPEN_PORTS+=("$port")
                    done
                fi
                
                firewall-cmd --reload
                log SUCCESS "Firewalld 配置完成。"
                CONFIG_STATUS[FIREWALL]="Firewalld"
                break
                ;;
            "ufw (Ubuntu/Debian)")
                if ! command -v ufw &> /dev/null; then
                    apt install -y ufw
                fi
                systemctl stop firewalld &>/dev/null; systemctl disable firewalld &>/dev/null
                
                ufw --force reset
                ufw default deny incoming
                ufw default allow outgoing
                
                ufw allow ${NEW_SSH_PORT}/tcp
                local extra_ports=$(get_input "请输入额外开放的业务端口 (空格分隔)" "")
                if [[ -n "$extra_ports" ]]; then
                    for port in $extra_ports; do
                        ufw allow ${port}/tcp
                        OPEN_PORTS+=("$port")
                    done
                fi
                
                echo "y" | ufw enable
                log SUCCESS "UFW 配置完成。"
                CONFIG_STATUS[FIREWALL]="UFW"
                break
                ;;
            "iptables (原生)")
                log WARN "Iptables 配置较复杂，仅做基础放行示例。"
                iptables -I INPUT 1 -p tcp --dport ${NEW_SSH_PORT} -j ACCEPT
                if command -v iptables-save &> /dev/null; then
                    iptables-save > /etc/sysconfig/iptables 2>/dev/null || iptables-save > /etc/iptables/rules.v4 2>/dev/null
                fi
                CONFIG_STATUS[FIREWALL]="Iptables (基础)"
                break
                ;;
            "跳过")
                log INFO "跳过防火墙配置。"
                CONFIG_STATUS[FIREWALL]="未启用"
                return
                ;;
            *) log WARN "无效选项，请输入数字 1-4";;
        esac
    done

    log INFO "正在重启 SSH 服务以应用新端口..."
    if systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null; then
        log SUCCESS "SSH 服务重启成功。"
    else
        log ERROR "❌ SSH 服务重启失败！请立即检查。"
    fi
}

#-------------------------------------------------------------------------------
# 2.7 系统优化与维护 (模块化) - [仅此处替换了 SELinux 逻辑]
#-------------------------------------------------------------------------------

optimize_system() {
    log INFO "--- ⚡ 系统优化 ---"
    
    # --- [修复版] 1. SELinux 管理 (严格基于 v1.1.2 风格，修复 Disabled 恢复逻辑) ---
    if command -v getenforce &> /dev/null; then
        local current_se_status
        current_se_status=$(getenforce 2>/dev/null)
        
        log INFO "检测到 SELinux 当前运行时状态: ${current_se_status:-Unknown}"
        log INFO "--- 🔒 SELinux 策略配置 ---"
        
        local se_choice
        PS3="请选择操作 [1-3]: "
        select se_choice in "彻底关闭 (Disabled, 需重启生效)" "设为宽容模式 (Permissive, 立即生效)" "保持/开启 (Enforcing)"; do
            case $se_choice in
                "彻底关闭 (Disabled, 需重启生效)")
                    if [[ -f /etc/selinux/config ]]; then
                        backup_file /etc/selinux/config
                        sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
                        setenforce 0 2>/dev/null || true
                        log SUCCESS "配置已更新为 Disabled"
                        CONFIG_STATUS[SELINUX]="Disabled (需重启完全生效)"
                        CONFIG_STATUS[SELINUX_REBOOT_REQ]="yes"
                    else
                        log WARN "未找到配置文件"
                        CONFIG_STATUS[SELINUX]="配置失败"
                    fi
                    break;;
                    
                "设为宽容模式 (Permissive, 立即生效)")
                    if [[ -f /etc/selinux/config ]]; then
                        backup_file /etc/selinux/config
                        sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
                        if [[ "$current_se_status" == "Disabled" ]]; then
                            log WARN "当前内核未加载 SELinux，无法即时切换。已修改配置文件，请重启生效。"
                            CONFIG_STATUS[SELINUX]="Permissive (需重启生效)"
                            CONFIG_STATUS[SELINUX_REBOOT_REQ]="yes"
                        else
                            setenforce 0
                            log SUCCESS "已切换为 Permissive (立即生效)"
                            CONFIG_STATUS[SELINUX]="Permissive"
                            CONFIG_STATUS[SELINUX_REBOOT_REQ]="no"
                        fi
                    else
                        log WARN "未找到配置文件"
                        CONFIG_STATUS[SELINUX]="配置失败"
                    fi
                    break;;
                    
                "保持/开启 (Enforcing)")
                    if [[ -f /etc/selinux/config ]]; then
                        backup_file /etc/selinux/config
                        sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
                        
                        # 核心修复：如果当前是 Disabled，setenforce 无效，必须重启
                        if [[ "$current_se_status" == "Disabled" ]]; then
                            log WARN "⚠️ 当前 SELinux 处于 Disabled 状态 (内核未加载)。"
                            log WARN "已修改配置文件为 Enforcing，但必须 REBOOT 重启服务器才能加载内核模块并生效！"
                            CONFIG_STATUS[SELINUX]="Enforcing (需重启生效)"
                            CONFIG_STATUS[SELINUX_REBOOT_REQ]="yes"
                        else
                            setenforce 1
                            log SUCCESS "已切换为 Enforcing (立即生效)"
                            CONFIG_STATUS[SELINUX]="Enforcing"
                            CONFIG_STATUS[SELINUX_REBOOT_REQ]="no"
                        fi
                    else
                        log WARN "未找到配置文件"
                        CONFIG_STATUS[SELINUX]="配置失败"
                    fi
                    break;;
                    
                *) log WARN "无效选项";;
            esac
        done
    else
        log INFO "当前系统未安装 SELinux，跳过。"
        CONFIG_STATUS[SELINUX]="未安装/N/A"
        CONFIG_STATUS[SELINUX_REBOOT_REQ]="no"
    fi

    # --- 2. 时间同步 (保留 v1.1.2 自定义 NTP 功能) ---
    if confirm_action "是否安装并启用 Chrony 时间同步服务？"; then
        if command -v chronyd &> /dev/null || command -v chrony &> /dev/null; then
            # 【v1.1.2 功能】询问是否自定义 NTP 服务器
            if confirm_action "是否手动指定 NTP 同步服务器？(选 n 使用默认阿里云)"; then
                local custom_ntp=$(get_input "请输入 NTP 服务器地址 (空格分隔多个)" "")
                if [[ -n "$custom_ntp" ]]; then
                    NTP_SERVERS="$custom_ntp"
                    log INFO "将使用自定义 NTP 服务器: $NTP_SERVERS"
                else
                    log WARN "未输入有效地址，自动切换回默认阿里云服务器。"
                    NTP_SERVERS="$DEFAULT_NTP_SERVERS"
                fi
            else
                NTP_SERVERS="$DEFAULT_NTP_SERVERS"
                log INFO "将使用默认阿里云 NTP 服务器: $NTP_SERVERS"
            fi

            # 确定配置文件路径 (不同发行版路径可能不同)
            local chrony_conf="/etc/chrony.conf"
            if [[ ! -f "$chrony_conf" ]] && [[ -f "/etc/chrony/chrony.conf" ]]; then
                chrony_conf="/etc/chrony/chrony.conf"
            fi

            if [[ -f "$chrony_conf" ]]; then
                backup_file "$chrony_conf"
                
                # 备份原文件后，清空原有的 server 行并写入新的
                sed -i 's/^server /#server /g' "$chrony_conf"
                sed -i 's/^pool /#pool /g' "$chrony_conf"
                
                # 写入新的服务器列表
                echo "" >> "$chrony_conf"
                echo "# Configured by init_server.sh" >> "$chrony_conf"
                for srv in $NTP_SERVERS; do
                    echo "server $srv iburst" >> "$chrony_conf"
                done
                
                # 重启服务
                systemctl enable chronyd --now 2>/dev/null || systemctl enable chrony --now 2>/dev/null
                # 强制刷新一次时间
                chronyc -a makestep &>/dev/null
                
                log SUCCESS "Chrony 时间同步已启用 (服务器: $NTP_SERVERS)。"
                CONFIG_STATUS[CHRONY]="已启用 ($NTP_SERVERS)"
            else
                log WARN "未找到 chrony 配置文件"
                CONFIG_STATUS[CHRONY]="配置失败"
            fi
        else
            log WARN "未找到 chrony 包，跳过。"
            CONFIG_STATUS[CHRONY]="未安装"
        fi
    else
        log INFO "跳过时间同步配置。"
        CONFIG_STATUS[CHRONY]="未配置"
    fi
    
    # --- 3. 内核参数调优 ---
    if confirm_action "是否进行内核参数调优 (vm.swappiness, file-max 等)?"; then
        backup_file /etc/sysctl.conf
        cat >> /etc/sysctl.conf <<EOF
# Optimized by init_server.sh
vm.swappiness = 10
fs.file-max = 2097152
net.core.somaxconn = 65535
EOF
        sysctl -p &>/dev/null
        log SUCCESS "内核参数已调优。"
        CONFIG_STATUS[KERNEL_TUNING]="已完成"
    else
        log INFO "跳过内核参数调优。"
        CONFIG_STATUS[KERNEL_TUNING]="未配置"
    fi

    # --- 4. 文件句柄数限制 ---
    if confirm_action "是否修改文件句柄数限制 (nofile 65535)?"; then
        backup_file /etc/security/limits.conf
        if ! grep -q "nofile 65535" /etc/security/limits.conf; then
            cat >> /etc/security/limits.conf <<EOF
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF
            log SUCCESS "文件句柄数限制已更新。"
        fi
    fi
    
    # --- 5. 数据盘自动化挂载 ---
    log INFO "扫描未挂载磁盘..."
    local disks=($(lsblk -dpno NAME,TYPE,MOUNTPOINT | awk '$2=="disk" && $3=="" {print $1}'))
    
    if [[ ${#disks[@]} -eq 0 ]]; then
        log INFO "未发现未挂载的数据盘，跳过。"
        DATA_DISK_MOUNTED="无"
    else
        log INFO "发现以下未挂载磁盘: ${disks[*]}"
        if confirm_action "是否格式化并挂载数据盘？"; then
            PS3="请选择要格式化的磁盘 [1-${#disks[@]}]: "
            select disk in "${disks[@]}" "取消"; do
                if [[ "$disk" == "取消" ]]; then
                    DATA_DISK_MOUNTED="用户取消"
                    break
                elif [[ -n "$disk" ]]; then
                    local mount_point=$(get_input "请输入挂载点" "/data")
                    
                    log WARN "⚠️ 即将格式化 $disk (数据将永久丢失)! 确认继续？(输入 yes 确认)"
                    read -rp "确认: " confirm_fmt
                    if [[ "$confirm_fmt" == "yes" ]]; then
                        mkfs.ext4 -F "$disk"
                        mkdir -p "$mount_point"
                        local uuid=$(blkid -s UUID -o value "$disk")
                        echo "UUID=$uuid $mount_point ext4 defaults 0 0" >> /etc/fstab
                        mount -a
                        chown -R $ADMIN_USER:$ADMIN_USER "$mount_point" 2>/dev/null || chown -R root:root "$mount_point"
                        log SUCCESS "磁盘 $disk 已格式化并挂载到 $mount_point"
                        DATA_DISK_MOUNTED="$disk -> $mount_point"
                    else
                        log INFO "取消格式化。"
                        DATA_DISK_MOUNTED="未操作"
                    fi
                    break
                else
                    log WARN "无效选项，请输入数字。"
                fi
            done
        else
            DATA_DISK_MOUNTED="用户跳过"
        fi
    fi
}

#-------------------------------------------------------------------------------
# 2.8 交付与收尾
#-------------------------------------------------------------------------------

generate_report() {
    clear
    echo -e "${COLOR_GREEN}${COLOR_BOLD}========================================${COLOR_RESET}"
    echo -e "${COLOR_GREEN}${COLOR_BOLD}       🎉 服务器初始化完成报告           ${COLOR_RESET}"
    echo -e "${COLOR_GREEN}${COLOR_BOLD}========================================${COLOR_RESET}"
    echo ""
    
    local report_content=""
    report_content+="时间：$(date)\n"
    report_content+="主机名：${CONFIG_STATUS[HOSTNAME]}\n"
    report_content+="IP 模式：${CONFIG_STATUS[IP_MODE]}\n"
    if [[ "$STATIC_IP_MODE" == "yes" ]]; then
        local cur_ip=$(ip -4 addr show $CURRENT_IFACE 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n1)
        report_content+="IP 地址：${cur_ip}\n"
        report_content+="网关：${CONFIG_STATUS[GATEWAY]}\n"
    fi
    report_content+="基础组件：${CONFIG_STATUS[PACKAGES]}\n"
    if [[ -n "$ADMIN_USER" ]]; then
        report_content+="管理员用户：$ADMIN_USER\n"
    fi
    report_content+="SSH 端口：${CONFIG_STATUS[SSH_PORT]:-22}\n"
    report_content+="SSH 加固：${CONFIG_STATUS[SSH_HARDENING]:-未启用}\n"
    report_content+="Root 登录：${CONFIG_STATUS[ROOT_LOGIN]:-未配置}\n"
    report_content+="密码认证：${CONFIG_STATUS[PWD_AUTH]:-未配置}\n"
    report_content+="防火墙：${CONFIG_STATUS[FIREWALL]:-未启用}\n"
    
    # [增强] 显示 SELinux 状态及是否需要重启
    local se_status="${CONFIG_STATUS[SELINUX]:-未检测}"
    if [[ "${CONFIG_STATUS[SELINUX_REBOOT_REQ]}" == "yes" ]]; then
        report_content+="SELinux：${COLOR_RED}${se_status} (必须重启!)${COLOR_RESET}\n"
    else
        report_content+="SELinux：${se_status}\n"
    fi
    
    if [[ ${#OPEN_PORTS[@]} -gt 0 ]]; then
        local unique_ports=($(echo "${OPEN_PORTS[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
        report_content+="开放端口：${unique_ports[*]}\n"
    else
        report_content+="开放端口：无额外配置\n"
    fi

    report_content+="时间同步：${CONFIG_STATUS[CHRONY]:-未配置}\n"
    report_content+="内核调优：${CONFIG_STATUS[KERNEL_TUNING]:-未配置}\n"
    report_content+="数据盘：${DATA_DISK_MOUNTED}\n"
    
    if [[ ${#FAILED_PACKAGES[@]} -gt 0 ]]; then
        report_content+="\n${COLOR_RED}⚠️ 警告：以下软件包安装失败：${FAILED_PACKAGES[*]}${COLOR_RESET}\n"
    fi
    
    echo -e "$report_content"
    echo -e "$report_content" > "$REPORT_FILE"
    echo ""
    echo -e "${COLOR_CYAN}📄 详细报告已保存至：$REPORT_FILE${COLOR_RESET}"
    echo -e "${COLOR_CYAN}📜 操作日志已保存至：$LOG_FILE${COLOR_RESET}"
    echo -e "${COLOR_CYAN}💾 备份目录位于：$BACKUP_DIR${COLOR_RESET}"
    echo ""
}

final_reboot() {
    # 如果 SELinux 选择了彻底关闭，或者从 Disabled 恢复，提示必须重启
    if [[ "${CONFIG_STATUS[SELINUX_REBOOT_REQ]}" == "yes" ]]; then
        log WARN "⚠️ 检测到 SELinux 配置变更需要从 Disabled 恢复或彻底关闭，必须重启才能生效。"
    fi

    if confirm_action "是否立即重启服务器以使所有配置生效？"; then
        log INFO "系统将在 3 秒后重启..."
        sleep 1
        echo "3..."
        sleep 1
        echo "2..."
        sleep 1
        echo "1..."
        reboot
    else
        log INFO "配置完成。请手动执行 'reboot' 重启服务器。"
        if [[ "${CONFIG_STATUS[SSH_PORT]}" != "22" ]]; then
            echo "⚠️ 提示：您修改了 SSH 端口，重启后请使用以下命令连接："
            echo "   ssh -p ${CONFIG_STATUS[SSH_PORT]} ${ADMIN_USER}@<服务器IP>"
        fi
        if [[ "${CONFIG_STATUS[SELINUX_REBOOT_REQ]}" == "yes" ]]; then
            echo -e "${COLOR_RED}⚠️ 重要提示：SELinux 将在下次重启后正式生效！${COLOR_RESET}"
        fi
    fi
}

#-------------------------------------------------------------------------------
# 主执行流程
#-------------------------------------------------------------------------------

main() {
    check_root
    detect_os
    init_logging
    
    log INFO "🚀 开始初始化流程..."
    
    config_hostname
    config_network
    config_repos
    install_packages
    harden_ssh
    config_firewall
    optimize_system
    
    generate_report
    final_reboot
}

main "$@"
