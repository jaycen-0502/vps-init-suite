#!/usr/bin/env bash
# Managed by vps-init-suite.

set -Eeuo pipefail

readonly SCRIPT_VERSION="1.10.9"
readonly REPO_SLUG="jaycen-0502/vps-init-suite"
readonly LAUNCHER_NAME="vps-init"
readonly INSTALL_DIR="/usr/local/lib/vps-init-suite"
readonly INSTALLED_SCRIPT="${INSTALL_DIR}/setup.sh"
readonly LAUNCHER_PATH="/usr/local/bin/${LAUNCHER_NAME}"
readonly SYSCTL_FILE="/etc/sysctl.d/99-vps-init-suite.conf"
readonly SYSCTL_UNIT="/etc/systemd/system/vps-init-suite-sysctl.service"
readonly SWAP_SYSCTL_FILE="/etc/sysctl.d/99-vps-init-suite-swap.conf"
readonly SWAP_FILE="/swapfile-vps-init-suite"
readonly MSS_CONFIG="/etc/default/vps-init-suite"
readonly TUNING_CONFIG="/etc/default/vps-init-suite-tuning"
readonly MSS_HELPER="/usr/local/lib/vps-init-suite/apply-mss.sh"
readonly MSS_UNIT="/etc/systemd/system/vps-init-suite-mss.service"
readonly MSS_TIMER="/etc/systemd/system/vps-init-suite-mss.timer"
readonly SYSTEMD_TIMEOUT_FILE="/etc/systemd/system.conf.d/90-vps-init-suite-timeout.conf"
readonly XUI_LIMITS_DIR="/etc/systemd/system/x-ui.service.d"
readonly XUI_LIMITS_FILE="${XUI_LIMITS_DIR}/90-vps-init-suite.conf"
readonly STATE_DIR="/var/lib/vps-init-suite/state"
readonly ORIGINAL_SYSCTL_STATE="${STATE_DIR}/initial-sysctl.conf"
readonly XUI_BACKUP_ROOT="/var/lib/vps-init-suite/backups/3xui"
readonly XUI_POLICY_HELPER="${INSTALL_DIR}/xui-policy.py"
readonly XUI_POLICY_HELPER_VERSION="1.8.0"
ZONEINFO_DIR="/usr/share/zoneinfo"
readonly ROOT_COMMANDS=(full kernel ipv6 conntrack bandwidth mss swap timezone install select menu uninstall remove uninstall-3xui xui-policy xray-policy update upgrade)
readonly CONFLICT_FILES=(
  99-custom-net.conf 99-cyberverse.conf 99-gost.conf 99-joeyblog.conf
  99-network-bbr.conf 99-optimal-proxy.conf 99-tcp-custom.conf
  99-tfo.conf 99-japan-vps.conf 99-us-vps.conf 99-vps-tuning.conf
)

if [[ -t 1 ]]; then
  readonly RED=$'\033[31m'
  readonly GREEN=$'\033[32m'
  readonly YELLOW=$'\033[33m'
  readonly RESET=$'\033[0m'
else
  readonly RED="" GREEN="" YELLOW="" RESET=""
fi

APT_UPDATED=0
XUI_POLICY_SERVICE_STOPPED=0

log() { printf '%s\n' "${GREEN}$*${RESET}"; }
warn() { printf '%s\n' "${YELLOW}$*${RESET}" >&2; }
run_with_timeout() {
  local seconds=$1
  shift
  command -v timeout >/dev/null 2>&1 || return 127
  timeout --signal=TERM "${seconds}s" "$@"
}
run_timedatectl() {
  local seconds=${1:-5}
  shift || true
  run_with_timeout "$seconds" timedatectl "$@"
}
github_raw_url() {
  local path=$1
  printf 'https://raw.githubusercontent.com/%s/main/%s?cache=%s-%s\n' \
    "$REPO_SLUG" "$path" "$(date +%s)" "$RANDOM"
}
die() {
  # Never leave 3X-UI stopped if an explicit error exits this script.
  if (( XUI_POLICY_SERVICE_STOPPED )); then
    systemctl start x-ui.service >/dev/null 2>&1 || true
    XUI_POLICY_SERVICE_STOPPED=0
  fi
  printf '%s\n' "${RED}Error: $*${RESET}" >&2
  exit 1
}

assert_not_symlink() {
  [[ ! -L "$1" ]] || die "Refusing to write through symlink ${1}; inspect or remove it first."
}

on_error() {
  local exit_code=$?
  if (( XUI_POLICY_SERVICE_STOPPED )); then
    systemctl start x-ui.service >/dev/null 2>&1 || true
    XUI_POLICY_SERVICE_STOPPED=0
  fi
  printf '%s\n' "${RED}Failed at line ${BASH_LINENO[0]} (exit ${exit_code}).${RESET}" >&2
  exit "$exit_code"
}
trap on_error ERR

require_root() {
  [[ ${EUID} -eq 0 ]] || die "Run this command as root (for example: sudo ./setup.sh full)."
}

is_root_command() {
  local command=$1 candidate
  for candidate in "${ROOT_COMMANDS[@]}"; do
    [[ "$command" == "$candidate" ]] && return 0
  done
  return 1
}

reexec_as_root() {
  command -v sudo >/dev/null || die "This command needs root privileges. Install sudo or run as root."
  local source_path=${BASH_SOURCE[0]}
  local executable="$INSTALLED_SCRIPT"
  if [[ -f "$source_path" && "$source_path" != "/dev/stdin" ]]; then
    executable=$(readlink -f -- "$source_path")
  fi
  [[ -f "$executable" ]] || die "Cannot locate the script for privilege escalation. Run the downloaded script with sudo."
  exec sudo -E "$executable" "$@"
}

require_supported_os() {
  [[ -r /etc/os-release ]] || die "Cannot identify this Linux distribution."
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *) die "Supported systems: Debian 11+ and Ubuntu 20.04+. Found: ${ID:-unknown}." ;;
  esac
  command -v systemctl >/dev/null || die "systemd is required."
  command -v apt-get >/dev/null || die "apt-get is required."
}

package_is_installed() {
  local status
  command -v dpkg-query >/dev/null 2>&1 || return 1
  status=$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) || return 1
  [[ "$status" == "install ok installed" ]]
}

apt_install() {
  local package
  local -a missing=()
  for package in "$@"; do
    if ! package_is_installed "$package"; then
      missing+=("$package")
    fi
  done
  ((${#missing[@]} == 0)) && return 0
  if [[ $APT_UPDATED -eq 0 ]]; then
    # Wait for unattended apt jobs instead of failing on the transient dpkg lock.
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=60 update -y
    APT_UPDATED=1
  fi
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=60 install -y --no-install-recommends "${missing[@]}"
}

backup_existing() {
  local path=$1
  [[ -e "$path" ]] || return 0
  local backup_dir
  backup_dir="/var/lib/vps-init-suite/backups/$(date +%Y%m%d-%H%M%S-%N)"
  mkdir -p "$backup_dir"
  cp -a "$path" "$backup_dir/$(basename "$path")"
  warn "Backed up ${path} to ${backup_dir}."
}

capture_original_sysctl_state() {
  [[ -e "$ORIGINAL_SYSCTL_STATE" ]] && return 0
  [[ -e "${STATE_DIR}/initial-sysctl-unavailable" ]] && return 0
  if is_suite_managed_file "$INSTALLED_SCRIPT"; then
    mkdir -p "$STATE_DIR"
    : >"${STATE_DIR}/initial-sysctl-unavailable"
    warn "An older suite installation already exists; its original runtime sysctl values were not recorded, so uninstall will not guess them."
    return 0
  fi
  local key value
  local keys=(
    net.core.default_qdisc
    net.ipv4.tcp_congestion_control net.ipv4.tcp_fastopen
    net.core.rmem_max net.core.wmem_max net.core.rmem_default net.core.wmem_default
    net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.ip_forward
    net.ipv6.conf.all.forwarding net.ipv6.conf.default.forwarding
    net.ipv6.conf.all.accept_ra net.ipv6.conf.default.accept_ra
    net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6 net.ipv6.conf.lo.disable_ipv6
    net.ipv4.tcp_sack net.ipv4.tcp_dsack net.ipv4.tcp_window_scaling
    net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_moderate_rcvbuf net.ipv4.tcp_mtu_probing
    net.ipv4.tcp_timestamps net.ipv4.tcp_tw_reuse
    net.core.somaxconn net.core.netdev_max_backlog net.ipv4.tcp_max_syn_backlog
    net.ipv4.tcp_syncookies net.ipv4.tcp_max_tw_buckets net.ipv4.tcp_fin_timeout
    net.ipv4.ip_local_port_range net.ipv4.tcp_keepalive_time
    net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes
    net.netfilter.nf_conntrack_max net.netfilter.nf_conntrack_tcp_timeout_established
    fs.file-max fs.nr_open vm.swappiness
  )
  mkdir -p "$STATE_DIR"
  : >"$ORIGINAL_SYSCTL_STATE"
  chmod 0600 "$ORIGINAL_SYSCTL_STATE"
  for key in "${keys[@]}"; do
    if value=$(sysctl -n "$key" 2>/dev/null); then
      printf '%s = %s\n' "$key" "$value" >>"$ORIGINAL_SYSCTL_STATE"
    fi
  done
}

capture_original_managed_file() {
  local path=$1
  local state_dir=${2:-$STATE_DIR}
  local filename marker original
  filename=$(basename "$path")
  marker="${state_dir}/original-${filename}.present"
  original="${state_dir}/original-${filename}"
  mkdir -p "$state_dir"
  if [[ -e "$marker" ]]; then
    # Older builds could snapshot the suite's own file as if it were user data.
    if [[ -e "$original" ]] && is_suite_managed_file "$original"; then
      rm -f -- "$marker" "$original"
      : >"${state_dir}/original-${filename}.absent"
    fi
    return 0
  fi
  [[ -e "${state_dir}/original-${filename}.absent" ]] && return 0
  if [[ -e "$path" ]] && ! is_suite_managed_file "$path"; then
    cp -a -- "$path" "$original"
    : >"$marker"
  else
    : >"${state_dir}/original-${filename}.absent"
  fi
}

is_suite_managed_file() {
  [[ -f "$1" ]] || return 1
  local filename
  filename=$(basename "$1")
  grep -qFx '# Managed by vps-init-suite.' "$1" ||
    grep -qF 'jaycen-0502/vps-init-suite' "$1" ||
    case "$filename" in
      vps-init-suite.conf) grep -qx 'tcp_bbr' "$1" ;;
      vps-init-suite) grep -q '^MSS_MODE=' "$1" ;;
      vps-init-suite-mss.service) grep -qF 'Apply vps-init-suite TCP MSS policy' "$1" ;;
      vps-init-suite-mss.timer) grep -qF 'Apply vps-init-suite TCP MSS policy after boot' "$1" ;;
      vps-init-suite-sysctl.service) grep -qF 'Apply vps-init-suite kernel parameters' "$1" ;;
      90-vps-init-suite-timeout.conf) grep -qF 'DefaultTimeoutStopSec=10s' "$1" ;;
      apply-mss.sh) grep -qF '/etc/default/vps-init-suite' "$1" ;;
      xui-policy.py) grep -qF 'SETTING_KEY = "xrayTemplateConfig"' "$1" ;;
      *) return 1 ;;
    esac
}

find_latest_unmanaged_backup() {
  local filename=$1 backup_root=${2:-/var/lib/vps-init-suite/backups}
  local candidates backup
  [[ -d "$backup_root" ]] || return 0
  candidates=$(find "$backup_root" -type f -name "$filename" -print 2>/dev/null | sort -r || true)
  while IFS= read -r backup; do
    [[ -n "$backup" ]] || continue
    if ! is_suite_managed_file "$backup"; then
      printf '%s\n' "$backup"
      return 0
    fi
  done <<<"$candidates"
}

