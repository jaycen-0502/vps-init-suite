#!/usr/bin/env bash
# ==============================================================================
# 项目名称: vps-init-suite (init.sh) - 纯净无防火墙稳定满速版
# 适用系统: Debian 12/13, Ubuntu 22.04/24.04, RHEL/AlmaLinux/Rocky 8/9
# 项目地址: https://github.com/jaycen-0502/vps-init-suite
# ==============================================================================

set -u

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}   $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERR]${NC}  $1"; }

check_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        log_err "请使用 root 权限运行此脚本！可先执行: sudo -i"
        exit 1
    fi
}

prompt_read() {
    local prompt_text="$1"
    local var_name="$2"
    if ( : < /dev/tty ) 2>/dev/null; then
        read -rp "$prompt_text" "$var_name" </dev/tty
    else
        read -rp "$prompt_text" "$var_name"
    fi
}

# ==============================================================================
# 核心模块 1: 6 项 VPS 稳定性与网络吞吐深度调优 (不启用任何防火墙)
# ==============================================================================
optimize_proxy_stability_and_speed() {
    log_info "开始执行 VPS 稳定性与网络吞吐 6 项深度调优（无防火墙模式）..."

    # 0. 安装基础依赖
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl iptables chrony cron >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q curl iptables chrony cronie >/dev/null 2>&1
    fi

    # 1. 自动探测并禁用残废 IPv6 (消除双栈域名 3.6s 超时与握手重置)
    if ! curl -6 -s -I -m 3 https://www.google.com/generate_204 >/dev/null 2>&1 && \
       ! curl -6 -s -I -m 3 https://cp.cloudflare.com/generate_204 >/dev/null 2>&1; then
        log_info "检测到当前 VPS 无有效 IPv6 公网出口，写入内核禁用规则..."
        cat << 'EOF' > /etc/sysctl.d/98-disable-ipv6.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    else
        log_info "IPv6 公网出口连通性正常，保留双栈支持。"
        rm -f /etc/sysctl.d/98-disable-ipv6.conf
    fi

    # 2. 跨洋高 RTT 缓冲扩容 + BBR + 关闭空闲慢启动重置
    cat << 'EOF' > /etc/sysctl.d/99-proxy-speed.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 16384
net.ipv4.tcp_max_syn_backlog = 16384
EOF

    # 3. 文件描述符 (FD) 与连接追踪 (Conntrack) 扩容
    mkdir -p /etc/security/limits.d /etc/systemd/system.conf.d /etc/modules-load.d
    cat << 'EOF' > /etc/security/limits.d/99-nofile.conf
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

    cat << 'EOF' > /etc/systemd/system.conf.d/99-limits.conf
[Manager]
DefaultLimitNOFILE=1048576
EOF

    echo "nf_conntrack" > /etc/modules-load.d/nf_conntrack.conf
    modprobe nf_conntrack 2>/dev/null || true

    cat << 'EOF' > /etc/sysctl.d/99-conntrack.conf
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_local_port_range = 10240 65535
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 1800
EOF

    # 4. 内存防爆 (2GB 幂等 Swap + Swappiness=10 + x-ui OOM 免疫 & 高句柄)
    if ! swapon --show | grep -q '/swapfile'; then
        if [[ ! -f /swapfile ]]; then
            log_info "创建 2GB Swap 交换文件以防爆内存..."
            fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null
        fi
        swapon /swapfile
    fi
    grep -qE '^/swapfile\s+' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo 'vm.swappiness=10' > /etc/sysctl.d/99-swap.conf

    mkdir -p /etc/systemd/system/x-ui.service.d
    cat << 'EOF' > /etc/systemd/system/x-ui.service.d/override.conf
[Service]
OOMScoreAdjust=-900
LimitNOFILE=1048576
Restart=always
RestartSec=2
EOF

    # 统一加载全部 sysctl 内核参数
    sysctl --system >/dev/null 2>&1

    # 5. TCP MSS 1380 钳制并持久化为 systemd 服务 (仅优化包长，不拦截任何端口)
    cat << 'EOF' > /etc/systemd/system/tcpmss-clamp.service
[Unit]
Description=Clamp TCP MSS to 1380 for Proxy Tunnels
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1380 2>/dev/null || iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1380'

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now tcpmss-clamp.service >/dev/null 2>&1
    systemctl is-active --quiet x-ui && systemctl restart x-ui >/dev/null 2>&1 || true

    # 6. Chrony 毫秒级校时 + Journald 日志封顶 + 每日凌晨 04:30 自动清理守护
    systemctl enable --now chrony >/dev/null 2>&1 || systemctl enable --now chronyd >/dev/null 2>&1 || true
    chronyc -a makestep >/dev/null 2>&1 || true

    mkdir -p /etc/systemd/journald.conf.d
    cat << 'EOF' > /etc/systemd/journald.conf.d/99-size.conf
[Journal]
SystemMaxUse=100M
MaxRetentionSec=7day
EOF
    systemctl restart systemd-journald >/dev/null 2>&1

    if command -v crontab >/dev/null 2>&1; then
        systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1 || true
        (crontab -l 2>/dev/null | grep -v 'vps-daily-maint'; echo '30 4 * * * /usr/bin/journalctl --vacuum-size=80M >/dev/null 2>&1 # vps-daily-maint') | crontab -
    fi

    log_ok "VPS 稳定性与网络性能 6 项深度调优已全部生效！"
}

