#!/usr/bin/env bash
#==============================================================================
#  S5 (SOCKS5) 代理一键管理脚本  ——  基于 Dante (danted)
#
#  功能：
#    1. 一键安装 S5 所需依赖（Debian/Ubuntu 用 apt；CentOS/RHEL 自动编译）
#    2. 随机生成 S5（随机端口 + 随机用户名 + 随机密码）
#    3. IP 白名单：可设置“只允许指定 IP 访问”
#    4. 修改端口 / 重新生成账号 / 切换认证方式 / 启停服务 / 卸载
#
#  管理命令：首次运行后，以后在任意位置输入  p-ui  即可打开本菜单
#==============================================================================

set -o pipefail

#-------------------------- 颜色 --------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; PLAIN='\033[0m'
red()    { echo -e "${RED}$1${PLAIN}"; }
green()  { echo -e "${GREEN}$1${PLAIN}"; }
yellow() { echo -e "${YELLOW}$1${PLAIN}"; }
blue()   { echo -e "${BLUE}$1${PLAIN}"; }
cyan()   { echo -e "${CYAN}$1${PLAIN}"; }

#-------------------------- 全局路径 --------------------------
DANTE_CONF="/etc/danted.conf"
S5_INFO="/etc/danted.s5info"           # 保存当前账号/端口信息
WHITELIST_FILE="/etc/danted.whitelist" # 保存白名单 IP（每行一个）
SCRIPT_PATH="/usr/local/bin/p-ui.sh"   # 脚本安装位置
CMD_LINK="/usr/local/bin/p-ui"         # 快捷命令
SERVICE="danted"

#==============================================================================
#  基础工具函数
#==============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        red "请使用 root 用户运行此脚本！（可执行 sudo -i 切换到 root）"
        exit 1
    fi
}

detect_os() {
    if [[ -f /etc/debian_version ]] || grep -qi "debian\|ubuntu" /etc/os-release 2>/dev/null; then
        OS="debian"
    elif grep -qi "centos\|rhel\|rocky\|alma\|fedora" /etc/os-release 2>/dev/null || [[ -f /etc/redhat-release ]]; then
        OS="rhel"
        if command -v dnf &>/dev/null; then PKG_INSTALL="dnf install -y"; else PKG_INSTALL="yum install -y"; fi
    else
        red "暂不支持的系统，仅支持 Debian/Ubuntu 与 CentOS/RHEL 系列"
        exit 1
    fi
}

# 获取默认出口网卡
get_interface() {
    local i
    i=$(ip route get 8.8.8.8 2>/dev/null | grep -oP '(?<=dev )\S+' | head -n1)
    [[ -z "$i" ]] && i=$(ip route show default 2>/dev/null | grep -oP '(?<=dev )\S+' | head -n1)
    [[ -z "$i" ]] && i="eth0"
    echo "$i"
}

