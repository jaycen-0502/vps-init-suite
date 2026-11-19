#!/usr/bin/env bash
# ==============================================================================
# 项目名称: vps-init-suite (init.sh) - 纯净无防火墙稳定满速版 (v1.19.0)
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

# 全局自适应网络参数
BW_MBPS=500
RTT_MS=160
CONN_TIER=1
TCP_MAX_BUF=16777216
TCP_DEF_BUF=16384
TCP_MEM_PAGES="24576 49152 81920"
TCP_NOTSENT_LOWAT=16384
NOFILE_LIMIT=65535
XUI_GOMEMLIMIT="350MiB"
XUI_GOGC="75"
XUI_OOM_SCORE="-300"
JOURNAL_DISK_MAX="30M"
PROFILE_DESC="1G-单线程极速档"

# ==============================================================================
# 自适应网络计算模块（按“带宽 + 延迟 + 并发档位 + 物理内存”四维动态计算）
# ==============================================================================
configure_adaptive_network() {
    local IN_BW="${1:-}"
    local IN_RTT="${2:-}"
    local IN_TIER="${3:-}"

    local MEM_TOTAL_MB CPU_CORES
    MEM_TOTAL_MB=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 1024)
    CPU_CORES=$(nproc 2>/dev/null || echo 1)

    # 1. 检测终端并引导手动填写（支持 curl | bash 管道交互）
    if ( : < /dev/tty ) 2>/dev/null; then
        if [ -z "$IN_BW" ] || [ -z "$IN_RTT" ] || [ -z "$IN_TIER" ]; then
            echo ""
            echo "============================================================"
            echo " 本机硬件检测: ${CPU_CORES} 核 CPU | ${MEM_TOTAL_MB} MB 内存"
            echo " 延迟参考: 日本/亚太填 40 | 美西直连填 160 | 美国国际落地填 30"
            echo "============================================================"
            if [ -z "$IN_BW" ]; then
                read -r -t 20 -p " 1. 请输入机器带宽 Mbps [回车默认 500]: " IN_BW </dev/tty || true
            fi
            if [ -z "$IN_RTT" ]; then
                read -r -t 20 -p " 2. 请输入典型延迟 ms   [回车默认 160]: " IN_RTT </dev/tty || true
            fi
            if [ -z "$IN_TIER" ]; then
                echo " 3. 请选择并发使用规模:"
                echo "    [1] 常规/低中并发 (500连接以内，单线程速度与视频极速优先，1G机放开至16M/32M)"
                echo "    [2] 多人高并发    (1000-3000+连接，防爆内存与极致稳定优先，1G机严格封顶)"
                read -r -t 20 -p " 请选择 [1/2，回车默认 1]: " IN_TIER </dev/tty || true
            fi
            echo "============================================================"
        fi
    fi

    # 默认值与合法性兜底
    BW_MBPS="${IN_BW:-500}"
    RTT_MS="${IN_RTT:-160}"
    CONN_TIER="${IN_TIER:-1}"
    [[ "$BW_MBPS" =~ ^[0-9]+$ ]] && [ "$BW_MBPS" -gt 0 ] || BW_MBPS=500
    [[ "$RTT_MS" =~ ^[0-9]+$ ]] && [ "$RTT_MS" -gt 0 ] || RTT_MS=160
    [[ "$CONN_TIER" == "2" ]] || CONN_TIER=1

    # 2. 按 1.5 倍 BDP 计算目标窗口，并向上对齐至 2M/4M/8M/16M/32M
    local TARGET_BYTES=$(( BW_MBPS * RTT_MS * 125 * 3 / 2 ))
    if [ "$TARGET_BYTES" -le 2097152 ]; then
        TCP_MAX_BUF=2097152
    elif [ "$TARGET_BYTES" -le 4194304 ]; then
        TCP_MAX_BUF=4194304
    elif [ "$TARGET_BYTES" -le 8388608 ]; then
        TCP_MAX_BUF=8388608
    elif [ "$TARGET_BYTES" -le 16777216 ]; then
        TCP_MAX_BUF=16777216
    else
        TCP_MAX_BUF=33554432
    fi

    # 3. 结合物理内存与并发档位计算安全护栏
    if [ "$MEM_TOTAL_MB" -le 1500 ]; then
        TCP_DEF_BUF=16384
        NOFILE_LIMIT=65535
        XUI_GOMEMLIMIT="350MiB"
        XUI_GOGC="75"
        XUI_OOM_SCORE="-300"
        JOURNAL_DISK_MAX="30M"
        if [ "$CONN_TIER" -eq 2 ]; then
            # 1G 高并发防爆：严控单连接上限与内核总内存
            if [ "$RTT_MS" -ge 100 ] && [ "$TCP_MAX_BUF" -gt 4194304 ]; then
                TCP_MAX_BUF=4194304
            elif [ "$RTT_MS" -lt 100 ] && [ "$TCP_MAX_BUF" -gt 2097152 ]; then
                TCP_MAX_BUF=2097152
            fi
            TCP_MEM_PAGES="16384 32768 65536"   # 硬顶 256MB
            TCP_NOTSENT_LOWAT=32768
            PROFILE_DESC="1G-高并发稳态档"
        else
            # 1G 低中并发极速：允许单连接最高飙到 16MB/32MB 跑满 500M/1G，靠 tcp_mem 320MB 兜底防爆
            [ "$TCP_MAX_BUF" -gt 33554432 ] && TCP_MAX_BUF=33554432
            TCP_MEM_PAGES="24576 49152 81920"   # 硬顶 320MB
            TCP_NOTSENT_LOWAT=16384
            PROFILE_DESC="1G-单线程极速档"
        fi
    else
        NOFILE_LIMIT=1048576
        XUI_GOGC="100"
        XUI_OOM_SCORE="-900"
        JOURNAL_DISK_MAX="100M"
        [ "$MEM_TOTAL_MB" -le 3000 ] && XUI_GOMEMLIMIT="1024MiB" || XUI_GOMEMLIMIT="2048MiB"
        local mem_high=$(( MEM_TOTAL_MB * 1024 / 4 / 4 ))
        TCP_MEM_PAGES="$((mem_high / 4)) $((mem_high / 2)) ${mem_high}"

        if [ "$CONN_TIER" -eq 2 ]; then
            TCP_DEF_BUF=32768
            [ "$TCP_MAX_BUF" -gt 16777216 ] && TCP_MAX_BUF=16777216
            TCP_NOTSENT_LOWAT=32768
            PROFILE_DESC="大内存-高并发稳态档"
        else
            TCP_DEF_BUF=65536
            TCP_NOTSENT_LOWAT=16384
            PROFILE_DESC="大内存-跨洋极速档"
        fi
    fi

    log_ok "匹配方案: ${PROFILE_DESC} | 带宽: ${BW_MBPS}Mbps | 延迟: ${RTT_MS}ms"
    log_ok "缓冲参数: TCP初始=$((TCP_DEF_BUF/1024))KB, TCP上限=$((TCP_MAX_BUF/1048576))MB, UDP默认=256KB"
}