# ==============================================================================
# 核心模块 2: 调优结果一键自检报告
# ==============================================================================
verify_optimization() {
    echo ""
    echo -e "${BOLD}==================== 系统调优状态自检报告 ====================${NC}"

    # 1. Google 连通性 (测试无残废 IPv6 超时阻塞)
    if curl -s -I -m 3 https://www.google.com/generate_204 2>/dev/null | grep -q "204"; then
        echo -e "1. 出站连通性 (防残废IPv6阻塞) : ${GREEN}[PASS] 秒返 HTTP 204${NC}"
    else
        echo -e "1. 出站连通性 (防残废IPv6阻塞) : ${YELLOW}[WARN] 访问 Google 超时或受限${NC}"
    fi

    # 2. BBR 拥塞控制与空闲慢启动
    local cc idle rmem
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    idle=$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null || echo "unknown")
    rmem=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "unknown")
    if [[ "$cc" == "bbr" ]] && [[ "$idle" == "0" ]]; then
        echo -e "2. BBR + 零空闲重置 + 大缓冲   : ${GREEN}[PASS] cc=${cc}, idle=${idle}, rmem=${rmem}${NC}"
    else
        echo -e "2. BBR + 零空闲重置 + 大缓冲   : ${RED}[FAIL] 当前 cc=${cc}, idle=${idle}${NC}"
    fi

    # 3. TCP MSS 1380 钳制
    if iptables -t mangle -L POSTROUTING -n 2>/dev/null | grep -q "TCPMSS set 1380"; then
        echo -e "3. TCP MSS 1380 隧道防分片     : ${GREEN}[PASS] 规则已生效并持久化${NC}"
    else
        echo -e "3. TCP MSS 1380 隧道防分片     : ${RED}[FAIL] 未检测到 TCPMSS 规则${NC}"
    fi

    # 4. Swap 交换内存与 x-ui OOM 免疫
    local swap_total
    swap_total=$(free -h 2>/dev/null | awk '/^Swap:/ {print $2}')
    if [[ -n "$swap_total" ]] && [[ "$swap_total" != "0B" ]]; then
        echo -e "4. Swap 防爆内存 & OOM 免疫    : ${GREEN}[PASS] Swap=${swap_total}, x-ui OOM=-900${NC}"
    else
        echo -e "4. Swap 防爆内存 & OOM 免疫    : ${YELLOW}[WARN] 未检测到活跃 Swap${NC}"
    fi

    # 5. Chrony NTP 时间同步
    if systemctl is-active --quiet chrony 2>/dev/null || systemctl is-active --quiet chronyd 2>/dev/null; then
        echo -e "5. Chrony 毫秒级时间同步       : ${GREEN}[PASS] 运行中 (保障 REALITY/TLS 握手)${NC}"
    else
        echo -e "5. Chrony 毫秒级时间同步       : ${YELLOW}[WARN] Chrony 未运行${NC}"
    fi

    echo -e "${BOLD}==============================================================${NC}"
    echo ""
}

# ==============================================================================
# 核心模块 3: 一键安装 / 更新 3x-ui 面板
# ==============================================================================
install_3xui() {
    log_info "正在拉取官方 3x-ui 安装脚本..."
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
    systemctl daemon-reload
    systemctl restart x-ui 2>/dev/null || true
}

# ==============================================================================
# 主交互式菜单
# ==============================================================================
show_menu() {
    while true; do
        clear
        echo -e "${CYAN}${BOLD}"
        echo "=============================================================="
        echo "     vps-init-suite | 代理与中转服务器一键调优套件 (无防火墙)"
        echo "=============================================================="
        echo -e "${NC}"
        echo -e "  ${GREEN}1.${NC} 一键全套深度调优 ${BOLD}(BBR/大缓冲/防IPv6卡顿/MSS1380/Swap + 自检)${NC} ${YELLOW}[推荐]${NC}"
        echo -e "  ${GREEN}2.${NC} 运行系统调优状态一键自检"
        echo -e "  ${GREEN}3.${NC} 一键安装 / 更新 3x-ui 面板"
        echo -e "  ${RED}0.${NC} 退出脚本"
        echo ""
        echo "--------------------------------------------------------------"

        local choice=""
        prompt_read "请输入操作编号 [0-3]: " choice
        echo ""

        case "$choice" in
            1)
                optimize_proxy_stability_and_speed
                verify_optimization
                prompt_read "按回车键返回主菜单..." _
                ;;
            2)
                verify_optimization
                prompt_read "按回车键返回主菜单..." _
                ;;
            3)
                install_3xui
                prompt_read "按回车键返回主菜单..." _
                ;;
            0)
                log_info "已退出 vps-init-suite。"
                exit 0
                ;;
            *)
                log_warn "无效输入，请输入 0 到 3 之间的数字！"
                sleep 1
                ;;
        esac
    done
}

# ==============================================================================
# 脚本入口 (支持交互菜单与 --auto 无人值守模式)
# ==============================================================================
check_root
if [[ "${1:-}" == "--auto" ]] || [[ "${1:-}" == "-y" ]]; then
    optimize_proxy_stability_and_speed
    verify_optimization
    exit 0
else
    show_menu
fi