# 获取公网 IP（多个来源容错）
get_public_ip() {
    local ip
    ip=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(curl -s4 --max-time 5 https://ipinfo.io/ip 2>/dev/null)
    echo "$ip" | tr -d '[:space:]'
}

# 随机串：rand_str 长度 字符集
rand_lower_digit() { tr -dc 'a-z0-9'      </dev/urandom | head -c "${1:-8}"; }
rand_alnum()       { tr -dc 'A-Za-z0-9'   </dev/urandom | head -c "${1:-16}"; }

# 校验 IPv4 / CIDR
validate_ip() {
    local ip=$1
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || return 1
    # 简单校验每段不超过 255
    local body="${ip%%/*}" seg
    IFS='.' read -r -a seg <<< "$body"
    for s in "${seg[@]}"; do (( s > 255 )) && return 1; done
    return 0
}

#==============================================================================
#  防火墙
#==============================================================================
open_firewall() {
    local port=$1
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qi active; then
        ufw allow "${port}/tcp" >/dev/null 2>&1
    fi
    if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
}
close_firewall() {
    local port=$1
    [[ -z "$port" ]] && return
    command -v ufw &>/dev/null && ufw delete allow "${port}/tcp" >/dev/null 2>&1
    if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
        firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
}

#==============================================================================
#  依赖安装
#==============================================================================
compile_dante() {
    local ver="1.4.3"
    yellow "正在编译安装 Dante ${ver}（约需 1-3 分钟）..."
    cd /tmp || return 1
    wget -q "https://www.inet.no/dante/files/dante-${ver}.tar.gz" -O dante.tar.gz || {
        red "下载 Dante 源码失败，请检查网络或手动修改脚本中的版本号/地址。"; return 1; }
    tar -xf dante.tar.gz
    cd "dante-${ver}" || return 1
    ./configure --prefix=/usr --sysconfdir=/etc \
        --without-libwrap --without-bsdauth --without-gssapi \
        --without-krb5 --without-upnp --without-pac --without-sasl >/dev/null 2>&1
    make >/dev/null 2>&1 && make install >/dev/null 2>&1
    cd /
}

install_deps() {
    if [[ "$OS" == "debian" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y dante-server curl iproute2 2>/dev/null || \
        apt-get install -y dante-server curl
    else
        $PKG_INSTALL epel-release 2>/dev/null
        $PKG_INSTALL gcc make wget tar pam-devel curl iproute 2>/dev/null || \
        $PKG_INSTALL gcc make wget tar pam-devel curl
        command -v sockd &>/dev/null || compile_dante
    fi
}

# PAM：账号密码认证需要。仅在缺失时创建，避免覆盖系统自带配置
ensure_pam() {
    local p
    for p in sockd danted; do
        if [[ ! -f /etc/pam.d/$p ]]; then
            cat > /etc/pam.d/$p <<'EOF'
auth    required pam_unix.so
account required pam_unix.so
EOF
        fi
    done
}

#==============================================================================
#  系统账号（用于 SOCKS5 账号密码认证）
#==============================================================================
create_s5_user() {
    local user=$1 pass=$2 nologin
    id "$user" &>/dev/null && userdel "$user" 2>/dev/null
    nologin=$(command -v nologin || echo /bin/false)
    useradd -M -s "$nologin" "$user" 2>/dev/null
    echo "${user}:${pass}" | chpasswd
}
delete_s5_user() {
    local user=$1
    [[ -n "$user" ]] && id "$user" &>/dev/null && userdel "$user" 2>/dev/null
}

#==============================================================================
#  生成 danted 配置（核心：根据 info + whitelist 重建）
#==============================================================================
generate_config() {
    [[ ! -f "$S5_INFO" ]] && { red "尚未安装"; return 1; }
    # shellcheck disable=SC1090
    source "$S5_INFO"
    local iface; iface=$(get_interface)

    {
        echo "# 由 p-ui 自动生成，请勿手动编辑"
        echo "logoutput: stderr"
        echo "internal: 0.0.0.0 port = ${PORT}"
        echo "external: ${iface}"
        echo "socksmethod: ${AUTH}"          # username = 需账号密码; none = 仅IP白名单
        echo "user.privileged: root"
        echo "user.unprivileged: nobody"
        echo ""
        echo "# ===== 来源 IP 控制（白名单） ====="
        if [[ -s "$WHITELIST_FILE" ]] && grep -qve '^[[:space:]]*$' "$WHITELIST_FILE"; then
            while read -r ip; do
                ip=$(echo "$ip" | tr -d '[:space:]')
                [[ -z "$ip" ]] && continue
                echo "client pass {"
                echo "    from: ${ip} to: 0.0.0.0/0"
                echo "    log: error"
                echo "}"
            done < "$WHITELIST_FILE"
            echo "client block {"
            echo "    from: 0.0.0.0/0 to: 0.0.0.0/0"
            echo "    log: connect error"
            echo "}"
        else
            echo "client pass {"
            echo "    from: 0.0.0.0/0 to: 0.0.0.0/0"
            echo "    log: error"
            echo "}"
        fi
        echo ""
        echo "# ===== 转发规则 ====="
        echo "socks pass {"
        echo "    from: 0.0.0.0/0 to: 0.0.0.0/0"
        echo "    log: connect error"
        echo "}"
    } > "$DANTE_CONF"
}

write_service() {
    local bin; bin=$(command -v danted 2>/dev/null || command -v sockd 2>/dev/null)
    cat > /etc/systemd/system/${SERVICE}.service <<EOF
[Unit]
Description=Dante SOCKS5 Proxy Server (managed by p-ui)
After=network.target

[Service]
Type=simple
ExecStart=${bin} -f ${DANTE_CONF}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

restart_service() {
    systemctl enable ${SERVICE} >/dev/null 2>&1
    systemctl restart ${SERVICE}
    sleep 1
    if systemctl is-active --quiet ${SERVICE}; then
        green "服务运行中 ✔"
    else
        red "服务启动失败！请执行查看日志：journalctl -u ${SERVICE} -n 30 --no-pager"
    fi
}

#==============================================================================
#  各项功能
#==============================================================================
install_s5() {
    detect_os
    if [[ -f "$S5_INFO" ]]; then
        read -rp "检测到已安装 S5，是否重新安装（会重置账号与配置）？[y/N]: " c
        [[ "$c" =~ ^[Yy]$ ]] || return
    fi

    yellow "==> 正在安装依赖，请稍候..."
    install_deps
    if ! command -v danted &>/dev/null && ! command -v sockd &>/dev/null; then
        red "Dante 安装失败，请向上翻查看错误信息。"; return
    fi

    # 随机生成 S5
    local port user pass
    port=$(shuf -i 20000-60000 -n1)
    user="s5$(rand_lower_digit 8)"
    pass="$(rand_alnum 16)"

    cat > "$S5_INFO" <<EOF
PORT=${port}
USERNAME=${user}
PASSWORD=${pass}
AUTH=username
EOF
    chmod 600 "$S5_INFO"
    : > "$WHITELIST_FILE"        # 初始白名单为空 = 允许所有 IP（但需账号密码）
    chmod 600 "$WHITELIST_FILE"

    create_s5_user "$user" "$pass"
    ensure_pam
    write_service
    generate_config
    open_firewall "$port"
    restart_service
    green "==> 安装完成！"
    echo
    show_info
}

show_info() {
    [[ ! -f "$S5_INFO" ]] && { red "尚未安装 S5，请先选择 [1] 安装"; return; }
    # shellcheck disable=SC1090
    source "$S5_INFO"
    local pubip; pubip=$(get_public_ip)
    echo
    cyan "================== S5 代理信息 =================="
    echo -e " 服务器地址 : ${GREEN}${pubip:-<你的服务器公网IP>}${PLAIN}"
    echo -e " 端口       : ${GREEN}${PORT}${PLAIN}"
    if [[ "$AUTH" == "username" ]]; then
        echo -e " 用户名     : ${GREEN}${USERNAME}${PLAIN}"
        echo -e " 密码       : ${GREEN}${PASSWORD}${PLAIN}"
        echo -e " 认证方式   : 账号密码${WHITELIST_FILE:+ + IP白名单}"
    else
        echo -e " 认证方式   : ${YELLOW}仅 IP 白名单（无需账号密码）${PLAIN}"
    fi
    echo " ------------------------------------------------"
    if [[ -s "$WHITELIST_FILE" ]] && grep -qve '^[[:space:]]*$' "$WHITELIST_FILE"; then
        echo " 允许的 IP（白名单）:"
        grep -ve '^[[:space:]]*$' "$WHITELIST_FILE" | sed 's/^/      • /'
    else
        echo -e " IP 白名单  : ${YELLOW}未设置（允许任意 IP 访问）${PLAIN}"
    fi
    echo " ------------------------------------------------"
    if [[ "$AUTH" == "username" && -n "$pubip" ]]; then
        echo -e " 连接串     : ${CYAN}socks5://${USERNAME}:${PASSWORD}@${pubip}:${PORT}${PLAIN}"
        echo -e " 通用格式   : ${CYAN}${pubip}:${PORT}:${USERNAME}:${PASSWORD}${PLAIN}"
    fi
    if systemctl is-active --quiet ${SERVICE}; then
        echo -e " 服务状态   : ${GREEN}运行中 ✔${PLAIN}"
    else
        echo -e " 服务状态   : ${RED}已停止 ✘${PLAIN}"
    fi
    cyan "================================================"
    yellow "提示：若连不上，请确认云服务商【安全组/防火墙】也放行了 ${PORT} 端口(TCP)。"
}

regen_account() {
    [[ ! -f "$S5_INFO" ]] && { red "请先安装"; return; }
    # shellcheck disable=SC1090
    source "$S5_INFO"
    delete_s5_user "$USERNAME"
    local newuser newpass
    newuser="s5$(rand_lower_digit 8)"
    newpass="$(rand_alnum 16)"
    create_s5_user "$newuser" "$newpass"
    sed -i "s/^USERNAME=.*/USERNAME=${newuser}/" "$S5_INFO"
    sed -i "s/^PASSWORD=.*/PASSWORD=${newpass}/" "$S5_INFO"
    green "已重新随机生成账号密码。"
    generate_config
    restart_service
    show_info
}

change_port() {
    [[ ! -f "$S5_INFO" ]] && { red "请先安装"; return; }
    # shellcheck disable=SC1090
    source "$S5_INFO"
    read -rp "请输入新端口 [1-65535]（直接回车随机生成）: " newport
    if [[ -z "$newport" ]]; then
        newport=$(shuf -i 20000-60000 -n1)
        yellow "随机端口：$newport"
    elif ! [[ "$newport" =~ ^[0-9]+$ ]] || (( newport < 1 || newport > 65535 )); then
        red "端口无效"; return
    fi
    close_firewall "$PORT"
    sed -i "s/^PORT=.*/PORT=${newport}/" "$S5_INFO"
    open_firewall "$newport"
    generate_config
    restart_service
    show_info
}

toggle_auth() {
    [[ ! -f "$S5_INFO" ]] && { red "请先安装"; return; }
    # shellcheck disable=SC1090
    source "$S5_INFO"
    if [[ "$AUTH" == "username" ]]; then
        if ! { [[ -s "$WHITELIST_FILE" ]] && grep -qve '^[[:space:]]*$' "$WHITELIST_FILE"; }; then
            red "切换到【仅 IP 白名单】前，必须先添加至少一个白名单 IP，"
            red "否则将变成任何人都能用的【开放代理】，极不安全！请先用菜单 [7] 添加 IP。"
            return
        fi
        sed -i "s/^AUTH=.*/AUTH=none/" "$S5_INFO"
        green "已切换为：仅 IP 白名单（无需账号密码）"
    else
        sed -i "s/^AUTH=.*/AUTH=username/" "$S5_INFO"
        green "已切换为：账号密码认证"
    fi
    generate_config
    restart_service
}

list_whitelist() {
    if [[ -s "$WHITELIST_FILE" ]] && grep -qve '^[[:space:]]*$' "$WHITELIST_FILE"; then
        cyan "当前 IP 白名单（仅这些 IP 可访问）："
        grep -ve '^[[:space:]]*$' "$WHITELIST_FILE" | nl -w2 -s'. ' | sed 's/^/  /'
    else
        yellow "白名单为空 —— 当前允许任意 IP 访问。"
    fi
}

add_whitelist() {
    [[ ! -f "$S5_INFO" ]] && { red "请先安装"; return; }
    read -rp "请输入要允许的 IP 或网段（如 1.2.3.4 或 1.2.3.0/24）: " ip
    ip=$(echo "$ip" | tr -d '[:space:]')
    if ! validate_ip "$ip"; then red "IP/网段格式无效"; return; fi
    [[ "$ip" != */* ]] && ip="${ip}/32"     # 纯 IP 默认 /32
    touch "$WHITELIST_FILE"; chmod 600 "$WHITELIST_FILE"
    if grep -qxF "$ip" "$WHITELIST_FILE"; then
        yellow "该 IP 已存在于白名单"
    else
        echo "$ip" >> "$WHITELIST_FILE"
        green "已添加：$ip"
    fi
    generate_config
    restart_service
    list_whitelist
}

del_whitelist() {
    [[ ! -s "$WHITELIST_FILE" ]] && { yellow "白名单为空"; return; }
    list_whitelist
    read -rp "请输入要删除的 IP（如 1.2.3.4 或 1.2.3.4/32）: " ip
    ip=$(echo "$ip" | tr -d '[:space:]')
    [[ "$ip" != */* ]] && ip="${ip}/32"
    if grep -qxF "$ip" "$WHITELIST_FILE"; then
        grep -vxF "$ip" "$WHITELIST_FILE" > "${WHITELIST_FILE}.tmp" && mv "${WHITELIST_FILE}.tmp" "$WHITELIST_FILE"
        green "已删除：$ip"
        # shellcheck disable=SC1090
        source "$S5_INFO"
        if [[ "$AUTH" == "none" ]] && ! grep -qve '^[[:space:]]*$' "$WHITELIST_FILE"; then
            red "警告：白名单已空且当前为【仅IP模式】→ 现在是开放代理！请添加 IP 或切回账号密码认证。"
        fi
    else
        yellow "白名单中没有该 IP"
    fi
    generate_config
    restart_service
}

clear_whitelist() {
    [[ ! -f "$S5_INFO" ]] && { red "请先安装"; return; }
    # shellcheck disable=SC1090
    source "$S5_INFO"
    if [[ "$AUTH" == "none" ]]; then
        red "当前为【仅 IP 白名单】模式，清空将导致开放代理，已阻止。请先切回账号密码认证。"
        return
    fi
    read -rp "确定清空白名单？（之后允许任意 IP，但仍需账号密码）[y/N]: " c
    [[ "$c" =~ ^[Yy]$ ]] || return
    : > "$WHITELIST_FILE"
    green "白名单已清空"
    generate_config
    restart_service
}

service_ctl() {
    case "$1" in
        start)   systemctl start ${SERVICE};   green "已执行：启动";;
        stop)    systemctl stop ${SERVICE};    green "已执行：停止";;
        restart) restart_service;;
        status)  systemctl status ${SERVICE} --no-pager -l;;
    esac
}