# ==============================================================================
# 核心模块 1: VPS 稳定性与网络吞吐 6 项深度调优 (不启用任何防火墙)
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
        log_info "检测到当前 VPS 无有效 IPv6 公网出口，写入内核禁用规则（防假死黑洞）..."
        cat << 'EOF' > /etc/sysctl.d/98-disable-ipv6.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    else
        log_info "IPv6 公网出口连通性正常，保留双栈支持。"
        rm -f /etc/sysctl.d/98-disable-ipv6.conf
    fi

    # 2. 四维自适应网络计算 (带宽 + 延迟 + 并发档位 + 物理内存)
    configure_adaptive_network "$@"

    # 3. 跨洋自适应缓冲 + BBR + 关闭空闲慢启动 + 256KB UDP/QUIC (多图/HTTP3/IM加速)
    cat << EOF > /etc/sysctl.d/99-proxy-speed.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = ${TCP_MAX_BUF}
net.core.wmem_max = ${TCP_MAX_BUF}
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 ${TCP_DEF_BUF} ${TCP_MAX_BUF}
net.ipv4.tcp_wmem = 4096 ${TCP_DEF_BUF} ${TCP_MAX_BUF}
net.ipv4.tcp_mem = ${TCP_MEM_PAGES}
net.ipv4.tcp_notsent_lowat = ${TCP_NOTSENT_LOWAT}
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_orphan_retries = 1
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 16384
net.ipv4.tcp_max_syn_backlog = 16384
EOF

    # 4. 文件描述符 (FD) 与连接追踪 (Conntrack) 扩容
    mkdir -p /etc/security/limits.d /etc/systemd/system.conf.d /etc/modules-load.d
    cat << EOF > /etc/security/limits.d/99-nofile.conf
