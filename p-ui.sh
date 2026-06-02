#!/usr/bin/env bash
#==============================================================================
#  S5 (SOCKS5) 多实例管理脚本  ——  基于 Dante (danted)
#
#  特点：一台多 IP 服务器，可创建【多个独立 S5】，每个 S5 各自：
#        · 独立端口  · 独立账号密码  · 绑定一个指定的出口 IP
#  即：客户端连 IP1:端口 → 从 IP1 出网；连 IP2:端口 → 从 IP2 出网。
#
#  管理命令：首次运行后，在任意位置输入  p-ui  即可打开菜单。
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
P_DIR="/etc/p-ui"                      # 所有实例的信息/配置/白名单都放这里
SCRIPT_PATH="/usr/local/bin/p-ui.sh"
CMD_LINK="/usr/local/bin/p-ui"

# 每个实例 id 对应的文件/服务名
info_file() { echo "$P_DIR/s5-$1.info"; }
wl_file()   { echo "$P_DIR/s5-$1.whitelist"; }
conf_file() { echo "$P_DIR/danted-$1.conf"; }
svc_name()  { echo "danted-s5-$1"; }

#==============================================================================
#  基础工具
#==============================================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        red "请使用 root 用户运行此脚本！（可执行 sudo -i 切换到 root）"; exit 1
    fi
}

detect_os() {
    if [[ -f /etc/debian_version ]] || grep -qi "debian\|ubuntu" /etc/os-release 2>/dev/null; then
        OS="debian"
    elif grep -qi "centos\|rhel\|rocky\|alma\|fedora" /etc/os-release 2>/dev/null || [[ -f /etc/redhat-release ]]; then
        OS="rhel"
        if command -v dnf &>/dev/null; then PKG_INSTALL="dnf install -y"; else PKG_INSTALL="yum install -y"; fi
    else
        red "暂不支持的系统，仅支持 Debian/Ubuntu 与 CentOS/RHEL 系列"; exit 1
    fi
}

# 列出本机所有全局 IPv4（含附加/第二 IP），用于选出口 IP
get_local_ips() {
    ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1
}

rand_lower_digit() { tr -dc 'a-z0-9'    </dev/urandom | head -c "${1:-8}"; }
rand_alnum()       { tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-16}"; }

validate_ip() {
    local ip=$1
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || return 1
    local body="${ip%%/*}" seg
    IFS='.' read -r -a seg <<< "$body"
    for s in "${seg[@]}"; do (( s > 255 )) && return 1; done
    return 0
}

# 读取某实例信息字段：get_field <id> <FIELD>
get_field() { grep "^$2=" "$(info_file "$1")" 2>/dev/null | head -n1 | cut -d= -f2-; }

list_ids() { ls "$P_DIR"/s5-*.info 2>/dev/null | sed -E 's#.*/s5-([0-9]+)\.info#\1#' | sort -n; }
next_id()  { local m=0 i; for i in $(list_ids); do (( i > m )) && m=$i; done; echo $(( m + 1 )); }

# 检查 IP:端口 是否已被其它实例占用，占用则输出其 id 并返回 0
socket_in_use() {
    local e=$1 p=$2 ex=$3 i
    for i in $(list_ids); do
        [[ "$i" == "$ex" ]] && continue
        if [[ "$(get_field "$i" EXT_IP)" == "$e" && "$(get_field "$i" PORT)" == "$p" ]]; then
            echo "$i"; return 0
        fi
    done
    return 1
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
    local port=$1; [[ -z "$port" ]] && return
    # 端口可能被其它实例共用，仅当没有别的实例还在用它时才删
    local i
    for i in $(list_ids); do
        [[ "$(get_field "$i" PORT)" == "$port" ]] && return
    done
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
        red "下载 Dante 源码失败，请检查网络。"; return 1; }
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
#  系统账号（SOCKS5 账号密码认证用）
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
#  生成单个实例的 danted 配置（核心：external 绑定该实例的出口 IP）
#==============================================================================
generate_config() {
    local id=$1
    local inf; inf=$(info_file "$id")
    [[ ! -f "$inf" ]] && return 1
    # shellcheck disable=SC1090
    source "$inf"                 # 读入 PORT USERNAME PASSWORD AUTH EXT_IP
    local wl; wl=$(wl_file "$id")
    local cf; cf=$(conf_file "$id")

    {
        echo "# S5 实例 #${id} 由 p-ui 生成，出口IP=${EXT_IP}，请勿手动编辑"
        echo "logoutput: stderr"
        echo "internal: ${EXT_IP} port = ${PORT}"   # 只在本实例的 IP 上监听
        echo "external: ${EXT_IP}"                   # 关键：从这个 IP 出网
        echo "socksmethod: ${AUTH}"                  # username=账号密码; none=仅IP白名单
        echo "user.privileged: root"
        echo "user.unprivileged: nobody"
        echo ""
        echo "# ===== 来源 IP 控制（白名单） ====="
        if [[ -s "$wl" ]] && grep -qve '^[[:space:]]*$' "$wl"; then
            while read -r ip; do
                ip=$(echo "$ip" | tr -d '[:space:]'); [[ -z "$ip" ]] && continue
                echo "client pass {"
                echo "    from: ${ip} to: 0.0.0.0/0"
                echo "    log: error"
                echo "}"
            done < "$wl"
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
    } > "$cf"
}