uninstall_s5() {
    read -rp "确定卸载 S5 代理？将停止服务、删除配置与账号 [y/N]: " c
    [[ "$c" =~ ^[Yy]$ ]] || return
    # shellcheck disable=SC1090
    [[ -f "$S5_INFO" ]] && source "$S5_INFO"
    systemctl stop ${SERVICE} 2>/dev/null
    systemctl disable ${SERVICE} 2>/dev/null
    [[ -n "$PORT" ]] && close_firewall "$PORT"
    delete_s5_user "$USERNAME"
    rm -f /etc/systemd/system/${SERVICE}.service
    systemctl daemon-reload
    [[ -f /etc/debian_version ]] && apt-get remove -y dante-server >/dev/null 2>&1
    rm -f "$DANTE_CONF" "$S5_INFO" "$WHITELIST_FILE"
    green "S5 代理已卸载。"
    read -rp "是否同时删除 p-ui 快捷命令与脚本本体？[y/N]: " c2
    if [[ "$c2" =~ ^[Yy]$ ]]; then
        rm -f "$CMD_LINK" "$SCRIPT_PATH"
        green "已删除 p-ui 命令与脚本。再见！"
        exit 0
    fi
}

install_command() {
    if [[ -f "$0" && "$0" != "$SCRIPT_PATH" ]]; then
        cp -f "$0" "$SCRIPT_PATH" 2>/dev/null
    fi
    if [[ -f "$SCRIPT_PATH" ]]; then
        chmod +x "$SCRIPT_PATH"
        ln -sf "$SCRIPT_PATH" "$CMD_LINK"
        chmod +x "$CMD_LINK"
        green "快捷命令已安装！以后在任意位置输入  p-ui  即可打开本菜单。"
    else
        yellow "无法自安装（可能是通过管道运行）。请先把脚本保存为文件再运行一次。"
    fi
}