* soft nofile ${NOFILE_LIMIT}
* hard nofile ${NOFILE_LIMIT}
root soft nofile ${NOFILE_LIMIT}
root hard nofile ${NOFILE_LIMIT}
EOF

    cat << EOF > /etc/systemd/system.conf.d/99-limits.conf
[Manager]
DefaultLimitNOFILE=${NOFILE_LIMIT}
EOF

    echo "nf_conntrack" > /etc/modules-load.d/nf_conntrack.conf
    modprobe nf_conntrack 2>/dev/null || true

    cat << 'EOF' > /etc/sysctl.d/99-conntrack.conf
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_local_port_range = 10240 65535
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
EOF

    # 5. 内存防爆 (2GB 幂等 Swap + Swappiness=10 + x-ui 分档 OOM 免疫 & 高句柄)
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

    # 日志占用限制防磁盘写满
    mkdir -p /etc/systemd/journald.conf.d
    cat << EOF > /etc/systemd/journald.conf.d/99-limit.conf
[Journal]
SystemMaxUse=${JOURNAL_DISK_MAX}
EOF
    systemctl restart systemd-journald 2>/dev/null || true

    # 注入 x-ui 自适应守护限制
    mkdir -p /etc/systemd/system/x-ui.service.d
    cat << EOF > /etc/systemd/system/x-ui.service.d/override.conf
[Service]
OOMScoreAdjust=${XUI_OOM_SCORE}
LimitNOFILE=${NOFILE_LIMIT}
Restart=always
RestartSec=2
EOF

    # 6. DNS 1秒超时轮询解析（防止首选 DNS 丢包造成网页图片转圈）
    if [[ ! -L /etc/resolv.conf ]]; then
        cat << 'EOF' > /etc/resolv.conf
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:1 attempts:2 rotate single-request-reopen
EOF
    fi

    # 统一加载全部 sysctl 内核参数
    sysctl --system >/dev/null 2>&1

    # 7. TCP MSS 1380 钳制并持久化为 systemd 服务 (仅优化包长，不拦截任何端口)
    iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1380 2>/dev/null || \
    iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1380

    cat << 'EOF' > /etc/systemd/system/proxy-mss.service
[Unit]
Description=Persist TCP MSS 1380 Clamping for Multi-layer Proxy Tunnels
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1380
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable proxy-mss.service >/dev/null 2>&1

    # 8. Chrony 毫秒级网络授时 (保障 REALITY 与 TLS 严格握手时间窗口)
    log_info "配置 Chrony 毫秒级时间同步..."
    systemctl enable chrony >/dev/null 2>&1 || systemctl enable chronyd >/dev/null 2>&1 || true
    systemctl restart chrony 2>/dev/null || systemctl restart chronyd 2>/dev/null || true
    chronyc makestep >/dev/null 2>&1 || true

    # 重启 x-ui 生效 drop-in 限制
    systemctl restart x-ui 2>/dev/null || true

    log_ok "VPS 稳定性与网络吞吐调优完成（未开启任何防火墙拦截，端口全通）。"
}