show_status() {
  local timezone="unavailable"
  local swap="none"
  local mss="not configured"
  local xui_nofile="未检测到 x-ui.service"
  local xui_pid
  local tuning_bandwidth tuning_rtt mss_mode mss_value mss_value6 ipv4_mss ipv6_mss

  if command -v timedatectl >/dev/null; then
    timezone=$(run_timedatectl 2 show --property=Timezone --value 2>/dev/null || true)
  fi
  if [[ -z "$timezone" || "$timezone" == "unavailable" ]]; then
    if [[ -r /etc/timezone ]]; then
      timezone=$(sed -n '1p' /etc/timezone)
    elif [[ -L /etc/localtime ]]; then
      timezone=$(readlink -f /etc/localtime | sed 's#^/usr/share/zoneinfo/##')
    fi
  fi
  if command -v swapon >/dev/null && [[ -n $(swapon --show=NAME --noheadings 2>/dev/null) ]]; then
    swap=$(free -h | awk '/^Swap:/ {print $2 " total, " $3 " used"}')
  fi
  if [[ -r "$MSS_CONFIG" ]]; then
    mss_mode=$(awk -F= '$1 == "MSS_MODE" {print $2; exit}' "$MSS_CONFIG")
    mss_value=$(awk -F= '$1 == "MSS_VALUE" {print $2; exit}' "$MSS_CONFIG")
    mss_value6=$(awk -F= '$1 == "MSS_VALUE6" {print $2; exit}' "$MSS_CONFIG")
    ipv4_mss=$(mss_family_status iptables "$mss_mode" "$mss_value" "$mss_value6")
    ipv6_mss=$(mss_family_status ip6tables "$mss_mode" "$mss_value" "$mss_value6")
    mss="${mss_mode:-unknown} (IPv4: ${ipv4_mss}, IPv6: ${ipv6_mss})"
  fi
  if xui_service_detected && command -v systemctl >/dev/null; then
    xui_pid=$(run_with_timeout 3 systemctl show x-ui.service --property=MainPID --value 2>/dev/null || true)
    if [[ "$xui_pid" =~ ^[1-9][0-9]*$ && -r "/proc/${xui_pid}/limits" ]]; then
      xui_nofile=$(awk '$1 == "Max" && $2 == "open" && $3 == "files" {print $4}' "/proc/${xui_pid}/limits")
      [[ -n "$xui_nofile" ]] || xui_nofile="未读取"
    else
      xui_nofile="未运行（下次启动配置：$(run_with_timeout 3 systemctl show x-ui.service --property=LimitNOFILE --value 2>/dev/null || echo 未读取)）"
    fi
  fi
  tuning_bandwidth=$(tuning_value BANDWIDTH_MBPS 2>/dev/null || true)
  tuning_rtt=$(tuning_value RTT_MS 2>/dev/null || true)
  [[ -n "$tuning_bandwidth" ]] || tuning_bandwidth="未设置"
  [[ -n "$tuning_rtt" ]] || tuning_rtt="未设置"

  printf '%s\n' "------------------------------------------------------------"
  printf '版本:                    %s\n' "$SCRIPT_VERSION"
  printf '快捷命令:                %s\n' "$LAUNCHER_NAME"
  if [[ -x "$LAUNCHER_PATH" ]]; then
    printf '快捷命令状态:            已安装\n'
  else
    printf '快捷命令状态:            未安装\n'
  fi
  printf '拥塞控制:                %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unavailable)"
  printf '默认队列:                %s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unavailable)"
  printf 'TCP Fast Open:           %s（目标值: 0，默认关闭）\n' "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo unavailable)"
  printf 'TCP MTU 探测:            %s（目标值: 1）\n' "$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo unavailable)"
  printf 'TCP 监听队列:            %s（SYN: %s）\n' "$(sysctl -n net.core.somaxconn 2>/dev/null || echo unavailable)" "$(sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null || echo unavailable)"
  printf 'TCP Keepalive:           %s/%s/%s 秒\n' "$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null || echo unavailable)" "$(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null || echo unavailable)" "$(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null || echo unavailable)"
  printf 'IPv4 转发:               %s\n' "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo unavailable)"
  printf 'IPv6 转发:               %s\n' "$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo unavailable)"
  printf 'IPv6 状态:               %s\n' "$(if [[ "$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo 0)" == "1" ]]; then printf '%s' 已开启; else printf '%s' 已关闭; fi)"
  printf 'TCP 缓冲上限:            %s 字节\n' "$(sysctl -n net.core.rmem_max 2>/dev/null || echo unavailable)"
  printf '带宽/RTT 缓冲档位:       %s Mbps / %s ms\n' "$tuning_bandwidth" "$tuning_rtt"
  printf 'Swap 倾向:               %s\n' "$(sysctl -n vm.swappiness 2>/dev/null || echo unavailable)"
  printf '时区:                    %s\n' "${timezone:-未知}"
  printf 'Swap:                    %s\n' "$swap"
  printf 'MSS 策略:                %s\n' "${mss:-未配置}"
  printf 'Conntrack:               %s\n' "$(if [[ -r /proc/sys/net/netfilter/nf_conntrack_max ]]; then printf '已加载 (%s/%s)' "$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo '?')" "$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo '?')"; else printf '%s' 未加载; fi)"
  printf 'x-ui 文件句柄上限:       %s\n' "$xui_nofile"
  printf '%s\n' "------------------------------------------------------------"
}

diagnose_system() {
  printf '%s\n' '================ VPS CPU/网络诊断 ================'
  printf '%s\n' '--- 进程 CPU（优先看 xray / ksoftirqd）---'
  ps -eLo pid,tid,psr,pcpu,pmem,comm --sort=-pcpu 2>/dev/null | head -n 18 || true
  printf '%s\n' '--- CPU 时间（us 用户态 / sy 内核态 / st 宿主机 steal）---'
  if command -v vmstat >/dev/null 2>&1; then
    vmstat 1 3
  else
    printf '%s\n' 'vmstat 不可用（未安装 procps）。'
  fi
  printf '%s\n' '--- Xray 进程（不显示启动参数）---'
  if pgrep -x xray >/dev/null 2>&1; then
    ps -C xray -o pid,pcpu,pmem,etime,comm --sort=-pcpu 2>/dev/null || true
  else
    printf '%s\n' '未发现 xray 进程。'
  fi
  printf '%s\n' '--- Socket 总览 ---'
  if command -v ss >/dev/null 2>&1; then
    ss -s
  else
    printf '%s\n' 'ss 不可用（未安装 iproute2）。'
  fi
  printf '%s\n' '--- TCP 重传/队列计数（累计值）---'
  if command -v nstat >/dev/null 2>&1; then
    nstat -az 2>/dev/null | grep -E 'TcpRetransSegs|TcpTimeouts|TCPFastRetrans|TCPRcvQDrop|ListenOverflows|ListenDrops' || true
  else
    printf '%s\n' 'nstat 不可用（可安装 iproute2 后重试）。'
  fi
  printf '%s\n' '--- Conntrack ---'
  if [[ -r /proc/sys/net/netfilter/nf_conntrack_count ]]; then
    printf 'count=%s max=%s\n' "$(cat /proc/sys/net/netfilter/nf_conntrack_count)" "$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo '?')"
  else
    printf '%s\n' '未加载 conntrack。'
  fi
  printf '%s\n' '--- 网卡/队列丢包统计 ---'
  if command -v ip >/dev/null 2>&1; then
    ip -s link 2>/dev/null | sed -n '/^[0-9].*: /,/^[0-9].*: /p' | head -n 80 || true
  fi
  if command -v tc >/dev/null 2>&1; then
    tc -s qdisc show 2>/dev/null || true
  fi
  printf '%s\n' '================================================='
}

tune_kernel() {
  require_root
  require_supported_os
  local ipv6_mode requested_ipv6 conntrack_mode requested_conntrack
  local requested_bandwidth requested_rtt
  requested_ipv6=${1:-}
  requested_conntrack=${2:-${VPS_CONNTRACK:-auto}}
  requested_bandwidth=${3:-}
  requested_rtt=${4:-}
  if [[ -t 0 ]]; then
    prompt_missing_tuning_profile requested_bandwidth requested_rtt
  fi

  assert_not_symlink "$SYSCTL_FILE"
  assert_not_symlink "$SYSCTL_UNIT"
  assert_not_symlink /etc/modules-load.d/vps-init-suite.conf
  apt_install kmod procps

  if [[ -z "$requested_ipv6" ]] && [[ -r /proc/sys/net/ipv6/conf/all/forwarding ]]; then
    requested_ipv6=$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || true)
    [[ "$requested_ipv6" == "1" ]] && requested_ipv6=on || requested_ipv6=off
  fi
  ipv6_mode=$(resolve_ipv6_mode "$requested_ipv6")

  conntrack_mode=$(resolve_conntrack_mode "$requested_conntrack")
  modprobe tcp_bbr 2>/dev/null || true
  if [[ "$conntrack_mode" == "on" ]]; then
    modprobe nf_conntrack 2>/dev/null || true
    log "Conntrack 已启用（模式: ${requested_conntrack}）。"
  else
    log "代理默认不主动加载 conntrack（模式: ${requested_conntrack}），减少无 NAT 场景的每包开销。"
  fi
  if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    die "This kernel does not expose BBR. Upgrade the kernel before applying this profile."
  fi

  capture_original_sysctl_state
  capture_original_managed_file "$SYSCTL_FILE"
  restore_system_sysctl_link
  clean_conflicts

  local memory_mb
  memory_mb=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
  resolve_tuning_profile "$requested_bandwidth" "$requested_rtt" "$memory_mb"
  local profile rmem_max wmem_max rmem_default wmem_default file_max conntrack_max backlog netdev_backlog syn_backlog tw_buckets keepalive_time keepalive_intvl keepalive_probes conntrack_config ipv6_config
  if [[ "$(buffer_profile "$memory_mb")" == "4" ]]; then
    profile="低内存高并发（${TUNING_BUFFER_MAX} 字节缓冲）"
    rmem_max=$TUNING_BUFFER_MAX
    wmem_max=$TUNING_BUFFER_MAX
    rmem_default=65536
    wmem_default=65536
    file_max=$(proxy_nofile_limit "$memory_mb")
    conntrack_max=65536
    backlog=8192
    netdev_backlog=8192
    syn_backlog=4096
    tw_buckets=32768
    keepalive_time=300
    keepalive_intvl=15
    keepalive_probes=3
  else
    profile="标准档（按带宽/RTT计算的 ${TUNING_BUFFER_MAX} 字节缓冲）"
    rmem_max=$TUNING_BUFFER_MAX
    wmem_max=$TUNING_BUFFER_MAX
    rmem_default=262144
    wmem_default=262144
    file_max=$(proxy_nofile_limit "$memory_mb")
    conntrack_max=131072
    backlog=16384
    netdev_backlog=16384
    syn_backlog=8192
    tw_buckets=50000
    keepalive_time=300
    keepalive_intvl=15
    keepalive_probes=3
  fi
  log "检测到 ${memory_mb} MiB 内存，正在应用 ${profile} 配置。"

  if [[ "$ipv6_mode" == "on" ]]; then
    ipv6_config="net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2"
    log "已按选择开启 IPv6 转发。"
  else
    ipv6_config="net.ipv6.conf.all.forwarding = 0