#==============================================================================
#  菜单
#==============================================================================
show_menu() {
    clear
    local status="未安装"
    if [[ -f "$S5_INFO" ]]; then
        if systemctl is-active --quiet ${SERVICE}; then status="${GREEN}运行中${PLAIN}"; else status="${RED}已停止${PLAIN}"; fi
    fi
    echo -e "${CYAN}╔══════════════════════════════════════════╗${PLAIN}"
    echo -e "${CYAN}║        S5 (SOCKS5) 代理管理面板 · p-ui     ║${PLAIN}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${PLAIN}"
    echo -e "  当前状态： ${status}    快捷命令： ${GREEN}p-ui${PLAIN}"
    echo "------------------------------------------------"
    echo -e "  ${GREEN}1.${PLAIN} 安装 / 重装 S5 代理（含一键装依赖）"
    echo -e "  ${GREEN}2.${PLAIN} 查看 S5 配置信息"
    echo -e "  ${GREEN}3.${PLAIN} 随机重新生成账号密码"
    echo -e "  ${GREEN}4.${PLAIN} 修改端口"
    echo -e "  ${GREEN}5.${PLAIN} 切换认证方式（账号密码 ⇄ 仅IP白名单）"
    echo "  ----------- IP 白名单（只允许指定IP） ----------"
    echo -e "  ${GREEN}6.${PLAIN} 查看白名单"
    echo -e "  ${GREEN}7.${PLAIN} 添加白名单 IP"
    echo -e "  ${GREEN}8.${PLAIN} 删除白名单 IP"
    echo -e "  ${GREEN}9.${PLAIN} 清空白名单（允许所有 IP）"
    echo "  ------------------- 服务管理 -------------------"
    echo -e " ${GREEN}10.${PLAIN} 启动服务   ${GREEN}11.${PLAIN} 停止服务"
    echo -e " ${GREEN}12.${PLAIN} 重启服务   ${GREEN}13.${PLAIN} 查看服务状态"
    echo "  --------------------- 其他 ---------------------"
    echo -e " ${GREEN}14.${PLAIN} 卸载 S5 代理"
    echo -e " ${GREEN}15.${PLAIN} 安装/更新 p-ui 快捷命令"
    echo -e "  ${GREEN}0.${PLAIN} 退出"
    echo "------------------------------------------------"
}