write_service() {
    local id=$1
    local bin; bin=$(command -v danted 2>/dev/null || command -v sockd 2>/dev/null)
    local svc; svc=$(svc_name "$id")
    local cf;  cf=$(conf_file "$id")
    cat > "/etc/systemd/system/${svc}.service" <<EOF
[Unit]
Description=Dante SOCKS5 #${id} (managed by p-ui)
After=network.target

[Service]
Type=simple
ExecStart=${bin} -f ${cf}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

restart_service() {
    local id=$1 svc; svc=$(svc_name "$id")
    systemctl enable "$svc" >/dev/null 2>&1
    systemctl restart "$svc"
    sleep 1
    if systemctl is-active --quiet "$svc"; then
        green "实例 #${id} 运行中 ✔"
    else
        red "实例 #${id} 启动失败！查看日志：journalctl -u ${svc} -n 30 --no-pager"
    fi
}

#==============================================================================
#  实例操作
#==============================================================================
ensure_installed() {
    detect_os
    if ! command -v danted &>/dev/null && ! command -v sockd &>/dev/null; then
        yellow "首次使用，正在安装依赖..."
        install_deps; ensure_pam
        if ! command -v danted &>/dev/null && ! command -v sockd &>/dev/null; then
            red "Dante 安装失败，请向上翻查看错误信息。"; return 1
        fi
        # 关掉发行版自带（以及旧版单实例）默认服务，避免端口冲突/混淆
        systemctl disable --now danted >/dev/null 2>&1
    fi
    return 0
}

add_s5() {
    ensure_installed || return

    echo; cyan "本机可用的全局 IP（可作为出口 IP）："
    local ips; ips=$(get_local_ips)
    if [[ -z "$ips" ]]; then red "未检测到全局 IP"; return; fi
    echo "$ips" | nl -w2 -s'. ' | sed 's/^/   /'
    echo

    local extip
    read -rp "请输入该 S5 的出口 IP（从上面选一个）: " extip
    extip=$(echo "$extip" | tr -d '[:space:]')
    validate_ip "$extip" || { red "IP 格式无效"; return; }
    if ! echo "$ips" | grep -qxF "$extip"; then
        yellow "注意：$extip 不在本机已绑定的 IP 列表里，若未绑定将无法工作。"
        read -rp "仍要继续？[y/N]: " c; [[ "$c" =~ ^[Yy]$ ]] || return
    fi

    local port
    read -rp "请输入端口（回车随机；不同 IP 可用相同端口）: " port
    if [[ -z "$port" ]]; then
        port=$(shuf -i 20000-60000 -n1); yellow "随机端口：$port"
    elif ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        red "端口无效"; return
    fi
    local dup; if dup=$(socket_in_use "$extip" "$port"); then
        red "${extip}:${port} 已被实例 #${dup} 占用，请换端口或换 IP"; return
    fi

    local id user pass
    id=$(next_id)
    user="s5$(rand_lower_digit 8)"
    pass="$(rand_alnum 16)"

    cat > "$(info_file "$id")" <<EOF
PORT=${port}
USERNAME=${user}
PASSWORD=${pass}
AUTH=username
EXT_IP=${extip}
EOF
    chmod 600 "$(info_file "$id")"
    : > "$(wl_file "$id")"; chmod 600 "$(wl_file "$id")"

    create_s5_user "$user" "$pass"
    ensure_pam
    write_service "$id"
    generate_config "$id"
    open_firewall "$port"
    restart_service "$id"
    green "==> 新的 S5 实例 #${id} 创建完成！"
    show_s5 "$id"
}

show_s5() {
    local id=$1
    [[ -f "$(info_file "$id")" ]] || { red "实例 #$id 不存在"; return; }
    (   # 子shell 读取展示，避免变量泄漏
        source "$(info_file "$id")"
        svc=$(svc_name "$id")
        echo; cyan "============= S5 实例 #${id} ============="
        echo -e " 出口/服务器 IP : ${GREEN}${EXT_IP}${PLAIN}"
        echo -e " 端口           : ${GREEN}${PORT}${PLAIN}"
        if [[ "$AUTH" == "username" ]]; then
            echo -e " 用户名         : ${GREEN}${USERNAME}${PLAIN}"
            echo -e " 密码           : ${GREEN}${PASSWORD}${PLAIN}"
            echo -e " 认证方式       : 账号密码"
            echo -e " 连接串         : ${CYAN}socks5://${USERNAME}:${PASSWORD}@${EXT_IP}:${PORT}${PLAIN}"
            echo -e " 通用格式       : ${CYAN}${EXT_IP}:${PORT}:${USERNAME}:${PASSWORD}${PLAIN}"
        else
            echo -e " 认证方式       : ${YELLOW}仅 IP 白名单（无需账号密码）${PLAIN}"
        fi
        wl=$(wl_file "$id")
        if [[ -s "$wl" ]] && grep -qve '^[[:space:]]*$' "$wl"; then
            echo " 白名单："; grep -ve '^[[:space:]]*$' "$wl" | sed 's/^/    • /'
        else
            echo -e " 白名单         : ${YELLOW}未设置（任意 IP）${PLAIN}"
        fi
        if systemctl is-active --quiet "$svc"; then
            echo -e " 服务状态       : ${GREEN}运行中 ✔${PLAIN}"
        else
            echo -e " 服务状态       : ${RED}已停止 ✘${PLAIN}"
        fi
        cyan "========================================="
    )
}

list_s5() {
    local ids; ids=$(list_ids)
    if [[ -z "$ids" ]]; then yellow "还没有任何 S5 实例，请先用菜单 [1] 添加。"; return; fi
    cyan "──────────────── 所有 S5 实例 ────────────────"
    printf " %-4s %-18s %-8s %-8s %s\n" "ID" "出口IP" "端口" "状态" "认证"
    local i
    for i in $ids; do
        (   source "$(info_file "$i")"
            svc=$(svc_name "$i")
            if systemctl is-active --quiet "$svc"; then st="运行中"; else st="停止"; fi
            printf " %-4s %-18s %-8s %-8s %s\n" "$i" "$EXT_IP" "$PORT" "$st" "$AUTH"
        )
    done
    cyan "──────────────────────────────────────────────"
    yellow "查看某实例完整连接信息：菜单 [3] 输入对应 ID"
}

pick_id() {
    local ids; ids=$(list_ids)
    [[ -z "$ids" ]] && { yellow "还没有任何实例，请先用菜单 [1] 添加。"; return 1; }
    list_s5
    read -rp "${1:-请输入实例 ID}: " PICKED_ID
    PICKED_ID=$(echo "$PICKED_ID" | tr -d '[:space:]')
    [[ -f "$(info_file "$PICKED_ID")" ]] || { red "实例 #${PICKED_ID} 不存在"; return 1; }
    return 0
}

regen_account() {
    pick_id "请输入要重置账号密码的实例 ID" || return
    local id="$PICKED_ID" inf; inf=$(info_file "$id")
    # shellcheck disable=SC1090
    source "$inf"
    delete_s5_user "$USERNAME"
    local nu np; nu="s5$(rand_lower_digit 8)"; np="$(rand_alnum 16)"
    create_s5_user "$nu" "$np"
    sed -i "s/^USERNAME=.*/USERNAME=${nu}/" "$inf"
    sed -i "s/^PASSWORD=.*/PASSWORD=${np}/" "$inf"
    generate_config "$id"; restart_service "$id"
    green "实例 #${id} 账号密码已重新生成。"; show_s5 "$id"
}

change_port() {
    pick_id "请输入要修改端口的实例 ID" || return
    local id="$PICKED_ID" inf; inf=$(info_file "$id")
    local old extip; old=$(get_field "$id" PORT); extip=$(get_field "$id" EXT_IP)
    local np
    read -rp "新端口 [1-65535]（回车随机）: " np
    if [[ -z "$np" ]]; then np=$(shuf -i 20000-60000 -n1); yellow "随机端口：$np"
    elif ! [[ "$np" =~ ^[0-9]+$ ]] || (( np < 1 || np > 65535 )); then red "端口无效"; return; fi
    local dup; if dup=$(socket_in_use "$extip" "$np" "$id"); then
        red "${extip}:${np} 已被实例 #${dup} 占用"; return; fi
    sed -i "s/^PORT=.*/PORT=${np}/" "$inf"
    open_firewall "$np"; close_firewall "$old"
    generate_config "$id"; restart_service "$id"
    show_s5 "$id"
}

toggle_auth() {
    pick_id "请输入要切换认证方式的实例 ID" || return
    local id="$PICKED_ID" inf; inf=$(info_file "$id"); local wl; wl=$(wl_file "$id")
    local auth; auth=$(get_field "$id" AUTH)
    if [[ "$auth" == "username" ]]; then
        if ! { [[ -s "$wl" ]] && grep -qve '^[[:space:]]*$' "$wl"; }; then
            red "切到【仅 IP 白名单】前，必须先给该实例添加至少一个白名单 IP，"
            red "否则会变成任何人都能用的开放代理！请先用菜单 [7] 添加 IP。"
            return
        fi
        sed -i "s/^AUTH=.*/AUTH=none/" "$inf"; green "实例 #${id} → 仅 IP 白名单"
    else
        sed -i "s/^AUTH=.*/AUTH=username/" "$inf"; green "实例 #${id} → 账号密码认证"
    fi
    generate_config "$id"; restart_service "$id"
}

#----------------------- 白名单（按实例） -----------------------
wl_list() {
    local id=$1 wl; wl=$(wl_file "$id")
    if [[ -s "$wl" ]] && grep -qve '^[[:space:]]*$' "$wl"; then
        echo " 当前白名单（仅这些 IP 可访问）："
        grep -ve '^[[:space:]]*$' "$wl" | nl -w2 -s'. ' | sed 's/^/   /'
    else
        yellow " 白名单为空 —— 当前允许任意 IP 访问。"
    fi
}
wl_add() {
    local id=$1 wl; wl=$(wl_file "$id")
    local ip; read -rp "请输入要允许的 IP 或网段（如 1.2.3.4 或 1.2.3.0/24）: " ip
    ip=$(echo "$ip" | tr -d '[:space:]')
    validate_ip "$ip" || { red "IP/网段格式无效"; return; }
    [[ "$ip" != */* ]] && ip="${ip}/32"
    touch "$wl"; chmod 600 "$wl"
    if grep -qxF "$ip" "$wl"; then yellow "该 IP 已存在"; else echo "$ip" >> "$wl"; green "已添加：$ip"; fi
    generate_config "$id"; restart_service "$id"
}
wl_del() {
    local id=$1 wl; wl=$(wl_file "$id")
    [[ -s "$wl" ]] || { yellow "白名单为空"; return; }
    local ip; read -rp "请输入要删除的 IP（如 1.2.3.4）: " ip
    ip=$(echo "$ip" | tr -d '[:space:]'); [[ "$ip" != */* ]] && ip="${ip}/32"
    if grep -qxF "$ip" "$wl"; then
        grep -vxF "$ip" "$wl" > "${wl}.tmp" && mv "${wl}.tmp" "$wl"; green "已删除：$ip"
        if [[ "$(get_field "$id" AUTH)" == "none" ]] && ! grep -qve '^[[:space:]]*$' "$wl"; then
            red "警告：该实例为【仅IP模式】且白名单已空 → 现在是开放代理！请加 IP 或切回账号密码。"
        fi
    else yellow "白名单中没有该 IP"; fi
    generate_config "$id"; restart_service "$id"
}
wl_clear() {
    local id=$1 wl; wl=$(wl_file "$id")
    if [[ "$(get_field "$id" AUTH)" == "none" ]]; then
        red "当前为【仅 IP 白名单】模式，清空会变开放代理，已阻止。请先切回账号密码。"; return
    fi
    read -rp "确定清空该实例白名单？（之后允许任意 IP，但仍需账号密码）[y/N]: " c
    [[ "$c" =~ ^[Yy]$ ]] || return
    : > "$wl"; green "白名单已清空"
    generate_config "$id"; restart_service "$id"
}
whitelist_menu() {
    pick_id "请输入要管理白名单的实例 ID" || return
    local id="$PICKED_ID"
    while true; do
        echo; cyan "──── 实例 #${id} 白名单管理 ────"
        wl_list "$id"
        echo "  1.添加   2.删除   3.清空   0.返回"
        read -rp "选择: " a
        case "$a" in
            1) wl_add "$id" ;;
            2) wl_del "$id" ;;
            3) wl_clear "$id" ;;
            0) break ;;
            *) red "无效选择" ;;
        esac
    done
}

