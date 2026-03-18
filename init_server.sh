#!/bin/bash
###############################################################################
# 脚本名称: init_server.sh
# 版本: 21.0 
# 
# 【功能概述】
# 本脚本用于 Linux 服务器的一键初始化部署。
#
# 【使用方法】
# chmod +x init_server_v21_enhanced.sh && sudo ./init_server_v21_enhanced.sh
###############################################################################

set -uo pipefail

# =============================================================================
# 【🔧 全局配置区域】
# =============================================================================

# --- 1. 网络与主机身份配置 ---
DEF_HOSTNAME="linux-node-01"
DEF_IP_ADDR=""                    # 留空则尝试自动检测
DEF_PREFIX="24"
DEF_GATEWAY="192.168.10.2"
DEF_DNS_1="223.5.5.5"
DEF_DNS_2="8.8.8.8"

# --- 2. 安全加固配置 ---
DEF_ADMIN_USER="ops_admin"
DEF_SSH_PORT="2222"

# --- 3. 系统内核优化配置 ---
DEF_FILE_LIMIT="65535"
DEF_SWAPPINESS="10"
DEF_DATA_MOUNT="/data"

# --- 4. 基础组件列表 ---
BASE_COMPONENTS_YUM="vim wget curl net-tools bash-completion telnet unzip tar gzip ntpdate chrony"
BASE_COMPONENTS_APT="vim wget curl net-tools bash-completion telnet unzip tar gzip ntpdate chrony"

# =============================================================================
# 【📦 全局变量定义】
# =============================================================================
LOG_FILE="/var/log/server_init.log"
BACKUP_DIR="/root/init_backups_$(date +%F_%H%M)"
OS_ID=""
PKG_MGR=""
LOCAL_REPO_CONFIGURED=false

# 运行时记录变量 (用于最终报告)
RUN_HOSTNAME=""
RUN_IP_ADDR=""
RUN_GATEWAY=""
RUN_IP_MODE="DHCP/保持原状"  # 新增：记录 IP 模式
RUN_ADMIN_USER=""
RUN_SSH_PORT=""
RUN_DISABLE_ROOT="No"
RUN_DISABLE_PASS="No"
RUN_DATA_MOUNT_INFO="未操作"
RUN_COMPONENTS_INSTALLED="否" # 新增：记录组件安装状态

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# =============================================================================
# 【🛠️ 基础工具函数库】
# =============================================================================

log() {
    local level=$1; shift
    local msg="$*"
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf "%s [%s] %s\n" "$ts" "$level" "$msg" >> "$LOG_FILE"
    
    local color_code=""
    local icon=""
    case $level in
        "INFO")    color_code="$BLUE"; icon="ℹ️" ;;
        "SUCCESS") color_code="$GREEN"; icon="✅" ;;
        "WARN")    color_code="$YELLOW"; icon="⚠️" ;;
        "ERROR")   color_code="$RED"; icon="❌" ;;
        "PROMPT")  color_code="$CYAN"; icon="👉" ;;
        "STEP")    color_code="$BOLD$CYAN"; icon="🚀" ;;
        "SUMMARY") color_code="$BOLD$GREEN"; icon="📋" ;;
    esac
    
    if [[ -n "$color_code" ]]; then
        printf "${color_code}[%s] ${icon} %s${NC}\n" "$level" "$msg"
    else
        printf "%s\n" "$msg"
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "必须使用 root 用户运行！"
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID=$ID
        if [[ "$OS_ID" == "kylin" || "$OS_ID" == "neokylin" || "$OS_ID" == "uos" || "$OS_ID" == "deepin" ]]; then
            log "INFO" "检测到国产化系统：$PRETTY_NAME"
        else
            log "INFO" "检测到系统：$PRETTY_NAME"
        fi
    else
        log "ERROR" "无法识别操作系统。"
        exit 1
    fi

    if command -v apt &>/dev/null; then PKG_MGR="apt";
    elif command -v yum &>/dev/null; then PKG_MGR="yum";
    elif command -v dnf &>/dev/null; then PKG_MGR="dnf";
    else log "ERROR" "未找到包管理器。"; exit 1; fi
    log "INFO" "包管理器：$PKG_MGR"
}