main() {
    check_root
    # 启动时静默安装快捷命令（仅当从真实文件运行且尚未安装时）
    if [[ -f "$0" && "$0" != "$SCRIPT_PATH" && ! -e "$CMD_LINK" ]]; then
        cp -f "$0" "$SCRIPT_PATH" 2>/dev/null && chmod +x "$SCRIPT_PATH" 2>/dev/null \
            && ln -sf "$SCRIPT_PATH" "$CMD_LINK" 2>/dev/null && chmod +x "$CMD_LINK" 2>/dev/null
    fi

    while true; do
        show_menu
        read -rp "请选择 [0-15]: " choice
        case "$choice" in
            1)  install_s5 ;;
            2)  show_info ;;
            3)  regen_account ;;
            4)  change_port ;;
            5)  toggle_auth ;;
            6)  list_whitelist ;;
            7)  add_whitelist ;;
            8)  del_whitelist ;;
            9)  clear_whitelist ;;
            10) service_ctl start ;;
            11) service_ctl stop ;;
            12) service_ctl restart ;;
            13) service_ctl status ;;
            14) uninstall_s5 ;;
            15) install_command ;;
            0)  exit 0 ;;
            *)  red "无效选择，请输入 0-15" ;;
        esac
        echo
        read -rp "按回车键返回菜单..." _
    done
}

main "$@"