del_s5() {
    pick_id "请输入要删除的实例 ID" || return
    local id="$PICKED_ID"
    read -rp "确定删除实例 #${id}？将停止服务、删除配置与账号 [y/N]: " c
    [[ "$c" =~ ^[Yy]$ ]] || return
    local user port svc
    user=$(get_field "$id" USERNAME); port=$(get_field "$id" PORT); svc=$(svc_name "$id")
    systemctl stop "$svc" 2>/dev/null; systemctl disable "$svc" 2>/dev/null
    delete_s5_user "$user"
    rm -f "/etc/systemd/system/${svc}.service" "$(conf_file "$id")" "$(info_file "$id")" "$(wl_file "$id")"
    systemctl daemon-reload
    close_firewall "$port"     # 删完后若没人再用该端口则关闭
    green "实例 #${id} 已删除。"
}

#----------------------- 服务管理 -----------------------
service_menu() {
    echo; cyan "──────── 服务管理 ────────"
    echo "  1.重启全部  2.停止全部  3.启动全部"
    echo "  4.操作单个  5.查看单个状态   0.返回"
    read -rp "选择: " a
    local i
    case "$a" in
        1) for i in $(list_ids); do restart_service "$i"; done ;;
        2) for i in $(list_ids); do systemctl stop "$(svc_name "$i")"; done; green "已停止全部" ;;
        3) for i in $(list_ids); do systemctl start "$(svc_name "$i")"; done; green "已启动全部" ;;
        4) pick_id "操作哪个实例 ID" || return
           echo "  1.启动  2.停止  3.重启"; read -rp "选择: " b
           local svc; svc=$(svc_name "$PICKED_ID")
           case "$b" in
               1) systemctl start "$svc"; green "已启动" ;;
               2) systemctl stop "$svc";  green "已停止" ;;
               3) restart_service "$PICKED_ID" ;;
               *) red "无效" ;;
           esac ;;
        5) pick_id "查看哪个实例 ID" || return
           systemctl status "$(svc_name "$PICKED_ID")" --no-pager -l ;;
        0) return ;;
        *) red "无效选择" ;;
    esac
}