get_input() {
    local prompt_msg="$1"
    local default_val="$2"
    local response
    if [[ -n "$default_val" ]]; then
        printf "${CYAN}👉 ${prompt_msg} [默认：${BOLD}${default_val}${NC}${CYAN}]: ${NC}"
        read -r response
        INPUT_RESULT="${response:-$default_val}"
    else
        printf "${CYAN}👉 ${prompt_msg}: ${NC}"
        read -r response
        INPUT_RESULT="$response"
    fi
}

ask_confirm() {
    local msg="$1"
    while true; do
        printf "${YELLOW}❓ ${msg} (y/n): ${NC}"
        read -r yn
        case $yn in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo "请输入 y 或 n。";;
        esac
    done
}

create_backup() {
    local target="$1"
    if [[ ! -e "$target" ]]; then return 0; fi
    mkdir -p "$BACKUP_DIR"
    local backup_name="$(basename "$target").bak.$(date +%s)"
    if [[ -f "$target" ]]; then
        \cp -f "$target" "$BACKUP_DIR/$backup_name"
        log "INFO" "已备份：$target"
    elif [[ -d "$target" ]]; then
        tar -czf "$BACKUP_DIR/$(basename "$target").tar.gz" -C "$(dirname "$target")" "$(basename "$target")" 2>/dev/null
        log "INFO" "已备份目录：$target"
    fi
}

get_current_ip() {
    local ip=""
    local iface=$(ip route | grep default | awk '{print $5}' | head -n1)
    if [[ -n "$iface" ]]; then
        ip=$(ip -4 addr show "$iface" | grep "inet " | awk '{print $2}' | cut -d/ -f1 | head -n1)
    fi
    if [[ -z "$ip" ]]; then
        ip=$(ip -4 addr show | grep "inet " | grep -v 127.0.0.1 | head -n1 | awk '{print $2}' | cut -d/ -f1)
    fi
    echo "${ip:-}"
}

# =============================================================================
# 【🚀 核心业务模块】
# =============================================================================