net.ipv6.conf.default.forwarding = 0
net.ipv6.conf.all.accept_ra = 1
net.ipv6.conf.default.accept_ra = 1"
    warn "IPv6 转发已关闭（默认）；本机普通 IPv6 出站连接仍保留。"
  fi

  conntrack_config=""
  if [[ "$conntrack_mode" == "on" && -e /proc/sys/net/netfilter/nf_conntrack_max ]]; then
    conntrack_config="net.netfilter.nf_conntrack_max = ${conntrack_max}"
  fi
  if [[ "$conntrack_mode" == "on" && -e /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established ]]; then
    if [[ -n "$conntrack_config" ]]; then
      conntrack_config+=$'\n'
    fi
    conntrack_config+="net.netfilter.nf_conntrack_tcp_timeout_established = 432000"
  fi
  if [[ "$conntrack_mode" == "off" ]]; then
    log "Conntrack 配置已关闭，跳过相关 sysctl。"
  elif [[ -z "$conntrack_config" ]]; then
    warn "系统没有可用的 nf_conntrack 参数节点，跳过连接跟踪限制。"
  else
    log "已按内核实际暴露的 conntrack 参数应用代理长连接保护。"
  fi

  cat >"$SYSCTL_FILE" <<EOF
# Managed by vps-init-suite.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 0
net.core.rmem_max = ${rmem_max}
net.core.wmem_max = ${wmem_max}
net.core.rmem_default = ${rmem_default}
net.core.wmem_default = ${wmem_default}
net.ipv4.tcp_rmem = 4096 ${rmem_default} ${rmem_max}
net.ipv4.tcp_wmem = 4096 ${wmem_default} ${wmem_max}
net.ipv4.ip_forward = 1
${ipv6_config}
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_slow_start_after_idle = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1
net.core.somaxconn = ${backlog}
net.core.netdev_max_backlog = ${netdev_backlog}
net.ipv4.tcp_max_syn_backlog = ${syn_backlog}
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_tw_buckets = ${tw_buckets}
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_keepalive_time = ${keepalive_time}
net.ipv4.tcp_keepalive_intvl = ${keepalive_intvl}
net.ipv4.tcp_keepalive_probes = ${keepalive_probes}
${conntrack_config}
fs.file-max = ${file_max}
fs.nr_open = ${file_max}
vm.swappiness = 10
EOF

  cat >/etc/modules-load.d/vps-init-suite.conf <<'EOF'
# Managed by vps-init-suite.
tcp_bbr
EOF
  if [[ "$conntrack_mode" == "on" && -n "$conntrack_config" && -e /proc/sys/net/netfilter/nf_conntrack_max ]]; then
    printf '%s\n' nf_conntrack >>/etc/modules-load.d/vps-init-suite.conf
  fi

  sysctl -p "$SYSCTL_FILE"
  verify_sysctl_value net.core.default_qdisc fq || die "内核未应用 net.core.default_qdisc=fq。"
  verify_sysctl_value net.ipv4.tcp_congestion_control bbr || die "内核未应用 TCP BBR。"
  verify_sysctl_value net.ipv4.tcp_fastopen 0 || die "内核未应用 TCP Fast Open=0。"
  verify_sysctl_value net.core.rmem_max "$rmem_max" || die "内核接收缓冲上限与配置不一致。"
  verify_sysctl_value net.core.wmem_max "$wmem_max" || die "内核发送缓冲上限与配置不一致。"
  verify_sysctl_value net.ipv4.ip_forward 1 || die "IPv4 转发未能生效。"
  if [[ "$ipv6_mode" == "on" ]]; then
    verify_sysctl_value net.ipv6.conf.all.forwarding 1 || die "IPv6 转发未能生效。"
  else
    verify_sysctl_value net.ipv6.conf.all.forwarding 0 || die "IPv6 转发关闭设置未能生效。"
  fi
  # /etc/sysctl.d is loaded by the distro-provided systemd-sysctl unit. Do
  # not add a second boot-time unit or place sysctl behind network-online.
  migrate_legacy_boot_services
  systemctl daemon-reload
  configure_systemd_shutdown_timeout
  configure_xui_service_limits "$file_max"
  log "内核配置已生效，并已设置为开机自动应用。"
}

restore_system_sysctl_link() {
  local path=/etc/sysctl.d/99-sysctl.conf
  # Older releases treated this distribution-managed entry point as a
  # removable conflict. Restore it only when absent; never overwrite a user
  # file or symlink.
  [[ -e "$path" || -L "$path" ]] && return 0
  [[ -f /etc/sysctl.conf ]] || return 0
  ln -s ../sysctl.conf "$path"
  log "已恢复系统默认的 /etc/sysctl.d/99-sysctl.conf 软链接。"
}

configure_systemd_shutdown_timeout() {
  # Keep the scope limited to the suite-owned manager drop-in. Do not alter
  # individual services or block network-online during boot.
  if [[ -e "$SYSTEMD_TIMEOUT_FILE" ]] && ! is_suite_managed_file "$SYSTEMD_TIMEOUT_FILE"; then
    warn "发现非本项目的 systemd 停机超时配置，保持原文件不变。"
    return 0
  fi
  assert_not_symlink "$SYSTEMD_TIMEOUT_FILE"
  capture_original_managed_file "$SYSTEMD_TIMEOUT_FILE"
  mkdir -p "$(dirname "$SYSTEMD_TIMEOUT_FILE")"
  local temporary
  temporary=$(mktemp "$(dirname "$SYSTEMD_TIMEOUT_FILE")/.90-vps-init-suite-timeout.XXXXXX")
  cat >"$temporary" <<'EOF'
# Managed by vps-init-suite.
[Manager]
DefaultTimeoutStopSec=10s
EOF
  chmod 0644 "$temporary"
  mv -f -- "$temporary" "$SYSTEMD_TIMEOUT_FILE"
  systemctl daemon-reload
  log "已设置 systemd 停机超时为 10 秒，避免代理服务停止时长时间挂起。"
}

write_mss_unit() {
  cat >"$MSS_UNIT" <<EOF
# Managed by vps-init-suite.
[Unit]
Description=Apply vps-init-suite TCP MSS policy
After=network.target

[Service]
Type=oneshot
ExecStart=${MSS_HELPER}
RemainAfterExit=yes
TimeoutStartSec=20s
TimeoutStopSec=5s

EOF
}

write_mss_timer() {
  cat >"$MSS_TIMER" <<EOF
# Managed by vps-init-suite.
[Unit]
Description=Apply vps-init-suite TCP MSS policy after boot

[Timer]
OnBootSec=30s
Unit=vps-init-suite-mss.service

[Install]
WantedBy=timers.target
EOF
}

migrate_legacy_boot_services() {
  restore_system_sysctl_link
  if is_suite_managed_file "$SYSCTL_UNIT"; then
    run_with_timeout 10 systemctl disable --now vps-init-suite-sysctl.service >/dev/null 2>&1 || true
    rm -f -- "$SYSCTL_UNIT"
    log "已移除旧版开机 sysctl 服务，改用系统原生 systemd-sysctl。"
  fi
  if is_suite_managed_file "$MSS_UNIT"; then
    assert_not_symlink "$MSS_UNIT"
    write_mss_unit
    systemctl disable vps-init-suite-mss.service >/dev/null 2>&1 || true
    assert_not_symlink "$MSS_TIMER"
    write_mss_timer
    systemctl enable --now vps-init-suite-mss.timer >/dev/null 2>&1 || true
    log "已迁移 MSS 到延迟启动计时器，不再占用系统开机目标。"
  fi
  # Remove only legacy suite-owned OUTPUT attachments. This lets an upgrade
  # take effect immediately even when setup_mss is not run afterwards.
  local binary
  for binary in iptables ip6tables; do
    command -v "$binary" >/dev/null 2>&1 || continue
    while "$binary" -w 2 -t mangle -C OUTPUT -p tcp --tcp-flags SYN,RST SYN \
      -m comment --comment vps-init-suite -j VPS_INIT_MSS 2>/dev/null; do
      "$binary" -w 2 -t mangle -D OUTPUT -p tcp --tcp-flags SYN,RST SYN \
        -m comment --comment vps-init-suite -j VPS_INIT_MSS || break
    done
  done
  systemctl daemon-reload >/dev/null 2>&1 || true
}

clean_conflicts() {
  local filename path
  local found=0
  for filename in "${CONFLICT_FILES[@]}"; do
    path="/etc/sysctl.d/${filename}"
    if [[ -e "$path" && "$path" != "$SYSCTL_FILE" ]]; then
      backup_existing "$path"
      rm -f -- "$path"
      found=1
    fi
  done
  if (( found )); then
    warn "已备份并移除已知的第三方 sysctl 碎片配置。"
  fi
}

verify_sysctl_value() {
  local key=$1 expected=$2 actual
  actual=$(sysctl -n "$key" 2>/dev/null) || return 1
  [[ "$actual" == "$expected" ]]
}

buffer_profile() {
  local memory_mb=$1
  if (( memory_mb < 1500 )); then
    printf '%s\n' "4"
  else
    printf '%s\n' "16"
  fi
}

memory_buffer_cap_mib() {
  local memory_mb=$1
  # Keep a 1 GiB proxy node capable of filling a 200 Mbps high-RTT path,
  # while still bounding the per-socket autotuning ceiling for OOM safety.
  local cap_mib=$(((memory_mb + 127) / 128))
  (( cap_mib < 4 )) && cap_mib=4
  (( cap_mib > 64 )) && cap_mib=64
  printf '%s\n' "$cap_mib"
}

tuning_value() {
  local key=$1 config=${2:-$TUNING_CONFIG}
  [[ -r "$config" ]] || return 0
  awk -F= -v wanted="$key" '$1 == wanted {print $2; exit}' "$config"
}

calculate_buffer_max() {
  local bandwidth_mbps=$1 rtt_ms=$2 memory_mb=$3
  local bdp_bytes target_bytes target_mib memory_cap_mib rounded_mib
  bdp_bytes=$((bandwidth_mbps * 125 * rtt_ms))
  # Reserve 1.5x BDP for ACK compression and moderate loss without making
  # every connection start with a large allocation.
  target_bytes=$((bdp_bytes * 3 / 2))
  target_mib=$(( (target_bytes + 1048575) / 1048576 ))
  (( target_mib < 4 )) && target_mib=4
  # Power-of-two ceilings avoid awkward values such as 6 MiB and give
  # autotuning enough headroom for real-world RTT/jitter variation.
  rounded_mib=4
  while (( rounded_mib < target_mib && rounded_mib < 64 )); do
    rounded_mib=$((rounded_mib * 2))
  done
  target_mib=$rounded_mib
  memory_cap_mib=$(memory_buffer_cap_mib "$memory_mb")
  (( target_mib > memory_cap_mib )) && target_mib=$memory_cap_mib
  printf '%s\n' "$((target_mib * 1048576))"
}