uninstall_all() {
    read -rp "确定卸载【全部】S5 实例？（依赖可选保留）[y/N]: " c
    [[ "$c" =~ ^[Yy]$ ]] || return
    local i user svc
    for i in $(list_ids); do
        user=$(get_field "$i" USERNAME); svc=$(svc_name "$i")
        systemctl stop "$svc" 2>/dev/null; systemctl disable "$svc" 2>/dev/null
        delete_s5_user "$user"
        rm -f "/etc/systemd/system/${svc}.service" "$(conf_file "$i")" "$(info_file "$i")" "$(wl_file "$i")"
    done
    systemctl daemon-reload
    green "全部 S5 实例已卸载。"
    read -rp "是否同时卸载 Dante 依赖（dante-server）？[y/N]: " c2
    if [[ "$c2" =~ ^[Yy]$ ]]; then
        [[ -f /etc/debian_version ]] && apt-get remove -y dante-server >/dev/null 2>&1
        green "依赖已移除。"
    fi
    read -rp "是否同时删除 p-ui 快捷命令与脚本本体？[y/N]: " c3
    if [[ "$c3" =~ ^[Yy]$ ]]; then
        rm -rf "$P_DIR"; rm -f "$CMD_LINK" "$SCRIPT_PATH"
        green "已删除 p-ui 命令与脚本。再见！"; exit 0
    fi
}