# ------------------------------------------------------------------------------
# 模块 1: 主机身份与网络配置 (v21: 增加静态 IP 开关)
# ------------------------------------------------------------------------------
config_network_identity() {
    log "STEP" "[1/8] 开始配置主机名与网络..."
    
    if ! ask_confirm "是否需要配置主机名？"; then
        RUN_HOSTNAME=$(hostname)
    else
        local current_hostname=$(hostname)
        get_input "设置新的主机名" "$DEF_HOSTNAME"
        local target_hostname="$INPUT_RESULT"
        RUN_HOSTNAME="$target_hostname"
        
        if [[ "$current_hostname" != "$target_hostname" ]]; then
            hostnamectl set-hostname "$target_hostname"
            log "SUCCESS" "主机名已更新：$target_hostname"
        fi
    fi

    # ★★★ 新增：独立询问是否设置静态 IP ★★★
    if ask_confirm "是否设置静态 IP 地址？(选 n 则保持 DHCP 或当前状态)"; then
        RUN_IP_MODE="静态 IP"
        local current_ip=$(get_current_ip)
        if [[ -n "$current_ip" ]]; then
            log "INFO" "🌐 当前检测到的 IP: ${BOLD}$current_ip${NC}"
            get_input "设置新的静态 IP" "$DEF_IP_ADDR"
            if [[ -z "$INPUT_RESULT" && -z "$DEF_IP_ADDR" ]]; then
                 INPUT_RESULT="$current_ip"
            fi
        else
            log "WARN" "未检测到 IP，请手动输入。"
            get_input "设置新的静态 IP" "$DEF_IP_ADDR"
        fi
        
        local target_ip="$INPUT_RESULT"
        RUN_IP_ADDR="$target_ip"
        local network_config_success=false 

        if [[ -n "$target_ip" ]]; then
            get_input "设置默认网关" "$DEF_GATEWAY"
            local target_gw="$INPUT_RESULT"
            RUN_GATEWAY="$target_gw"
            
            get_input "设置子网前缀 (PREFIX)" "$DEF_PREFIX"
            local target_prefix="$INPUT_RESULT"
            
            if ask_confirm "确认应用网络配置？"; then
                local iface=$(ip route | grep default | awk '{print $5}' | head -1)
                if [[ -z "$iface" ]]; then
                    iface=$(ip link show | awk -F: '$0 !~ "lo|vir|docker|^$" && /UP/ {print $2}' | tr -d ' ' | head -n1)
                fi

                if [[ -z "$iface" ]]; then
                    log "ERROR" "无法识别网卡。"
                else
                    local cfg_file=""
                    if [[ -d /etc/sysconfig/network-scripts ]]; then
                        cfg_file="/etc/sysconfig/network-scripts/ifcfg-$iface"
                    elif [[ -f /etc/netplan/*.yaml ]]; then
                        log "WARN" "Netplan 需手动配置，跳过自动改写。"
                    fi

                    if [[ -n "$cfg_file" && -f "$cfg_file" ]]; then
                        create_backup "$cfg_file"
                        local old_uuid=$(grep "^UUID=" "$cfg_file" 2>/dev/null | cut -d'=' -f2 | tr -d ' ')
                        [[ -z "$old_uuid" ]] && old_uuid=$(cat /proc/sys/kernel/random/uuid)

                        cat > "$cfg_file" << EOF
TYPE=Ethernet
BOOTPROTO=static
DEFROUTE=yes
NAME=$iface
DEVICE=$iface
ONBOOT=yes
IPADDR=$target_ip
PREFIX=$target_prefix
GATEWAY=$target_gw
DNS1=$DEF_DNS_1
DNS2=$DEF_DNS_2
EOF
                        systemctl restart network 2>/dev/null || true
                        systemctl restart NetworkManager 2>/dev/null || true
                        sleep 5
                        
                        if [[ "$(get_current_ip)" == "$target_ip" ]]; then
                            network_config_success=true
                            log "SUCCESS" "网络配置验证通过。"
                        else
                            log "ERROR" "网络配置验证失败。"
                        fi
                    fi
                fi
            fi
        fi
        
        if [[ "$network_config_success" == true ]]; then
            local final_ip=$(get_current_ip)
            [[ -z "$final_ip" ]] && final_ip="$target_ip"
            local hosts_file="/etc/hosts"
            create_backup "$hosts_file"
            sed -i "/[[:space:]]${RUN_HOSTNAME}$/d" "$hosts_file"
            echo "$final_ip $RUN_HOSTNAME" >> "$hosts_file"
            log "SUCCESS" "Hosts 已更新。"
        fi
    else
        # 用户选择不设置静态 IP
        RUN_IP_MODE="DHCP/保持原状"
        RUN_IP_ADDR=$(get_current_ip)
        RUN_GATEWAY=$(ip route | grep default | awk '{print $3}' | head -1)
        log "INFO" "已跳过静态 IP 配置，保持当前网络状态。"
        sync_hosts_file
    fi
}

sync_hosts_file() {
    local target_hostname=${1:-$(hostname)}
    local current_ip=$(get_current_ip)
    local hosts_file="/etc/hosts"
    if [[ -z "$current_ip" || ! -w "$hosts_file" ]]; then return 1; fi
    create_backup "$hosts_file"
    sed -i "/[[:space:]]${target_hostname}$/d" "$hosts_file"
    echo "$current_ip $target_hostname" >> "$hosts_file"
}

# ------------------------------------------------------------------------------
# 模块 2: 软件源管理
# ------------------------------------------------------------------------------
config_local_repo() {
    log "STEP" "[2/8] 开始配置软件源..."
    if ! ask_confirm "是否配置本地/内网软件源？"; then
        if ask_confirm "是否重写在线源地址？"; then
            if [[ "$PKG_MGR" == "yum" || "$PKG_MGR" == "dnf" ]]; then
                local repo_dir="/etc/yum.repos.d"
                create_backup "$repo_dir"
                mkdir -p "$BACKUP_DIR/old_repos"
                \mv "$repo_dir"/*.repo "$BACKUP_DIR/old_repos/" 2>/dev/null || true
                get_input "请输入新的在线源 BaseURL" ""
                local new_url="$INPUT_RESULT"
                if [[ -n "$new_url" ]]; then
                    cat > "$repo_dir/custom_online.repo" << EOF
[Custom-Online]
name=Custom Online Repository
baseurl=$new_url
enabled=1
gpgcheck=0
EOF
                    $PKG_MGR makecache && LOCAL_REPO_CONFIGURED=true || LOCAL_REPO_CONFIGURED=false
                fi
            elif [[ "$PKG_MGR" == "apt" ]]; then
                local sources_list="/etc/apt/sources.list"
                create_backup "$sources_list"
                > "$sources_list"
                \rm -f /etc/apt/sources.list.d/*.list 2>/dev/null || true
                get_input "请输入新的在线源地址" ""
                local new_url="$INPUT_RESULT"
                if [[ -n "$new_url" ]]; then
                    local codename=$(lsb_release -cs 2>/dev/null || echo "unknown")
                    cat > "$sources_list" << EOF
deb $new_url $codename main restricted universe multiverse
deb $new_url $codename-updates main restricted universe multiverse
deb $new_url $codename-security main restricted universe multiverse
EOF
                    apt update && LOCAL_REPO_CONFIGURED=true || LOCAL_REPO_CONFIGURED=false
                fi
            fi
        else
            LOCAL_REPO_CONFIGURED=false
        fi
        return
    fi

    # 简化版本地源逻辑 (ISO/HTTP)
    echo -e "${CYAN}请选择源类型:${NC} 1) ISO 镜像挂载  2) 内网 HTTP 源  0) 取消"
    read -rp "选项： " repo_choice
    [[ "$repo_choice" == "0" ]] && { LOCAL_REPO_CONFIGURED=false; return; }

    local success=false
    local mount_point="/mnt/cdrom"
    mkdir -p "$mount_point"

    if [[ "$PKG_MGR" == "yum" || "$PKG_MGR" == "dnf" ]]; then
        create_backup "/etc/yum.repos.d"
        \mv /etc/yum.repos.d/*.repo "$BACKUP_DIR/old_repos/" 2>/dev/null || true
    elif [[ "$PKG_MGR" == "apt" ]]; then
        create_backup "/etc/apt/sources.list"
        > /etc/apt/sources.list
    fi

    if [[ "$repo_choice" == "1" ]]; then
        get_input "ISO 路径" ""
        local iso_path="$INPUT_RESULT"
        if [[ -f "$iso_path" ]] && mount -o loop "$iso_path" "$mount_point" 2>/dev/null; then
            echo "$iso_path  $mount_point  iso9660  loop 0 0" >> /etc/fstab
            if [[ "$PKG_MGR" == "yum" || "$PKG_MGR" == "dnf" ]]; then
                echo -e "[Local-ISO]\nbaseurl=file://$mount_point\nenabled=1\ngpgcheck=0" > "/etc/yum.repos.d/local_iso.repo"
                $PKG_MGR makecache && success=true
            elif [[ "$PKG_MGR" == "apt" ]]; then
                echo "deb [trusted=yes] file:$mount_point ./" > /etc/apt/sources.list
                apt update && success=true
            fi
        fi
    elif [[ "$repo_choice" == "2" ]]; then
        get_input "内网源 URL" ""
        local repo_url="$INPUT_RESULT"
        if [[ -n "$repo_url" ]]; then
            if [[ "$PKG_MGR" == "yum" || "$PKG_MGR" == "dnf" ]]; then
                echo -e "[Local-Net]\nbaseurl=$repo_url\nenabled=1\ngpgcheck=0" > "/etc/yum.repos.d/local_net.repo"
                $PKG_MGR makecache && success=true
            elif [[ "$PKG_MGR" == "apt" ]]; then
                local codename=$(lsb_release -cs 2>/dev/null || echo "unknown")
                echo -e "deb $repo_url $codename main restricted universe multiverse\ndeb $repo_url $codename-security main restricted universe multiverse" > /etc/apt/sources.list
                apt update && success=true
            fi
        fi
    fi
    [[ "$success" == true ]] && LOCAL_REPO_CONFIGURED=true || LOCAL_REPO_CONFIGURED=false
}

# ------------------------------------------------------------------------------
# 模块 3: 安装组件 (v21: 增加独立开关)
# ------------------------------------------------------------------------------
check_and_install_components() {
    log "STEP" "[3/8] 基础组件安装..."
    
    # ★★★ 新增：独立询问是否安装组件 ★★★
    if ! ask_confirm "是否安装基础组件 (vim, wget, curl 等)？"; then
        log "INFO" "用户选择跳过组件安装。"
        RUN_COMPONENTS_INSTALLED="否 (用户跳过)"
        return
    fi

    local components=""
    [[ "$PKG_MGR" == "apt" ]] && components="$BASE_COMPONENTS_APT" || components="$BASE_COMPONENTS_YUM"

    if [[ "$LOCAL_REPO_CONFIGURED" == true ]]; then
        install_components_logic "$components"
        RUN_COMPONENTS_INSTALLED="是 (本地源)"
    else
        if ping -c 3 -W 2 www.baidu.com > /dev/null 2>&1; then
            install_components_logic "$components"
            RUN_COMPONENTS_INSTALLED="是 (在线源)"
        else
            log "WARN" "网络不通且无本地源，跳过安装。"
            RUN_COMPONENTS_INSTALLED="否 (网络不通)"
        fi
    fi
}

install_components_logic() {
    local comps="$1"
    local failed_pkgs=()
    log "INFO" "正在安装：$comps"
    
    if [[ "$PKG_MGR" == "apt" ]]; then
        apt update -y
        for pkg in $comps; do
            apt install -y "$pkg" > /dev/null 2>&1 || failed_pkgs+=("$pkg")
        done
    else
        $PKG_MGR makecache -y 2>/dev/null || true
        for pkg in $comps; do
            $PKG_MGR install -y "$pkg" > /dev/null 2>&1 || failed_pkgs+=("$pkg")
        done
    fi

    if [[ ${#failed_pkgs[@]} -gt 0 ]]; then
        log "ERROR" "❌ 以下组件安装失败："
        for pkg in "${failed_pkgs[@]}"; do echo "   - $pkg"; done
    else
        log "SUCCESS" "✅ 组件安装完成。"
    fi
}

# ------------------------------------------------------------------------------
# 模块 4: 安全加固
# ------------------------------------------------------------------------------
harden_security() {
    log "STEP" "[4/8] 安全加固 (SSH)..."
    if ! ask_confirm "是否进行 SSH 安全加固？"; then 
        RUN_SSH_PORT=$(grep "^Port" /etc/ssh/sshd_config 2>/dev/null | tail -1 | awk '{print $2}')
        RUN_SSH_PORT=${RUN_SSH_PORT:-22}
        RUN_ADMIN_USER="未新建"
        return
    fi
    
    get_input "设置管理员用户名" "$DEF_ADMIN_USER"
    local user="$INPUT_RESULT"
    RUN_ADMIN_USER="$user"
    
    if ! id "$user" &>/dev/null; then
        useradd -m -s /bin/bash "$user"
        echo "$user ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/$user
        chmod 440 /etc/sudoers.d/$user
        log "SUCCESS" "用户 $user 创建成功。"
        passwd "$user"
    fi
    
    local ssh_conf="/etc/ssh/sshd_config"
    create_backup "$ssh_conf"
    
    get_input "设置 SSH 端口" "$DEF_SSH_PORT"
    RUN_SSH_PORT="$INPUT_RESULT"
    
    sed -i "s/^Port .*/#&/" "$ssh_conf"
    echo "Port $RUN_SSH_PORT" >> "$ssh_conf"
    
    if ask_confirm "禁止 Root 远程登录？"; then
        sed -i "s/^#*PermitRootLogin.*/PermitRootLogin no/" "$ssh_conf"
        RUN_DISABLE_ROOT="Yes"
    fi

    if ask_confirm "禁止密码认证？"; then
        sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication no/" "$ssh_conf"
        RUN_DISABLE_PASS="Yes"
    fi
}

# ------------------------------------------------------------------------------
# 模块 5: 防火墙
# ------------------------------------------------------------------------------
config_firewall() {
    log "STEP" "[5/8] 配置防火墙..."
    if ! ask_confirm "是否配置防火墙？"; then return; fi
    
    [[ -z "${RUN_SSH_PORT:-}" ]] && RUN_SSH_PORT=22
    
    echo -e "${CYAN}选择防火墙：1) firewalld  2) ufw  3) iptables  0) 跳过${NC}"
    read -rp "选项： " fw_choice
    [[ "$fw_choice" == "0" ]] && return

    local selected_fw=""
    case $fw_choice in
        1) selected_fw="firewalld" ;; 2) selected_fw="ufw" ;; 3) selected_fw="iptables" ;; *) return ;;
    esac
    
    for fw in firewalld ufw iptables; do 
        [[ "$fw" != "$selected_fw" ]] && { systemctl stop "$fw" 2>/dev/null || true; systemctl disable "$fw" 2>/dev/null || true; }
    done
    
    read -rp "开放端口 (默认含 SSH $RUN_SSH_PORT): " ports
    ports=${ports:-$RUN_SSH_PORT}
    [[ ! "$ports" =~ "$RUN_SSH_PORT" ]] && ports="$ports,$RUN_SSH_PORT"

    if [[ "$selected_fw" == "firewalld" ]]; then
        $PKG_MGR install -y firewalld 2>/dev/null || true
        systemctl enable --now firewalld
        for p in $(echo $ports | tr ',' ' '); do firewall-cmd --permanent --add-port=$p/tcp; done
        firewall-cmd --reload
    elif [[ "$selected_fw" == "ufw" ]]; then
        $PKG_MGR install -y ufw 2>/dev/null || true
        ufw --force reset; ufw default deny incoming
        for p in $(echo $ports | tr ',' ' '); do ufw allow $p/tcp; done
        ufw --force enable
    elif [[ "$selected_fw" == "iptables" ]]; then
        $PKG_MGR install -y iptables-services 2>/dev/null || true
        systemctl enable --now iptables
        iptables -F; iptables -P INPUT DROP
        iptables -A INPUT -i lo -j ACCEPT
        iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        for p in $(echo $ports | tr ',' ' '); do iptables -A INPUT -p tcp --dport $p -j ACCEPT; done
        service iptables save 2>/dev/null || true
    fi
    
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
    log "SUCCESS" "防火墙配置完成。"
}