resolve_tuning_profile() {
  local requested_bandwidth=${1:-} requested_rtt=${2:-} memory_mb=$3
  local stored_bandwidth stored_rtt bdp_bytes requested_mib memory_cap_mib
  stored_bandwidth=$(tuning_value BANDWIDTH_MBPS)
  stored_rtt=$(tuning_value RTT_MS)
  [[ -n "$requested_bandwidth" ]] || requested_bandwidth="$stored_bandwidth"
  [[ -n "$requested_rtt" ]] || requested_rtt="$stored_rtt"

  if [[ -z "$requested_bandwidth" && -t 0 ]]; then
    prompt_tuning_value requested_bandwidth "VPS 标称带宽" \
      "请输入 VPS 标称带宽 Mbps（输入 auto 使用保守 100 Mbps）[auto]: " \
      auto 1 100000 1 100 Mbps
  fi
  if [[ -z "$requested_rtt" && -t 0 ]]; then
    prompt_tuning_value requested_rtt "代理 RTT" \
      "请输入代理用户到 VPS 的典型 RTT 毫秒（跨洋可填 160）[160]: " \
      160 1 2000 1 160 ms
  fi
  [[ -n "$requested_bandwidth" ]] || requested_bandwidth=auto
  [[ -n "$requested_rtt" ]] || requested_rtt=160
  [[ "$requested_bandwidth" == "auto" ]] && requested_bandwidth=100
  [[ "$requested_rtt" == "auto" ]] && requested_rtt=160
  [[ "$requested_bandwidth" =~ ^[0-9]+$ ]] || die "带宽必须是 1-100000 Mbps 的整数，或输入 auto。"
  (( 10#$requested_bandwidth >= 1 && 10#$requested_bandwidth <= 100000 )) || die "带宽必须是 1-100000 Mbps 的整数，或输入 auto。"
  [[ "$requested_rtt" =~ ^[0-9]+$ ]] || die "RTT 必须是 1-2000 毫秒的整数，或输入 auto。"
  (( 10#$requested_rtt >= 1 && 10#$requested_rtt <= 2000 )) || die "RTT 必须是 1-2000 毫秒的整数，或输入 auto。"

  TUNING_BANDWIDTH=$((10#$requested_bandwidth))
  TUNING_RTT=$((10#$requested_rtt))
  TUNING_BUFFER_MAX=$(calculate_buffer_max "$TUNING_BANDWIDTH" "$TUNING_RTT" "$memory_mb")
  bdp_bytes=$((TUNING_BANDWIDTH * 125 * TUNING_RTT))
  requested_mib=$(( (bdp_bytes * 3 / 2 + 1048575) / 1048576 ))
  memory_cap_mib=$(memory_buffer_cap_mib "$memory_mb")
  if (( requested_mib > memory_cap_mib )); then
    warn "按 ${TUNING_BANDWIDTH} Mbps/${TUNING_RTT} ms 计算需要约 ${requested_mib} MiB；受 ${memory_mb} MiB 物理内存保护，上限收敛为 ${memory_cap_mib} MiB。"
  fi
  assert_not_symlink "$TUNING_CONFIG"
  capture_original_managed_file "$TUNING_CONFIG"
  mkdir -p "$(dirname "$TUNING_CONFIG")"
  local temporary
  temporary=$(mktemp "$(dirname "$TUNING_CONFIG")/.vps-init-suite-tuning.XXXXXX")
  cat >"$temporary" <<EOF
# Managed by vps-init-suite.
BANDWIDTH_MBPS=${TUNING_BANDWIDTH}
RTT_MS=${TUNING_RTT}
BUFFER_MAX=${TUNING_BUFFER_MAX}
EOF
  chmod 0644 "$temporary"
  mv -f -- "$temporary" "$TUNING_CONFIG"
}

prompt_tuning_value() {
  local target=$1 label=$2 prompt=$3 default=$4 minimum=$5 maximum=$6
  local allow_auto=$7 auto_fallback=$8 unit=$9 answer value digit_limit auto_hint=""
  digit_limit=${#maximum}
  if [[ "$allow_auto" == "1" ]]; then
    auto_hint="，或输入 auto"
  fi

  while true; do
    if ! read -r -p "$prompt" answer; then
      printf '\n'
      die "无法读取${label}输入，请在交互式终端重试。"
    fi
    printf '\n'
    value=${answer:-$default}

    if [[ "$allow_auto" == "1" && "$value" == "auto" ]]; then
      printf -v "$target" '%s' "auto"
      printf '已确认%s：auto（按保守值 %s %s 计算）。\n\n' "$label" "$auto_fallback" "$unit"
      return 0
    fi

    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
      printf '输入无效：请输入 %s-%s 之间的整数%s。请重新输入本项。\n\n' \
        "$minimum" "$maximum" "$auto_hint"
      continue
    fi

    while [[ "$value" == 0* && "$value" != 0 ]]; do value=${value#0}; done
    if (( ${#value} > digit_limit )); then
      printf '输入超出范围：%s 需在 %s-%s 之间。请重新输入本项。\n\n' \
        "$label" "$minimum" "$maximum"
      continue
    fi
    value=$((10#$value))
    if (( value < minimum || value > maximum )); then
      printf '输入超出范围：%s 需在 %s-%s 之间。请重新输入本项。\n\n' \
        "$label" "$minimum" "$maximum"
      continue
    fi

    printf -v "$target" '%s' "$value"
    printf '已确认%s：%s %s。\n\n' "$label" "$value" "$unit"
    return 0
  done
}

prompt_missing_tuning_profile() {
  local bandwidth_var=$1 rtt_var=$2
  local bandwidth=${!bandwidth_var} rtt=${!rtt_var}
  local stored_bandwidth stored_rtt

  stored_bandwidth=$(tuning_value BANDWIDTH_MBPS 2>/dev/null || true)
  stored_rtt=$(tuning_value RTT_MS 2>/dev/null || true)
  [[ -n "$bandwidth" ]] || bandwidth=$stored_bandwidth
  [[ -n "$rtt" ]] || rtt=$stored_rtt

  if [[ -z "$bandwidth" || -z "$rtt" ]]; then
    log "带宽和 RTT 不会自动测速。请按 VPS 套餐标称带宽和用户到节点的典型延迟填写；每项确认后再进入下一项。"
  fi
  if [[ -z "$bandwidth" ]]; then
    prompt_tuning_value bandwidth "VPS 标称带宽" \
      "请输入 VPS 套餐标称带宽 Mbps（输入 auto 按保守 100 Mbps）[auto]: " \
      auto 1 100000 1 100 Mbps
  fi
  if [[ -z "$rtt" ]]; then
    prompt_tuning_value rtt "代理 RTT" \
      "请输入代理用户到 VPS 的典型 RTT 毫秒（跨洋可填 160）[160]: " \
      160 1 2000 1 160 ms
  fi

  log "本次缓冲档位：${bandwidth} Mbps / ${rtt} ms；如需修改，可在菜单选择“手动设置/修改带宽与 RTT”。"
  printf -v "$bandwidth_var" '%s' "$bandwidth"
  printf -v "$rtt_var" '%s' "$rtt"
}

configure_bandwidth_profile() {
  require_root
  require_supported_os
  local memory_mb bandwidth=${1:-} rtt=${2:-} current_bandwidth current_rtt
  memory_mb=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
  if [[ -z "$bandwidth" && -t 0 ]]; then
    current_bandwidth=$(tuning_value BANDWIDTH_MBPS 2>/dev/null || true)
    prompt_tuning_value bandwidth "VPS 标称带宽" \
      "请输入 VPS 标称带宽 Mbps（输入 auto 使用保守 100 Mbps）[${current_bandwidth:-auto}]: " \
      "${current_bandwidth:-auto}" 1 100000 1 100 Mbps
  fi
  if [[ -z "$rtt" && -t 0 ]]; then
    current_rtt=$(tuning_value RTT_MS 2>/dev/null || true)
    prompt_tuning_value rtt "代理 RTT" \
      "请输入代理用户到 VPS 的典型 RTT 毫秒（跨洋可填 160）[${current_rtt:-160}]: " \
      "${current_rtt:-160}" 1 2000 1 160 ms
  fi
  tune_kernel "${VPS_IPV6:-}" "${VPS_CONNTRACK:-auto}" "$bandwidth" "$rtt"
  log "已保存带宽档位：${TUNING_BANDWIDTH} Mbps，RTT：${TUNING_RTT} ms，TCP 缓冲上限：${TUNING_BUFFER_MAX} 字节。"
}

proxy_nofile_limit() {
  local memory_mb=$1
  if (( memory_mb < 1500 )); then
    printf '%s\n' "262144"
  else
    printf '%s\n' "524288"
  fi
}

configure_xui_service_limits() {
  local file_limit=${1:?missing x-ui file limit}
  xui_service_detected || return 0
  systemctl cat x-ui.service >/dev/null 2>&1 || return 0
  if [[ -L "$XUI_LIMITS_DIR" ]]; then
    warn "检测到 x-ui.service.d 是符号链接，跳过文件句柄 drop-in，避免写入未知位置。"
    return 0
  fi
  assert_not_symlink "$XUI_LIMITS_FILE"
  if [[ -e "$XUI_LIMITS_FILE" ]] && ! is_suite_managed_file "$XUI_LIMITS_FILE"; then
    warn "发现非本项目的 x-ui 文件句柄配置，保持原文件不变并跳过覆盖。"
    return 0
  fi

  mkdir -p "$XUI_LIMITS_DIR"
  capture_original_managed_file "$XUI_LIMITS_FILE"
  local temporary
  temporary=$(mktemp "${XUI_LIMITS_DIR}/.90-vps-init-suite.XXXXXX")
  cat >"$temporary" <<EOF
# Managed by vps-init-suite.
# Proxy-node service limit; takes effect on the next x-ui.service restart.
[Service]
LimitNOFILE=${file_limit}
EOF
  chmod 0644 "$temporary"
  mv -f -- "$temporary" "$XUI_LIMITS_FILE"
  systemctl daemon-reload
  if systemctl is-active --quiet x-ui.service; then
    if [[ -t 0 ]]; then
      local answer
      read -r -p "是否现在重启 x-ui.service 使文件句柄上限生效？现有代理连接会短暂重连 [y/N]: " answer
      case "${answer:-n}" in
        y|Y|yes|YES)
          if systemctl restart x-ui.service; then
            log "已为 x-ui.service 应用 LimitNOFILE=${file_limit}。"
          else
            warn "x-ui.service 重启失败，正在尝试启动服务；文件句柄设置将在下次成功启动时生效。"
            systemctl start x-ui.service >/dev/null 2>&1 || true
          fi
          ;;
        *) log "已为 x-ui.service 保存 LimitNOFILE=${file_limit}；下次重启面板服务后生效。" ;;
      esac
    else
      log "已为 x-ui.service 保存 LimitNOFILE=${file_limit}；下次重启面板服务后生效。"
    fi
  else
    log "已为 x-ui.service 设置 LimitNOFILE=${file_limit}；服务下次启动时生效。"
  fi
}

normalize_ipv6_mode() {
  case "${1:-}" in
    on|yes|y|1|enable|enabled) printf '%s\n' "on" ;;
    off|no|n|0|disable|disabled) printf '%s\n' "off" ;;
    *) return 1 ;;
  esac
}

resolve_ipv6_mode() {
  local requested=${1:-${VPS_IPV6:-}}
  local answer
  if [[ -z "$requested" ]]; then
    if [[ -t 0 ]]; then
      read -r -p "是否开启本 VPS 的 IPv6 转发？[y/N]: " answer
      requested=${answer:-off}
    else
      requested="off"
    fi
  fi
  normalize_ipv6_mode "$requested" || die "IPv6 mode must be on or off. Default is off."
}

normalize_conntrack_mode() {
  case "${1:-}" in
    auto|on|off) printf '%s\n' "$1" ;;
    *) return 1 ;;
  esac
}

conntrack_rules_present() {
  local binary
  if command -v nft >/dev/null 2>&1 &&
    nft list ruleset 2>/dev/null | grep -Eq -- 'ct (state|status)|type nat'; then
    return 0
  fi
  for binary in iptables ip6tables; do
    command -v "$binary" >/dev/null 2>&1 || continue
    if "$binary" -w 2 -S 2>/dev/null | grep -Eq -- ' -m (conntrack|state)( |$)'; then
      return 0
    fi
    if "$binary" -w 2 -t nat -S 2>/dev/null | grep -Eq -- '^-A (PREROUTING|POSTROUTING|OUTPUT) '; then
      return 0
    fi
  done
  return 1
}

resolve_conntrack_mode() {
  local requested=${1:-${VPS_CONNTRACK:-auto}}
  normalize_conntrack_mode "$requested" >/dev/null || die "Conntrack mode must be auto, on, or off."
  if [[ "$requested" == "auto" ]]; then
    if conntrack_rules_present; then
      printf '%s\n' "on"
    else
      printf '%s\n' "off"
    fi
  else
    printf '%s\n' "$requested"
  fi
}

is_valid_timezone() {
  local timezone=$1
  [[ "$timezone" =~ ^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)+$ ]] || return 1
  case "/${timezone}/" in
    */../*|*/./*) return 1 ;;
  esac
  [[ -f "${ZONEINFO_DIR}/${timezone}" ]]
}

fetch_timezone_text() {
  local url=$1
  local response
  response=$(curl --proto '=https' --tlsv1.2 --silent --show-error --fail \
    --connect-timeout 2 --max-time 3 "$url" 2>/dev/null) || return 1
  response=${response//$'\r'/}
  response=${response//$'\n'/}
  is_valid_timezone "$response" || return 1
  printf '%s\n' "$response"
}

fetch_timezone_json() {
  local url=$1
  local filter=$2
  local response timezone
  response=$(curl --proto '=https' --tlsv1.2 --silent --show-error --fail \
    --connect-timeout 2 --max-time 3 "$url" 2>/dev/null) || return 1
  timezone=$(jq -er "$filter" <<<"$response" 2>/dev/null) || return 1
  is_valid_timezone "$timezone" || return 1
  printf '%s\n' "$timezone"
}

detect_public_timezone() {
  local timezone
  if timezone=$(fetch_timezone_json "https://ipwho.is/" '.timezone.id // empty'); then
    printf '%s\n' "$timezone"
    return 0
  fi
  if timezone=$(fetch_timezone_text "https://ipinfo.io/timezone"); then
    printf '%s\n' "$timezone"
    return 0
  fi
  if timezone=$(fetch_timezone_text "https://ipapi.co/timezone/"); then
    printf '%s\n' "$timezone"
    return 0
  fi
  return 1
}

choose_timezone_interactively() {
  local choice custom_timezone
  cat >&2 <<'EOF'
自动时区探测失败，请选择：
  1. 保留当前时区（推荐）
  2. UTC（协调世界时）
  3. Asia/Tokyo（东京）
  4. America/Los_Angeles（洛杉矶）
  5. America/New_York（纽约）
  6. Europe/London（伦敦）
  7. Asia/Singapore（新加坡）
  8. 输入其他 IANA 时区
EOF
  read -r -p "请选择 [1-8]（直接回车保留当前时区）: " choice
  case "$choice" in
    1) printf '%s\n' "keep" ;;
    2) printf '%s\n' "Etc/UTC" ;;
    3) printf '%s\n' "Asia/Tokyo" ;;
    4) printf '%s\n' "America/Los_Angeles" ;;
    5) printf '%s\n' "America/New_York" ;;
    6) printf '%s\n' "Europe/London" ;;
    7) printf '%s\n' "Asia/Singapore" ;;
    8)
      read -r -p "请输入 IANA 时区（例如 Europe/Berlin）: " custom_timezone
      is_valid_timezone "$custom_timezone" || die "Unknown IANA timezone: ${custom_timezone}"
      printf '%s\n' "$custom_timezone"
      ;;
    *) printf '%s\n' "keep" ;;
  esac
}

enable_network_time() {
  # Prefer the distribution's native timesyncd. It adds no package or boot
  # dependency. Fall back to chrony only when timesyncd is unavailable.
  if run_timedatectl 5 set-ntp true 2>/dev/null ||
    run_with_timeout 10 systemctl enable --now systemd-timesyncd.service >/dev/null 2>&1; then
    return 0
  fi
  warn "systemd-timesyncd 不可用，正在安装 chrony 作为备用校时服务。"
  if ! apt_install chrony; then
    warn "chrony 安装失败；保留当前时间，稍后可手动安装 chrony。"
    return 0
  fi
  run_with_timeout 10 systemctl disable --now systemd-timesyncd.service >/dev/null 2>&1 || true
  if ! run_with_timeout 15 systemctl enable --now chrony.service >/dev/null 2>&1; then
    warn "chrony 启动失败；可检查 systemctl status chrony.service。"
    return 0
  fi
  if ! run_with_timeout 15 systemctl restart chrony.service >/dev/null 2>&1; then
    warn "chrony 重启失败；保留后台校时服务继续运行。"
    return 0
  fi
  if command -v chronyc >/dev/null 2>&1; then
    if run_with_timeout 15 chronyc -n makestep >/dev/null 2>&1; then
      log "chrony 已立即校准系统时间。"
    else
      warn "chrony 尚未完成立即校时；后台服务会继续重试。"
    fi
  else
    warn "未找到 chronyc，无法立即校时；chrony 服务仍已启用。"
  fi
}

set_timezone() {
  local timezone=$1
  if run_timedatectl 5 set-timezone "$timezone" 2>/dev/null; then
    return 0
  fi
  ln -snf "/usr/share/zoneinfo/${timezone}" /etc/localtime
  printf '%s\n' "$timezone" >/etc/timezone
  warn "timedatectl 不可用，已通过 /etc/localtime 软链接设置时区。"
}

setup_timezone() {
  require_root
  require_supported_os
  local requested=${1:-auto}
  local timezone

  apt_install ca-certificates curl jq tzdata
  if [[ "$requested" == "auto" ]]; then
    warn "正在根据 VPS 公网出口自动探测时区..."
    if timezone=$(detect_public_timezone); then
      log "检测到 IANA 时区：${timezone}"
    else
      timezone="keep"
      warn "自动探测失败（已快速跳过），保留当前时区继续；如需手动设置，请执行：vps-init timezone 时区。"
    fi
  elif [[ "$requested" == "keep" ]]; then
    timezone="keep"
  else
    timezone=$requested
    is_valid_timezone "$timezone" || die "Unknown IANA timezone: ${timezone}"
  fi

  if [[ "$timezone" != "keep" ]]; then
    set_timezone "$timezone"
    log "时区已设置为 ${timezone}。"
  else
    warn "保留当前系统时区。"
  fi
  enable_network_time
  log "网络时间同步已启用，当前时间：$(date '+%Y-%m-%d %H:%M:%S %Z')"
}

setup_swap() {
  require_root
  require_supported_os
  assert_not_symlink "$SWAP_SYSCTL_FILE"
  apt_install util-linux

  if [[ -n $(swapon --show=NAME --noheadings 2>/dev/null) ]]; then
    warn "系统已有活动 SWAP，保持现状不修改。"
    return 0
  fi

  local memory_mb swap_gib required_bytes available_bytes
  memory_mb=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
  if (( memory_mb <= 2048 )); then
    swap_gib=2
  else
    swap_gib=4
  fi
  required_bytes=$(( (swap_gib + 1) * 1024 * 1024 * 1024 ))
  available_bytes=$(df -PB1 / | awk 'NR == 2 {print $4}')
  (( available_bytes >= required_bytes )) || die "Not enough free disk space for ${swap_gib} GiB swap plus 1 GiB headroom."

  if [[ -e "$SWAP_FILE" ]]; then
    if [[ -e "${STATE_DIR}/managed-swap.present" ]]; then
      warn "正在重新创建未启用的受管 SWAP 文件 ${SWAP_FILE}。"
      rm -f -- "$SWAP_FILE"
    else
      die "${SWAP_FILE} already exists but is not verified as suite-managed; preserving it. Inspect the file before moving it and rerunning swap setup."
    fi
  fi
  if ! fallocate -l "${swap_gib}G" "$SWAP_FILE"; then
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$((swap_gib * 1024)) status=progress
  fi
  chmod 600 "$SWAP_FILE"
  mkswap "$SWAP_FILE"
  swapon "$SWAP_FILE"
  grep -qF "$SWAP_FILE none swap sw 0 0" /etc/fstab || printf '%s\n' "$SWAP_FILE none swap sw 0 0" >>/etc/fstab
  mkdir -p "$STATE_DIR"
  : >"${STATE_DIR}/managed-swap.present"

  capture_original_sysctl_state
  capture_original_managed_file "$SWAP_SYSCTL_FILE"
  cat >"$SWAP_SYSCTL_FILE" <<'EOF'
# Managed by vps-init-suite.
vm.swappiness = 10
EOF
  sysctl -p "$SWAP_SYSCTL_FILE"
  log "已创建 ${swap_gib} GiB SWAP，swappiness 设置为 10。"
}

write_mss_helper() {
  local helper_path=${1:-$MSS_HELPER}
  local state_dir=${2:-$STATE_DIR}
  assert_not_symlink "$helper_path"
  mkdir -p "$(dirname "$helper_path")"
  capture_original_managed_file "$helper_path" "$state_dir"
  cat >"$helper_path" <<'EOF'
#!/usr/bin/env bash
# Managed by vps-init-suite.
set -Eeuo pipefail

# shellcheck disable=SC1091
source "${VPS_INIT_MSS_CONFIG:-/etc/default/vps-init-suite}"

apply_family() {
  local binary=$1
  local chain
  command -v "$binary" >/dev/null || return 0

  if ! "$binary" -w 5 -t mangle -L >/dev/null 2>&1; then
    printf 'vps-init-suite: %s mangle table unavailable; skipping MSS policy.\n' "$binary" >&2
    return 0
  fi
  if ! "$binary" -w 5 -t mangle -N VPS_INIT_MSS 2>/dev/null; then
    if ! "$binary" -w 5 -t mangle -S VPS_INIT_MSS >/dev/null 2>&1; then
      printf 'vps-init-suite: cannot create VPS_INIT_MSS with %s; skipping.\n' "$binary" >&2
      return 0
    fi
  fi
  if ! "$binary" -w 5 -t mangle -F VPS_INIT_MSS; then
    printf 'vps-init-suite: cannot update VPS_INIT_MSS with %s; skipping.\n' "$binary" >&2
    return 0
  fi

  local mss_value="$MSS_VALUE"
  if [[ "$MSS_MODE" == "dual-fixed" && "$binary" == "ip6tables" ]]; then
    mss_value="$MSS_VALUE6"
  fi
  if [[ "$MSS_MODE" == "fixed" || "$MSS_MODE" == "dual-fixed" ]]; then
    if ! "$binary" -w 5 -t mangle -A VPS_INIT_MSS -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss_value"; then
      printf 'vps-init-suite: cannot add fixed MSS rule with %s; skipping.\n' "$binary" >&2
      return 0
    fi
  else
    if ! "$binary" -w 5 -t mangle -A VPS_INIT_MSS -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu; then
      printf 'vps-init-suite: cannot add PMTU MSS rule with %s; skipping.\n' "$binary" >&2
      return 0
    fi
  fi

  # Remove OUTPUT attachments created by older releases.  Only rules carrying
  # the suite comment are touched; unrelated firewall rules remain unchanged.
  while "$binary" -w 5 -t mangle -C OUTPUT -p tcp --tcp-flags SYN,RST SYN \
    -m comment --comment vps-init-suite -j VPS_INIT_MSS 2>/dev/null; do
    "$binary" -w 5 -t mangle -D OUTPUT -p tcp --tcp-flags SYN,RST SYN \
      -m comment --comment vps-init-suite -j VPS_INIT_MSS || break
  done

  # Limit MSS rewriting to forwarded traffic.  Locally generated SYN/SYN-ACK
  # packets (including SSH and Xray) must not be rewritten by this policy.
  for chain in FORWARD; do
    if ! "$binary" -w 5 -t mangle -C "$chain" -p tcp --tcp-flags SYN,RST SYN -m comment --comment vps-init-suite -j VPS_INIT_MSS 2>/dev/null; then
      if ! "$binary" -w 5 -t mangle -I "$chain" 1 -p tcp --tcp-flags SYN,RST SYN -m comment --comment vps-init-suite -j VPS_INIT_MSS; then
        printf 'vps-init-suite: cannot attach MSS rule to %s/%s; skipping.\n' "$binary" "$chain" >&2
        return 0
      fi
    fi
  done
}

if ! apply_family iptables; then
  printf '%s\n' 'vps-init-suite: IPv4 MSS policy could not be applied; continuing.' >&2
fi
if ! apply_family ip6tables; then
  printf '%s\n' 'vps-init-suite: IPv6 MSS policy could not be applied; continuing.' >&2
fi
# A restricted VPS may not grant CAP_NET_ADMIN. Keep the systemd unit healthy
# and report the skipped family instead of making the whole initialization fail.
exit 0
EOF
  chmod 0755 "$helper_path"
}

mss_family_status() {
  local binary=$1 mode=$2 value=$3 value6=$4 rule_value
  local chain
  command -v "$binary" >/dev/null 2>&1 || { printf '%s\n' "未安装"; return 0; }
  "$binary" -w 2 -t mangle -L >/dev/null 2>&1 || { printf '%s\n' "不支持"; return 0; }
  "$binary" -w 2 -t mangle -S VPS_INIT_MSS >/dev/null 2>&1 || { printf '%s\n' "未生效"; return 0; }

  case "$mode" in
    clamp)
      "$binary" -w 2 -t mangle -C VPS_INIT_MSS -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 || {
        printf '%s\n' "未生效"
        return 0
      }
      ;;
    fixed|dual-fixed)
      rule_value=$value
      [[ "$mode" != "dual-fixed" || "$binary" != "ip6tables" ]] || rule_value=$value6
      [[ "$rule_value" =~ ^[0-9]+$ ]] || { printf '%s\n' "未生效"; return 0; }
      "$binary" -w 2 -t mangle -C VPS_INIT_MSS -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$rule_value" >/dev/null 2>&1 || {
        printf '%s\n' "未生效"
        return 0
      }
      ;;
    *)
      printf '%s\n' "未生效"
      return 0
      ;;
  esac

  for chain in FORWARD; do
    "$binary" -w 2 -t mangle -C "$chain" -p tcp --tcp-flags SYN,RST SYN \
      -m comment --comment vps-init-suite -j VPS_INIT_MSS >/dev/null 2>&1 || {
      printf '%s\n' "不完整"
      return 0
    }
  done
  printf '%s\n' "已生效"
}

setup_mss() {
  require_root
  require_supported_os
  assert_not_symlink "$MSS_CONFIG"
  assert_not_symlink "$MSS_UNIT"
  local requested=${1:-clamp}
  local mode value value6

  if [[ "$requested" == "clamp" ]]; then
    mode="clamp"
    value="1380"
    value6="1340"
  elif [[ "$requested" == "dual-fixed" ]]; then
    mode="dual-fixed"
    value="1380"
    value6="1340"
  elif [[ "$requested" =~ ^[0-9]+$ ]] && (( 10#$requested >= 1200 && 10#$requested <= 1460 )); then
    mode="fixed"
    value=$((10#$requested))
    value6="$value"
  else
    die "MSS must be 'clamp', 'dual-fixed', or a value from 1200 through 1460."
  fi

  apt_install iptables
  capture_original_managed_file "$MSS_CONFIG"
  cat >"$MSS_CONFIG" <<EOF
# Managed by vps-init-suite.
MSS_MODE=${mode}
MSS_VALUE=${value}
MSS_VALUE6=${value6}
EOF
  write_mss_helper

  capture_original_managed_file "$MSS_UNIT"
  write_mss_unit
  assert_not_symlink "$MSS_TIMER"
  capture_original_managed_file "$MSS_TIMER"
  write_mss_timer

  systemctl daemon-reload
  systemctl disable vps-init-suite-mss.service >/dev/null 2>&1 || true
  systemctl enable --now vps-init-suite-mss.timer >/dev/null
  if ! run_with_timeout 20 systemctl start vps-init-suite-mss.service; then
    warn "MSS 服务未能启动，将继续完成其他配置；检查命令：systemctl status vps-init-suite-mss.service"
    systemctl disable vps-init-suite-mss.service >/dev/null 2>&1 || true
    return 0
  fi
  local ipv4_status ipv6_status
  ipv4_status=$(mss_family_status iptables "$mode" "$value" "$value6")
  ipv6_status=$(mss_family_status ip6tables "$mode" "$value" "$value6")
  if [[ "$mode" == "dual-fixed" ]]; then
    log "MSS 持久化策略：IPv4 ${value}，IPv6 ${value6}。"
  elif [[ "$mode" == "fixed" ]]; then
    log "MSS 持久化策略：固定 ${value}。"
  else
    log "MSS 持久化策略：clamp-to-PMTU。"
  fi
  log "MSS 生效校验：IPv4 ${ipv4_status}，IPv6 ${ipv6_status}。"
  [[ "$ipv4_status" == "已生效" ]] || warn "IPv4 MSS 规则未完整生效；检查 VPS 是否提供 iptables mangle 权限。"
  [[ "$ipv6_status" == "已生效" ]] || warn "IPv6 MSS 规则不可用或未完整生效；IPv6 未启用时可忽略。"
}

uninstall_3xui() {
  require_root
  require_supported_os
  local assume_yes=${1:-}

  warn "This permanently removes the 3X-UI service, database, and configuration."
  if [[ "$assume_yes" != "--yes" ]]; then
    [[ -t 0 ]] || die "Interactive confirmation is unavailable. Re-run with: uninstall-3xui --yes"
    read -r -p "Type REMOVE to continue: " answer
    [[ "$answer" == "REMOVE" ]] || { warn "Cancelled."; return 0; }
  fi

  systemctl disable --now x-ui.service 2>/dev/null || true
  rm -rf -- /usr/local/x-ui /etc/x-ui
  rm -f -- /etc/systemd/system/x-ui.service /usr/lib/systemd/system/x-ui.service /usr/bin/x-ui
  systemctl daemon-reload
  log "3X-UI and its known local data paths were removed."
}

install_xui_policy_helper() {
  require_root
  require_supported_os
  command -v python3 >/dev/null || apt_install python3
  assert_not_symlink "$XUI_POLICY_HELPER"
  capture_original_managed_file "$XUI_POLICY_HELPER"
  mkdir -p "$INSTALL_DIR"
  local source_path=${BASH_SOURCE[0]:-}
  local source_helper=""
  local temporary
  if [[ -n "$source_path" && "$source_path" != "$INSTALLED_SCRIPT" && "$source_path" != "bash" && "$source_path" != "/dev/stdin" && -f "$source_path" ]]; then
    source_helper="$(dirname -- "$source_path")/xui-policy.py"
  fi
  temporary=$(mktemp "${INSTALL_DIR}/xui-policy.py.XXXXXX")
  if [[ -n "$source_helper" && -f "$source_helper" ]]; then
    install -m 0755 "$source_helper" "$temporary"
  else
    command -v curl >/dev/null || apt_install ca-certificates curl
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 --silent --show-error --fail \
      "$(github_raw_url xui-policy.py)" -o "$temporary"
    chmod 0755 "$temporary"
  fi
  python3 - "$temporary" <<'PY'
import pathlib
import sys
compile(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"), sys.argv[1], "exec")
PY
  mv -f -- "$temporary" "$XUI_POLICY_HELPER"
  log "3X-UI policy 辅助程序已安装。"
}

ensure_xui_policy_helper() {
  if [[ -x "$XUI_POLICY_HELPER" ]] && is_suite_managed_file "$XUI_POLICY_HELPER" &&
    grep -qF "HELPER_VERSION = \"${XUI_POLICY_HELPER_VERSION}\"" "$XUI_POLICY_HELPER"; then
    return 0
  fi
  # Upgrade helpers left by older suite versions on first policy access.
  install_xui_policy_helper >&2
}

xui_policy_database() {
  ensure_xui_policy_helper
  python3 "$XUI_POLICY_HELPER" locate
}

xui_policy_stop_service() {
  XUI_POLICY_SERVICE_STOPPED=0
  if systemctl is-active --quiet x-ui.service; then
    systemctl stop x-ui.service
    XUI_POLICY_SERVICE_STOPPED=1
  fi
}

xui_policy_start_service() {
  if (( XUI_POLICY_SERVICE_STOPPED )); then
    systemctl start x-ui.service
    systemctl is-active --quiet x-ui.service || return 1
    XUI_POLICY_SERVICE_STOPPED=0
  fi
}

xui_policy_apply() {
  local seconds=$1 uplink=$2 downlink=$3
  local database backup
  [[ -t 0 ]] || die "修改 3X-UI 数据库前需要交互式确认。"
  database=$(xui_policy_database) || die "找不到 3X-UI SQLite 数据库。"
  python3 "$XUI_POLICY_HELPER" show "$database"
  warn "即将修改 Xray policy level 0，并重启 x-ui.service；现有代理连接可能短暂重连。"
  local answer
  read -r -p "请输入 APPLY-XUI-POLICY 继续：" answer
  [[ "$answer" == "APPLY-XUI-POLICY" ]] || { warn "已取消。"; return 0; }
  backup="${XUI_BACKUP_ROOT}/x-ui-$(date +%Y%m%d-%H%M%S-%N).db"
  mkdir -p "$XUI_BACKUP_ROOT"
  chmod 0700 "$XUI_BACKUP_ROOT"
  xui_policy_stop_service
  if ! python3 "$XUI_POLICY_HELPER" backup "$database" "$backup"; then
    xui_policy_start_service || true
    die "无法创建并校验 3X-UI 数据库备份，未修改 policy。"
  fi
  if ! python3 "$XUI_POLICY_HELPER" set "$database" "$seconds" "$uplink" "$downlink"; then
    python3 "$XUI_POLICY_HELPER" restore-policy "$database" "$backup" >/dev/null 2>&1 || true
    xui_policy_start_service || true
    die "无法更新 3X-UI policy，备份仍保留在：${backup}"
  fi
  if ! xui_policy_start_service; then
    warn "修改 policy 后 3X-UI 重启失败，正在恢复已验证备份。"
    python3 "$XUI_POLICY_HELPER" restore-policy "$database" "$backup" || true
    systemctl start x-ui.service >/dev/null 2>&1 || true
    XUI_POLICY_SERVICE_STOPPED=0
    die "3X-UI 未能正常重启，已恢复之前的 policy。"
  fi
  log "3X-UI policy 已更新，已验证备份：${backup}"
}

xui_policy_restore_latest() {
  local database backup
  database=$(xui_policy_database) || die "找不到 3X-UI SQLite 数据库。"
  backup=$(find "$XUI_BACKUP_ROOT" -maxdepth 1 -type f -name 'x-ui-*.db' -printf '%f\n' 2>/dev/null | sort -r | head -n 1)
  [[ -n "$backup" ]] || die "没有找到 vps-init-suite 的 3X-UI policy 备份。"
  backup="${XUI_BACKUP_ROOT}/${backup}"
  warn "即将恢复 3X-UI policy 备份：${backup}"
  [[ -t 0 ]] || die "恢复数据库前需要交互式确认。"
  local answer
  read -r -p "请输入 RESTORE-3XUI 继续：" answer
  [[ "$answer" == "RESTORE-3XUI" ]] || { warn "已取消。"; return 0; }
  xui_policy_stop_service
  if ! python3 "$XUI_POLICY_HELPER" restore-policy "$database" "$backup"; then
    xui_policy_start_service || true
    die "无法恢复 3X-UI policy 备份。"
  fi
  xui_policy_start_service || die "恢复后 3X-UI 未能正常重启。"
  log "已从以下备份恢复 3X-UI policy：${backup}"
}

xui_service_detected() {
  [[ -e /etc/x-ui/x-ui.db || -e /usr/local/x-ui/x-ui.db ||
    -e /etc/systemd/system/x-ui.service || -e /usr/lib/systemd/system/x-ui.service ]]
}

offer_xui_policy() {
  xui_service_detected || return 0
  log "检测到 3X-UI，可以直接调整 Xray 连接策略。"
  if [[ ! -t 0 ]]; then
    warn "当前为非交互模式，未打开 3X-UI 菜单；稍后执行 vps-init xui-policy 即可。"
    return 0
  fi
  local answer
  read -r -p "现在打开 3X-UI 参数菜单吗？[Y/n]: " answer
  case "${answer:-y}" in
    y|Y|yes|Yes|YES) xui_policy_menu ;;
    *) log "已跳过 3X-UI 参数菜单，稍后可执行：vps-init xui-policy" ;;
  esac
}

xui_policy_menu() {
  local choice seconds uplink downlink
  while true; do
    printf '\n========== 3X-UI / Xray 连接策略 ==========\n'
    printf '%s\n' \
      "  1. 查看当前 policy（只读）" \
      "  2. 稳定长连接：connIdle=300，uplinkOnly=2，downlinkOnly=5" \
      "  3. 1G 高并发：connIdle=120，uplinkOnly=2，downlinkOnly=5" \
      "  4. 自定义 policy 参数" \
      "  5. 恢复最近一次已验证备份" \
      "  0. 返回上一级"
    read -r -p "请选择 [0-5]: " choice
    case "$choice" in
      1)
        local database
        database=$(xui_policy_database) || die "找不到 3X-UI SQLite 数据库。"
        python3 "$XUI_POLICY_HELPER" show "$database"
        ;;
      2) xui_policy_apply 300 2 5 ;;
      3) xui_policy_apply 120 2 5 ;;
      4)
        read -r -p "请输入 connIdle 秒数 [60-86400]: " seconds
        read -r -p "请输入 uplinkOnly 秒数 [1-86400]: " uplink
        read -r -p "请输入 downlinkOnly 秒数 [1-86400]: " downlink
        [[ "$seconds" =~ ^[0-9]+$ && "$uplink" =~ ^[0-9]+$ && "$downlink" =~ ^[0-9]+$ ]] || { warn "参数必须是整数。"; continue; }
        (( seconds >= 60 && seconds <= 86400 && uplink >= 1 && uplink <= 86400 && downlink >= 1 && downlink <= 86400 )) || { warn "参数超出允许范围。"; continue; }
        xui_policy_apply "$seconds" "$uplink" "$downlink"
        ;;
      5) xui_policy_restore_latest ;;
      0) return 0 ;;
      *) warn "无效选项。" ;;
    esac
  done
}

xui_policy() {
  require_root
  require_supported_os
  local action=${1:-menu} database
  case "$action" in
    menu|select) xui_policy_menu ;;
    status)
      database=$(xui_policy_database) || die "找不到 3X-UI SQLite 数据库。"
      python3 "$XUI_POLICY_HELPER" show "$database"
      ;;
    stable) xui_policy_apply 300 2 5 ;;
    high-concurrency) xui_policy_apply 120 2 5 ;;
    set)
      [[ $# -ge 2 && $# -le 4 ]] || die "用法：vps-init xui-policy set CONN_IDLE [UPLINK_ONLY DOWNLINK_ONLY]"
      [[ "$2" =~ ^[0-9]+$ ]] || die "connIdle 必须是整数。"
      local uplink=${3:-2} downlink=${4:-5}
      [[ "$uplink" =~ ^[0-9]+$ && "$downlink" =~ ^[0-9]+$ ]] || die "uplinkOnly/downlinkOnly 必须是整数。"
      (( 60 <= 10#$2 && 10#$2 <= 86400 && 1 <= 10#$uplink && 10#$uplink <= 86400 && 1 <= 10#$downlink && 10#$downlink <= 86400 )) || die "policy 参数超出允许范围。"
      xui_policy_apply "$2" "$uplink" "$downlink"
      ;;
    restore) xui_policy_restore_latest ;;
    *) die "用法：vps-init xui-policy [status|stable|high-concurrency|set|restore|menu]" ;;
  esac
}

restore_conflict_backups() {
  local filename backup
  local restored=0
  local backup_root="/var/lib/vps-init-suite/backups"
  [[ -d "$backup_root" ]] || return 0

  for filename in "${CONFLICT_FILES[@]}"; do
    [[ "$filename" == "$(basename "$SYSCTL_FILE")" ]] && continue
    backup=$(find_latest_unmanaged_backup "$filename" "$backup_root")
    [[ -n "$backup" && ! -e "/etc/sysctl.d/${filename}" ]] || continue
    cp -a -- "$backup" "/etc/sysctl.d/${filename}"
    restored=$((restored + 1))
  done
  if (( restored > 0 )); then
    log "Restored ${restored} backed-up third-party sysctl fragment(s). Review them for conflicts before reapplying tuning."
  fi

}

restore_original_managed_files() {
  local path filename marker original backup
  for path in "$SYSCTL_FILE" "$SWAP_SYSCTL_FILE" "$SYSCTL_UNIT" "$MSS_UNIT" "$MSS_TIMER" "$SYSTEMD_TIMEOUT_FILE" \
    /etc/modules-load.d/vps-init-suite.conf "$MSS_CONFIG" "$MSS_HELPER" \
    "$TUNING_CONFIG" "$XUI_POLICY_HELPER" "$XUI_LIMITS_FILE" "$INSTALLED_SCRIPT" "$LAUNCHER_PATH"; do
    filename=$(basename "$path")
    marker="${STATE_DIR}/original-${filename}.present"
    original="${STATE_DIR}/original-${filename}"
    if [[ -e "$marker" && -e "$original" ]] && ! is_suite_managed_file "$original"; then
      mkdir -p "$(dirname "$path")"
      cp -a -- "$original" "$path"
      log "Restored pre-existing ${filename}. Inspect it for conflicting tuning values."
    elif [[ ! -e "$path" ]] && backup=$(find_latest_unmanaged_backup "$filename"); then
      if [[ -n "$backup" ]]; then
        cp -a -- "$backup" "$path"
        warn "Restored legacy backup ${filename}; inspect it for conflicts."
      fi
    fi
  done
}

restore_original_sysctl_state() {
  local line key value
  [[ -r "$ORIGINAL_SYSCTL_STATE" ]] || return 0
  while IFS= read -r line; do
    [[ "$line" == *=* ]] || continue
    key=${line%%=*}
    value=${line#*=}
    key=${key//[[:space:]]/}
    value=${value# }
    sysctl -w "${key}=${value}" >/dev/null 2>&1 || warn "Could not restore runtime sysctl ${key}."
  done <"$ORIGINAL_SYSCTL_STATE"
}

remove_managed_swap() {
  local used_bytes="0"
  [[ -e "${STATE_DIR}/managed-swap.present" ]] || die "The swap file is not verified as suite-managed; refusing to remove it."
  if [[ -e "$SWAP_FILE" ]]; then
    used_bytes=$(swapon --show=NAME,USED --bytes --noheadings --raw 2>/dev/null | awk -v file="$SWAP_FILE" '$1 == file {sum += $2} END {print sum + 0}')
    if (( used_bytes > 0 )); then
      die "Managed swap is in use (${used_bytes} bytes). Keep it, or free memory and run 'swapoff ${SWAP_FILE}' manually before uninstalling with --remove-swap."
    fi
    if swapon --show=NAME --noheadings --raw | grep -Fxq "$SWAP_FILE"; then
      swapoff "$SWAP_FILE"
    fi
    rm -f -- "$SWAP_FILE"
  fi
  sed -i '\|^/swapfile-vps-init-suite none swap sw 0 0$|d' /etc/fstab
  rm -f -- "${STATE_DIR}/managed-swap.present"
  log "Managed swap file and fstab entry removed."
}

remove_managed_mss_rules() {
  local config_path=${1:-$MSS_CONFIG}
  local binary chain mode value value6
  local -a rule_args=()
  mode=$(awk -F= '$1 == "MSS_MODE" {print $2; exit}' "$config_path" 2>/dev/null || true)
  value=$(awk -F= '$1 == "MSS_VALUE" {print $2; exit}' "$config_path" 2>/dev/null || true)
  value6=$(awk -F= '$1 == "MSS_VALUE6" {print $2; exit}' "$config_path" 2>/dev/null || true)
  for binary in iptables ip6tables; do
    command -v "$binary" >/dev/null || continue
    "$binary" -w 5 -t mangle -S >/dev/null 2>&1 || continue
    # Remove both current and legacy suite attachments during uninstall.
    for chain in OUTPUT FORWARD; do
      while "$binary" -w 5 -t mangle -C "$chain" -p tcp --tcp-flags SYN,RST SYN -m comment --comment vps-init-suite -j VPS_INIT_MSS 2>/dev/null; do
        "$binary" -w 5 -t mangle -D "$chain" -p tcp --tcp-flags SYN,RST SYN -m comment --comment vps-init-suite -j VPS_INIT_MSS || break
      done
    done
    if "$binary" -w 5 -t mangle -S VPS_INIT_MSS >/dev/null 2>&1; then
      rule_args=()
      case "$mode:$binary" in
        clamp:*) rule_args=(-p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu) ;;
        fixed:iptables|fixed:ip6tables)
          if [[ "$value" =~ ^[0-9]+$ ]]; then
            rule_args=(-p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$value")
          fi
          ;;
        dual-fixed:iptables)
          if [[ "$value" =~ ^[0-9]+$ ]]; then
            rule_args=(-p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$value")
          fi
          ;;
        dual-fixed:ip6tables)
          if [[ "$value6" =~ ^[0-9]+$ ]]; then
            rule_args=(-p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$value6")
          fi
          ;;
      esac
      while ((${#rule_args[@]})) && "$binary" -w 5 -t mangle -C VPS_INIT_MSS "${rule_args[@]}" 2>/dev/null; do
        "$binary" -w 5 -t mangle -D VPS_INIT_MSS "${rule_args[@]}" || break
      done
      if [[ -z $("$binary" -w 5 -t mangle -S VPS_INIT_MSS 2>/dev/null | sed -n '2p') ]]; then
        "$binary" -w 5 -t mangle -X VPS_INIT_MSS || true
      else
        warn "Leaving non-suite rules in ${binary}'s VPS_INIT_MSS chain untouched."
      fi
    fi
  done
}

remove_managed_file() {
  local path=$1
  [[ -e "$path" || -L "$path" ]] || return 0
  if [[ "$path" == "$LAUNCHER_PATH" ]]; then
    if [[ -L "$path" && $(readlink -f -- "$path") == "$INSTALLED_SCRIPT" ]]; then
      rm -f -- "$path"
    else
      warn "Leaving unrelated shortcut path untouched: ${path}"
    fi
  elif is_suite_managed_file "$path"; then
    rm -f -- "$path"
  else
    warn "Leaving unrecognized file untouched: ${path}"
  fi
}

uninstall_suite() {
  require_root
  require_supported_os
  local remove_swap=0
  local assume_yes=0
  local option
  for option in "$@"; do
    case "$option" in
      --remove-swap) remove_swap=1 ;;
      --yes) assume_yes=1 ;;
      *) die "Unknown uninstall option: ${option}" ;;
    esac
  done

  warn "This removes vps-init-suite services, sysctl files, MSS rules, and the vps-init command."
  if (( remove_swap )); then
    warn "--remove-swap also deletes the managed swap file; this is blocked if swap is in use."
  else
    log "Managed swap will be preserved by default."
  fi

  if (( ! assume_yes )); then
    [[ -t 0 ]] || die "Interactive confirmation required. Use 'uninstall --yes' (and optionally --remove-swap)."
    read -r -p "Type REMOVE-VPS-INIT to continue: " answer
    [[ "$answer" == "REMOVE-VPS-INIT" ]] || { warn "Cancelled."; return 0; }
  fi

  if (( remove_swap )); then
    remove_managed_swap
  fi

  remove_managed_mss_rules
  if is_suite_managed_file "$MSS_UNIT"; then
    systemctl disable --now vps-init-suite-mss.service >/dev/null 2>&1 || true
  fi
  if is_suite_managed_file "$MSS_TIMER"; then
    systemctl disable --now vps-init-suite-mss.timer >/dev/null 2>&1 || true
  fi
  if is_suite_managed_file "$SYSCTL_UNIT"; then
    systemctl disable --now vps-init-suite-sysctl.service >/dev/null 2>&1 || true
  fi
  local managed_path
  for managed_path in "$MSS_UNIT" "$MSS_TIMER" "$SYSCTL_UNIT" \
    "$SYSTEMD_TIMEOUT_FILE" \
    /etc/modules-load.d/vps-init-suite.conf \
    "$SYSCTL_FILE" "$SWAP_SYSCTL_FILE" "$TUNING_CONFIG" \
    "$MSS_CONFIG" "$MSS_HELPER" "$XUI_POLICY_HELPER" "$XUI_LIMITS_FILE" \
    "$LAUNCHER_PATH" "$INSTALLED_SCRIPT"; do
    remove_managed_file "$managed_path"
  done
  rmdir "$XUI_LIMITS_DIR" 2>/dev/null || true
  systemctl daemon-reload
  systemctl reset-failed vps-init-suite-mss.service vps-init-suite-sysctl.service >/dev/null 2>&1 || true

  restore_conflict_backups
  restore_original_managed_files
  if ! sysctl -e --system >/dev/null 2>&1; then
    warn "Some remaining sysctl values could not be reapplied; review 'sysctl --system'."
  fi
  if [[ -e "${STATE_DIR}/initial-sysctl-unavailable" ]]; then
    warn "Runtime sysctl baseline was not recorded by the older installation; restart to load the restored configuration files."
  else
    restore_original_sysctl_state
  fi
  rm -f -- "$ORIGINAL_SYSCTL_STATE" "${STATE_DIR}/initial-sysctl-unavailable" "$STATE_DIR"/original-*
  rmdir "$STATE_DIR" 2>/dev/null || true
  rmdir "$INSTALL_DIR" 2>/dev/null || true
  log "vps-init-suite has been uninstalled. Backups remain under /var/lib/vps-init-suite/backups."
}

install_shortcut() {
  require_root
  require_supported_os
  local source_path=${BASH_SOURCE[0]:-}
  local temporary

  assert_not_symlink "$INSTALLED_SCRIPT"
  capture_original_managed_file "$INSTALLED_SCRIPT"
  capture_original_managed_file "$LAUNCHER_PATH"
  mkdir -p "$INSTALL_DIR" "$(dirname "$LAUNCHER_PATH")"
  temporary=$(mktemp "${INSTALL_DIR}/setup.sh.XXXXXX")

  if [[ -n "$source_path" && "$source_path" != "bash" && "$source_path" != "/dev/stdin" && -f "$source_path" ]]; then
    install -m 0755 "$source_path" "$temporary"
  else
    apt_install ca-certificates curl
    if ! curl --location --proto '=https' --proto-redir '=https' --tlsv1.2 --silent --show-error --fail \
      "$(github_raw_url setup.sh)" -o "$temporary"; then
      rm -f -- "$temporary"
      die "Could not download the latest setup script."
    fi
    chmod 0755 "$temporary"
  fi

  if ! bash -n "$temporary"; then
    rm -f -- "$temporary"
    die "Downloaded setup script failed its Bash syntax check."
  fi
  mv -f -- "$temporary" "$INSTALLED_SCRIPT"
  ln -sfn "$INSTALLED_SCRIPT" "$LAUNCHER_PATH"
  migrate_legacy_boot_services
  log "Shortcut installed: ${LAUNCHER_NAME} (privileged actions will request sudo automatically)"
}

full_init() {
  local timezone=${1:-${VPS_TIMEZONE:-auto}}
  local ipv6_mode=${2:-${VPS_IPV6:-}}
  local conntrack_mode=${3:-${VPS_CONNTRACK:-auto}}
  local bandwidth=${4:-${VPS_BANDWIDTH_MBPS:-}}
  local rtt=${5:-${VPS_RTT_MS:-}}
  require_root
  require_supported_os
  tune_kernel "$ipv6_mode" "$conntrack_mode" "$bandwidth" "$rtt"
  setup_timezone "$timezone"
  setup_swap
  setup_mss clamp
  install_shortcut
  log "VPS 初始化完成。"
  show_status
  offer_xui_policy
}

update_self() {
  require_root
  require_supported_os
  apt_install ca-certificates curl git
  local script_dir
  script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

  if [[ -d "$script_dir/.git" ]]; then
    git -C "$script_dir" pull --ff-only
    if [[ -L "$LAUNCHER_PATH" ]]; then
      install_shortcut
    fi
    log "Repository updated. Re-run the command to apply changes."
    return 0
  fi

  local target
  if [[ $(readlink -f -- "${BASH_SOURCE[0]}") == "$INSTALLED_SCRIPT" ]]; then
    target="$INSTALLED_SCRIPT"
  else
    target="${PWD}/setup.sh"
  fi
  assert_not_symlink "$target"
  local temporary
  temporary=$(mktemp "$(dirname -- "$target")/.setup.sh.XXXXXX")
  if ! curl --proto '=https' --proto-redir '=https' --tlsv1.2 --silent --show-error --fail --location \
    "$(github_raw_url setup.sh)" -o "$temporary"; then
    rm -f -- "$temporary"
    die "Could not download the latest setup script."
  fi
  if ! bash -n "$temporary"; then
    rm -f -- "$temporary"
    die "Downloaded setup script failed its Bash syntax check."
  fi
  chmod 0755 "$temporary"
  mv -f -- "$temporary" "$target"
  migrate_legacy_boot_services
  log "Downloaded the latest script to ${target}."
}

usage() {
  cat <<'EOF'
Usage: setup.sh <command> [option]

Commands:
  full [auto|keep|ZONE] [on|off] [auto|on|off] [Mbps] [RTT_MS]
                           Apply defaults; IPv6 off, conntrack auto, bandwidth auto
  kernel [on|off] [auto|on|off] [Mbps] [RTT_MS]
                           Apply BBR, FQ, TCP, and BDP-sized buffers
  ipv6 [on|off]            Enable or disable IPv6 forwarding (default: off)
  conntrack [auto|on|off]  Select conntrack for NAT/firewall or proxy-only mode
  bandwidth [Mbps|auto] [RTT_MS|auto]
                           Save bandwidth/RTT buffer profile without changing MSS
  mss [clamp|dual-fixed|1200..1460] Persist MSS policy (default: clamp)
  swap                     Create managed 2/4 GiB swap if none exists
  timezone [auto|keep|ZONE] Detect, retain, or set an IANA timezone
  install                  Install the 'vps-init' shortcut command
  select                   Choose an action interactively
  status                   Show current settings
  diagnose                 Show CPU, retransmission, softirq, and conntrack counters
  uninstall [--remove-swap] Remove suite (preserves swap by default)
  remove                   Alias for uninstall
  uninstall-3xui [--yes]   Permanently remove 3X-UI and known data paths
  xui-policy [action]      Inspect or tune 3X-UI Xray connection policy
  update                   Download or pull the latest project version
  upgrade                  Alias for update
  menu                     Open the interactive menu
  version                  Print the installed script version
EOF
}

pause_menu() {
  if [[ -t 0 ]]; then
    read -r -p "Press Enter to return to the menu..." _ || true
  fi
}

menu() {
  while true; do
    [[ -t 1 ]] && clear
    printf '%s\n' "VPS 初始化与内核调优工具 v${SCRIPT_VERSION}"
    show_status
    cat <<'EOF'
  1. 完整初始化（推荐）
  2. 内核与网络调优
  3. MSS 自动钳制（clamp-to-PMTU）
  4. 固定 MSS 1380
  5. 创建 SWAP
  6. 自动探测时区并启用网络校时
  7. 卸载 3X-UI
  8. 升级/下载最新版脚本
  9. 安装/修复快捷命令（vps-init）
 10. 开启 IPv6 转发
 11. 关闭 IPv6 转发
 12. 卸载 vps-init-suite（保留 SWAP）
  13. 3X-UI / Xray 连接策略
 14. 手动设置/修改带宽与 RTT
 15. 网络/CPU 诊断
 16. 退出（也可输入 0）
EOF
    read -r -p "请选择 [0-16]: " choice
    case "$choice" in
      1) full_init; pause_menu ;;
      2) tune_kernel; pause_menu ;;
      3) setup_mss clamp; pause_menu ;;
      4) setup_mss 1380; pause_menu ;;
      5) setup_swap; pause_menu ;;
      6) setup_timezone auto; pause_menu ;;
      7) uninstall_3xui; pause_menu ;;
      8) update_self; pause_menu ;;
      9) install_shortcut; pause_menu ;;
      10) tune_kernel on; pause_menu ;;
      11) tune_kernel off; pause_menu ;;
      12) uninstall_suite; return $? ;;
      13) xui_policy_menu ;;
      14) configure_bandwidth_profile; pause_menu ;;
      15) diagnose_system; pause_menu ;;
      16|0) return 0 ;;
      *) warn "无效选项。"; pause_menu ;;
    esac
  done
}

select_menu() {
  local choice
  while true; do
    printf '\nVPS Init - 请选择操作\n'
    printf '%s\n' \
      "  1. 完整初始化" \
      "  2. 内核设置（含 IPv6 选择）" \
      "  3. 时区与网络校时" \
      "  4. 没有 SWAP 时创建 SWAP" \
      "  5. 配置 MSS 自动钳制" \
      "  6. 安装/刷新 vps-init 快捷命令" \
      "  7. 查看当前状态" \
      "  8. 升级/下载最新版脚本" \
      "  9. 安装/修复快捷命令" \
      " 10. 开启 IPv6 转发" \
      " 11. 关闭 IPv6 转发" \
      " 12. 卸载套件（保留 SWAP）" \
      " 13. 卸载套件并删除受管 SWAP" \
      " 14. 3X-UI / Xray 连接策略" \
      " 15. 手动设置/修改带宽与 RTT" \
      " 16. 网络/CPU 诊断" \
      "  0. 退出"
    read -r -p "请选择 [0-16]: " choice
    case "$choice" in
      1) full_init ;;
      2) tune_kernel ;;
      3) setup_timezone auto ;;
      4) setup_swap ;;
      5) setup_mss clamp ;;
      6) install_shortcut ;;
      7) show_status ;;
      8) update_self ;;
      9) install_shortcut ;;
      10) tune_kernel on ;;
      11) tune_kernel off ;;
      12) uninstall_suite; return $? ;;
      13) uninstall_suite --remove-swap; return $? ;;
      14) xui_policy_menu ;;
      15) configure_bandwidth_profile ;;
      16) diagnose_system ;;
      0) return 0 ;;
      *) warn "无效选项。" ;;
    esac
  done
}

main() {
  if [[ ${EUID} -ne 0 ]] && is_root_command "${1:-menu}"; then
    reexec_as_root "$@"
  fi
  case "${1:-menu}" in
    full) full_init "${2:-${VPS_TIMEZONE:-auto}}" "${3:-${VPS_IPV6:-}}" "${4:-${VPS_CONNTRACK:-auto}}" "${5:-${VPS_BANDWIDTH_MBPS:-}}" "${6:-${VPS_RTT_MS:-}}" ;;
    kernel) tune_kernel "${2:-${VPS_IPV6:-}}" "${3:-${VPS_CONNTRACK:-auto}}" "${4:-${VPS_BANDWIDTH_MBPS:-}}" "${5:-${VPS_RTT_MS:-}}" ;;
    ipv6) tune_kernel "${2:-}" ;;
    conntrack) tune_kernel "${VPS_IPV6:-}" "${2:-auto}" ;;
    bandwidth) configure_bandwidth_profile "${2:-}" "${3:-}" ;;
    mss) setup_mss "${2:-clamp}" ;;
    swap) setup_swap ;;
    timezone) setup_timezone "${2:-auto}" ;;
    install|shortcut) install_shortcut ;;
    select|choose) select_menu ;;
    uninstall|remove) uninstall_suite "${@:2}" ;;
    status) show_status ;;
    diagnose) diagnose_system ;;
    uninstall-3xui) uninstall_3xui "${2:-}" ;;
    xui-policy|xray-policy) xui_policy "${@:2}" ;;
    update|upgrade) update_self ;;
    menu) menu ;;
    version|--version|-v) printf '%s\n' "$SCRIPT_VERSION" ;;
    help|--help|-h) usage ;;
    *) usage; exit 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