install_command() {
    if [[ -f "$0" && "$0" != "$SCRIPT_PATH" ]]; then
        cp -f "$0" "$SCRIPT_PATH" 2>/dev/null
    fi
    if [[ -f "$SCRIPT_PATH" ]]; then
        chmod +x "$SCRIPT_PATH"; ln -sf "$SCRIPT_PATH" "$CMD_LINK"; chmod +x "$CMD_LINK"
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
    local n; n=$(list_ids | wc -l | tr -d ' ')
    echo -e "${CYAN}╔══════════════════════════════════════════╗${PLAIN}"
    echo -e "${CYAN}║   多IP · S5(SOCKS5) 多实例管理面板 · p-ui  ║${PLAIN}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${PLAIN}"
    echo -e "  已创建实例数： ${GREEN}${n}${PLAIN}     快捷命令： ${GREEN}p-ui${PLAIN}"
    echo "------------------------------------------------"
    echo -e "  ${GREEN}1.${PLAIN} 添加一个新的 S5（绑定指定出口 IP）"
    echo -e "  ${GREEN}2.${PLAIN} 查看所有 S5 实例"
    echo -e "  ${GREEN}3.${PLAIN} 查看某个 S5 的连接信息"
    echo -e "  ${GREEN}4.${PLAIN} 重新生成某个 S5 的账号密码"
    echo -e "  ${GREEN}5.${PLAIN} 修改某个 S5 的端口"
    echo -e "  ${GREEN}6.${PLAIN} 切换某个 S5 的认证方式（账密 ⇄ 仅IP）"
    echo -e "  ${GREEN}7.${PLAIN} 白名单管理（指定实例）"
    echo -e "  ${GREEN}8.${PLAIN} 服务管理（启停 / 重启）"
    echo -e "  ${GREEN}9.${PLAIN} 删除某个 S5"
    echo "  ------------------------------------------------"
    echo -e " ${GREEN}10.${PLAIN} 卸载全部（含依赖/脚本，可选）"
    echo -e " ${GREEN}11.${PLAIN} 安装/更新 p-ui 快捷命令"
    echo -e "  ${GREEN}0.${PLAIN} 退出"
    echo "------------------------------------------------"
    [[ "$n" == "0" ]] && yellow "  首次使用：选 [1] 添加，会自动安装依赖。"
}