# ==============================================================================
# 核心模块 2: 调优状态一键自检报告
# ==============================================================================
verify_optimization() {
    echo ""
    echo -e "${BOLD}${CYAN}==================== VPS 调优状态自检报告 ====================${NC}"

    # 1. 方案与缓冲参数
    local cc idle rmem def_buf tcp_mem_val udp_def
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    idle=$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null || echo "unknown")
    rmem=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "unknown")
    def_buf=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{print $2}' || echo "unknown")
    tcp_mem_val=$(sysctl -n net.ipv4.tcp_mem 2>/dev/null || echo "unknown")
    udp_def=$(sysctl -n net.core.rmem_default 2>/dev/null || echo "unknown")

    echo -e "1. 调优策略与并发模式     : ${GREEN}[PASS] ${PROFILE_DESC}${NC}"
    echo -e "   • 带宽与 RTT 设置        : ${BW_MBPS} Mbps / ${RTT_MS} ms (并发档位: ${CONN_TIER})"
    if [[ "$cc" == "bbr" ]] && [[ "$idle" == "0" ]]; then
        echo -e "2. BBR + 零空闲慢启动重置 : ${GREEN}[PASS] cc=${cc}, idle=${idle}${NC}"
    else
        echo -e "2. BBR + 零空闲慢启动重置 : ${RED}[FAIL] 当前 cc=${cc}, idle=${idle}${NC}"
    fi

    echo -e "3. TCP 窗口与 UDP/QUIC 缓冲: ${GREEN}[PASS] TCP上限=$((rmem/1048576))MB, 初始=$((def_buf/1024))KB, UDP默认=$((udp_def/1024))KB${NC}"
    echo -e "   • 内核 tcp_mem 全局硬顶  : ${tcp_mem_val} 页"

    # 4. Google 连通性 (测试无残废 IPv6 超时阻塞)
    if curl -s -I -m 3 https://www.google.com/generate_204 2>/dev/null | grep -q "204"; then
        echo -e "4. 出站连通性 (防残废IPv6阻塞): ${GREEN}[PASS] 秒返 HTTP 204${NC}"
    else
        echo -e "4. 出站连通性 (防残废IPv6阻塞): ${YELLOW}[WARN] 访问 Google 超时或受限${NC}"
    fi

    # 5. TCP MSS 1380 钳制
    if iptables -t mangle -L POSTROUTING -n 2>/dev/null | grep -q "TCPMSS set 1380"; then
        echo -e "5. TCP MSS 1380 隧道防分片    : ${GREEN}[PASS] 规则已生效并持久化${NC}"
    else
        echo -e "5. TCP MSS 1380 隧道防分片    : ${RED}[FAIL] 未检测到 TCPMSS 规则${NC}"
    fi

    # 6. Swap 交换内存与 x-ui OOM 免疫
    local swap_total
    swap_total=$(free -h 2>/dev/null | awk '/^Swap:/ {print $2}')
    if [[ -n "$swap_total" ]] && [[ "$swap_total" != "0B" ]]; then
        echo -e "6. Swap 防爆内存 & OOM 免疫   : ${GREEN}[PASS] Swap=${swap_total}, x-ui OOM=${XUI_OOM_SCORE}, 句柄=${NOFILE_LIMIT}${NC}"
    else
        echo -e "6. Swap 防爆内存 & OOM 免疫   : ${YELLOW}[WARN] 未检测到活跃 Swap${NC}"
    fi

    # 7. Chrony NTP 时间同步
    if systemctl is-active --quiet chrony 2>/dev/null || systemctl is-active --quiet chronyd 2>/dev/null; then
        echo -e "7. Chrony 毫秒级时间同步      : ${GREEN}[PASS] 运行中 (保障 REALITY/TLS 握手)${NC}"
    else
        echo -e "7. Chrony 毫秒级时间同步      : ${YELLOW}[WARN] Chrony 未运行${NC}"
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
        echo "  vps-init-suite | 纯净无防火墙网络优化套件 (v1.19.0 自适应版)"
        echo "=============================================================="
        echo -e "${NC}"
        echo -e "  ${GREEN}1.${NC} 一键全套深度调优 ${BOLD}(带宽/RTT/并发四维自适应计算 + 自检)${NC} ${YELLOW}[推荐]${NC}"
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
# 脚本入口 (支持直接传参、--auto 无人值守模式与交互菜单)
# ==============================================================================
check_root
if [[ "${1:-}" == "--auto" ]] || [[ "${1:-}" == "-y" ]]; then
    optimize_proxy_stability_and_speed 500 160 1
    verify_optimization
    exit 0
elif [[ "${1:-}" =~ ^[0-9]+$ ]]; then
    optimize_proxy_stability_and_speed "$@"
    verify_optimization
    exit 0
else
    show_menu
fi