# ------------------------------------------------------------------------------
# 模块 6, 7, 8: 时间、优化、磁盘
# ------------------------------------------------------------------------------
config_time() {
    log "STEP" "[6/8] 时间同步..."
    if ! ask_confirm "启用 Chrony？"; then return; fi
    $PKG_MGR install -y chrony 2>/dev/null || true
    systemctl enable --now chronyd 2>/dev/null || systemctl enable --now chrony
}

optimize_system() {
    log "STEP" "[7/8] 系统优化..."
    if ! ask_confirm "应用内核优化？"; then return; fi
    local sysctl_file="/etc/sysctl.conf"
    create_backup "$sysctl_file"
    grep -q "vm.swappiness" "$sysctl_file" || echo "vm.swappiness = $DEF_SWAPPINESS" >> "$sysctl_file"
    grep -q "fs.file-max" "$sysctl_file" || echo "fs.file-max = 1000000" >> "$sysctl_file"
    sysctl -p > /dev/null
    local limits_file="/etc/security/limits.conf"
    grep -q "nofile $DEF_FILE_LIMIT" "$limits_file" || cat << EOF >> "$limits_file"
* soft nofile $DEF_FILE_LIMIT
* hard nofile $DEF_FILE_LIMIT
EOF
}

init_disk() {
    log "STEP" "[8/8] 扫描数据盘..."
    local available_disks=()
    while IFS= read -r line; do
        local disk_name=$(echo "$line" | awk '{print $1}')
        local disk_size=$(echo "$line" | awk '{print $2}')
        local disk_type=$(echo "$line" | awk '{print $3}')
        local mount_point=$(echo "$line" | awk '{print $4}')
        if [[ "$disk_type" == "disk" && -z "$mount_point" ]]; then
            local is_mounted=false
            for part in /dev/${disk_name}*; do
                [[ -b "$part" ]] && mount | grep -q "^$part " && { is_mounted=true; break; }
            done
            [[ "$is_mounted" == false ]] && available_disks+=("$disk_name ($disk_size)")
        fi
    done < <(lsblk -ndo NAME,SIZE,TYPE,MOUNTPOINT --paths 2>/dev/null | grep -v "loop\|rom")

    if [[ ${#available_disks[@]} -eq 0 ]]; then
        log "SUCCESS" "无可用数据盘。"
        return 0
    fi

    log "SUCCESS" "发现数据盘："
    for i in "${!available_disks[@]}"; do echo "   $((i+1)). ${available_disks[$i]}"; done

    if ! ask_confirm "是否初始化？"; then return 0; fi

    while true; do
        printf "选择编号 (1-${#available_disks[@]}): "
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#available_disks[@]} )); then
            local selected_disk=$(echo "${available_disks[$((choice-1))]}" | awk '{print $1}' | xargs basename)
            break
        fi
    done

    get_input "设置挂载点" "$DEF_DATA_MOUNT"
    local mnt="$INPUT_RESULT"
    
    if ask_confirm "⚠️ 确认格式化 /dev/$selected_disk？"; then
        mkfs.ext4 -F "/dev/$selected_disk"
        mkdir -p "$mnt"
        local uuid=$(blkid -s UUID -o value "/dev/$selected_disk")
        create_backup "/etc/fstab"
        grep -q "$uuid" /etc/fstab || echo "UUID=$uuid $mnt ext4 defaults 0 0" >> /etc/fstab
        mount -a
        if mount | grep -q "$mnt"; then
            RUN_DATA_MOUNT_INFO="$mnt (/dev/$selected_disk)"
            log "SUCCESS" "挂载成功。"
        fi
    fi
}

# =============================================================================
# 【🏁 主程序 & 总结报告】
# =============================================================================
main() {
    check_root
    detect_os
    mkdir -p "$BACKUP_DIR"
    
    echo -e "${BOLD}${CYAN}==========================================\n   服务器初始化脚本 (v21.0 Enhanced)\n==========================================${NC}"
    log "SUCCESS" "脚本启动。"

    config_network_identity
    config_local_repo
    check_and_install_components
    harden_security
    config_firewall
    config_time
    optimize_system
    init_disk
    
    # ★★★ 配置总结报告 ★★★
    echo -e "\n${BOLD}${GREEN}=========================================="
    echo "   📋 配置变更总结报告"
    echo "==========================================${NC}"
    echo -e "${BOLD}🖥️  主机名:${NC}      $RUN_HOSTNAME"
    echo -e "${BOLD}🌐  IP 模式:${NC}     $RUN_IP_MODE"
    echo -e "${BOLD}🌐  IP 地址:${NC}     $RUN_IP_ADDR"
    echo -e "${BOLD}🚪  网关:${NC}        $RUN_GATEWAY"
    echo -e "${BOLD}📦  组件安装:${NC}    $RUN_COMPONENTS_INSTALLED"
    echo -e "${BOLD}👤  管理员:${NC}      $RUN_ADMIN_USER"
    echo -e "${BOLD}🔑  SSH 端口:${NC}    $RUN_SSH_PORT"
    echo -e "${BOLD}🚫  禁 Root:${NC}     $RUN_DISABLE_ROOT"
    echo -e "${BOLD}🚫  禁密码:${NC}      $RUN_DISABLE_PASS"
    echo -e "${BOLD}💾  数据盘:${NC}      $RUN_DATA_MOUNT_INFO"
    echo -e "${GREEN}==========================================${NC}\n"

    if ask_confirm "是否立即重启？"; then
        log "INFO" "3 秒后重启..."
        sleep 3
        reboot
    else
        log "INFO" "未重启。建议手动 reboot。"
    fi
}

main "$@"