main() {
    check_root
    mkdir -p "$P_DIR"
    # 启动时静默安装快捷命令（仅当从真实文件运行且尚未安装时）
    if [[ -f "$0" && "$0" != "$SCRIPT_PATH" && ! -e "$CMD_LINK" ]]; then
        cp -f "$0" "$SCRIPT_PATH" 2>/dev/null && chmod +x "$SCRIPT_PATH" 2>/dev/null \
            && ln -sf "$SCRIPT_PATH" "$CMD_LINK" 2>/dev/null && chmod +x "$CMD_LINK" 2>/dev/null
    fi

    while true; do
        show_menu
        read -rp "请选择 [0-11]: " choice
        case "$choice" in
            1)  add_s5 ;;
            2)  list_s5 ;;
            3)  pick_id "查看哪个实例 ID" && show_s5 "$PICKED_ID" ;;
            4)  regen_account ;;
            5)  change_port ;;
            6)  toggle_auth ;;
            7)  whitelist_menu ;;
            8)  service_menu ;;
            9)  del_s5 ;;
            10) uninstall_all ;;
            11) install_command ;;
            0)  exit 0 ;;
            *)  red "无效选择，请输入 0-11" ;;
        esac
        echo
        read -rp "按回车键返回菜单..." _
    done
}

main "$@"
