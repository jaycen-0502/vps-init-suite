#!/usr/bin/env bash

set -Eeuo pipefail

readonly VERSION="1.1.1"
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
readonly MSS_HELPER="/usr/local/lib/vps-init-suite/apply-mss.sh"
readonly MSS_UNIT="/etc/systemd/system/vps-init-suite-mss.service"

if [[ -t 1 ]]; then
  readonly RED=$'\033[31m'
  readonly GREEN=$'\033[32m'
  readonly YELLOW=$'\033[33m'
  readonly RESET=$'\033[0m'
else
  readonly RED="" GREEN="" YELLOW="" RESET=""
fi

APT_UPDATED=0

log() { printf '%s\n' "${GREEN}$*${RESET}"; }
warn() { printf '%s\n' "${YELLOW}$*${RESET}" >&2; }
die() { printf '%s\n' "${RED}Error: $*${RESET}" >&2; exit 1; }

on_error() {
  local exit_code=$?
  printf '%s\n' "${RED}Failed at line ${BASH_LINENO[0]} (exit ${exit_code}).${RESET}" >&2
  exit "$exit_code"
}
trap on_error ERR

require_root() {
  [[ ${EUID} -eq 0 ]] || die "Run this command as root (for example: sudo ./setup.sh full)."
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

apt_install() {
  if [[ $APT_UPDATED -eq 0 ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y
    APT_UPDATED=1
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

backup_existing() {
  local path=$1
  [[ -e "$path" ]] || return 0
  local backup_dir
  backup_dir="/var/lib/vps-init-suite/backups/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"
  cp -a "$path" "$backup_dir/$(basename "$path")"
  warn "Backed up ${path} to ${backup_dir}."
}

show_status() {
  local timezone="unavailable"
  local swap="none"
  local mss="not configured"

  if command -v timedatectl >/dev/null; then
    timezone=$(timedatectl show --property=Timezone --value 2>/dev/null || true)
  fi
  if command -v swapon >/dev/null && [[ -n $(swapon --show=NAME --noheadings 2>/dev/null) ]]; then
    swap=$(free -h | awk '/^Swap:/ {print $2 " total, " $3 " used"}')
  fi
  if command -v iptables >/dev/null && iptables -w 2 -t mangle -S VPS_INIT_MSS >/dev/null 2>&1; then
    mss=$(awk -F= '/^MSS_MODE=/{mode=$2} /^MSS_VALUE=/{value=$2} END {if (mode == "fixed") print mode " (" value ")"; else print mode}' "$MSS_CONFIG" 2>/dev/null || true)
  fi

  printf '%s\n' "------------------------------------------------------------"
  printf 'Version:                 %s\n' "$VERSION"
  printf 'Shortcut command:        %s\n' "$LAUNCHER_NAME"
  printf 'Congestion control:      %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unavailable)"
  printf 'Default qdisc:           %s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unavailable)"
  printf 'TCP Fast Open:           %s (target: 3)\n' "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo unavailable)"
  printf 'Timezone:                %s\n' "${timezone:-unavailable}"
  printf 'Swap:                    %s\n' "$swap"
  printf 'MSS policy:              %s\n' "${mss:-configured}"
  printf '%s\n' "------------------------------------------------------------"
}

tune_kernel() {
  require_root
  require_supported_os
  apt_install kmod procps

  modprobe tcp_bbr 2>/dev/null || true
  if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    die "This kernel does not expose BBR. Upgrade the kernel before applying this profile."
  fi

  backup_existing "$SYSCTL_FILE"
  cat >"$SYSCTL_FILE" <<'EOF'
# Managed by vps-init-suite.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.ip_forward = 1
EOF

  cat >/etc/modules-load.d/vps-init-suite.conf <<'EOF'
tcp_bbr
EOF

  cat >"$SYSCTL_UNIT" <<EOF
[Unit]
Description=Apply vps-init-suite kernel parameters
After=systemd-sysctl.service
Before=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/sysctl -p ${SYSCTL_FILE}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  sysctl -p "$SYSCTL_FILE"
  systemctl daemon-reload
  systemctl enable vps-init-suite-sysctl.service >/dev/null
  log "Kernel profile applied and enabled at boot."
}

is_valid_timezone() {
  local timezone=$1
  local known_timezones
  [[ "$timezone" =~ ^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)+$ ]] || return 1
  known_timezones=$(timedatectl list-timezones 2>/dev/null) || return 1
  grep -Fxq -- "$timezone" <<<"$known_timezones"
}

fetch_timezone_text() {
  local url=$1
  local response
  response=$(curl --proto '=https' --tlsv1.2 --silent --show-error --fail \
    --connect-timeout 3 --max-time 6 --retry 1 "$url" 2>/dev/null) || return 1
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
    --connect-timeout 3 --max-time 6 --retry 1 "$url" 2>/dev/null) || return 1
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
Automatic timezone detection failed. Select a fallback:
  1. Keep the current timezone
  2. UTC
  3. Asia/Tokyo
  4. America/Los_Angeles
  5. America/New_York
  6. Europe/London
  7. Asia/Singapore
  8. Enter another IANA timezone
EOF
  read -r -p "Select [1-8]: " choice
  case "$choice" in
    1) printf '%s\n' "keep" ;;
    2) printf '%s\n' "Etc/UTC" ;;
    3) printf '%s\n' "Asia/Tokyo" ;;
    4) printf '%s\n' "America/Los_Angeles" ;;
    5) printf '%s\n' "America/New_York" ;;
    6) printf '%s\n' "Europe/London" ;;
    7) printf '%s\n' "Asia/Singapore" ;;
    8)
      read -r -p "IANA timezone (for example Europe/Berlin): " custom_timezone
      is_valid_timezone "$custom_timezone" || die "Unknown IANA timezone: ${custom_timezone}"
      printf '%s\n' "$custom_timezone"
      ;;
    *) printf '%s\n' "keep" ;;
  esac
}

enable_network_time() {
  if ! timedatectl set-ntp true 2>/dev/null; then
    apt_install systemd-timesyncd
    systemctl enable --now systemd-timesyncd.service
    timedatectl set-ntp true
  fi
}

setup_timezone() {
  require_root
  require_supported_os
  local requested=${1:-auto}
  local timezone

  apt_install ca-certificates curl jq tzdata
  if [[ "$requested" == "auto" ]]; then
    warn "Detecting timezone from the VPS public network egress..."
    if timezone=$(detect_public_timezone); then
      log "Detected IANA timezone: ${timezone}"
    elif [[ -t 0 ]]; then
      timezone=$(choose_timezone_interactively)
    else
      timezone="keep"
      warn "Timezone detection failed in non-interactive mode; keeping the current timezone."
    fi
  elif [[ "$requested" == "keep" ]]; then
    timezone="keep"
  else
    timezone=$requested
    is_valid_timezone "$timezone" || die "Unknown IANA timezone: ${timezone}"
  fi

  if [[ "$timezone" != "keep" ]]; then
    timedatectl set-timezone "$timezone"
    log "Timezone set to ${timezone}."
  else
    warn "Keeping the current system timezone."
  fi
  enable_network_time
  log "Network time synchronization enabled. Current local time: $(date '+%Y-%m-%d %H:%M:%S %Z')"
}

setup_swap() {
  require_root
  require_supported_os
  apt_install util-linux

  if [[ -n $(swapon --show=NAME --noheadings 2>/dev/null) ]]; then
    warn "An active swap device already exists; leaving it unchanged."
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
    warn "Recreating inactive managed swap file ${SWAP_FILE}."
    rm -f -- "$SWAP_FILE"
  fi
  if ! fallocate -l "${swap_gib}G" "$SWAP_FILE"; then
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$((swap_gib * 1024)) status=progress
  fi
  chmod 600 "$SWAP_FILE"
  mkswap "$SWAP_FILE"
  swapon "$SWAP_FILE"
  grep -qF "$SWAP_FILE none swap sw 0 0" /etc/fstab || printf '%s\n' "$SWAP_FILE none swap sw 0 0" >>/etc/fstab

  cat >"$SWAP_SYSCTL_FILE" <<'EOF'
# Managed by vps-init-suite.
vm.swappiness = 10
EOF
  sysctl -p "$SWAP_SYSCTL_FILE"
  log "Created ${swap_gib} GiB swap with swappiness 10."
}

write_mss_helper() {
  mkdir -p "$(dirname "$MSS_HELPER")"
  cat >"$MSS_HELPER" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source /etc/default/vps-init-suite

apply_family() {
  local binary=$1
  local chain
  command -v "$binary" >/dev/null || return 0

  "$binary" -w 5 -t mangle -N VPS_INIT_MSS 2>/dev/null || true
  "$binary" -w 5 -t mangle -F VPS_INIT_MSS

  if [[ "$MSS_MODE" == "fixed" ]]; then
    "$binary" -w 5 -t mangle -A VPS_INIT_MSS -j TCPMSS --set-mss "$MSS_VALUE"
  else
    "$binary" -w 5 -t mangle -A VPS_INIT_MSS -j TCPMSS --clamp-mss-to-pmtu
  fi

  for chain in OUTPUT FORWARD; do
    if ! "$binary" -w 5 -t mangle -C "$chain" -p tcp --tcp-flags SYN,RST SYN -m comment --comment vps-init-suite -j VPS_INIT_MSS 2>/dev/null; then
      "$binary" -w 5 -t mangle -I "$chain" 1 -p tcp --tcp-flags SYN,RST SYN -m comment --comment vps-init-suite -j VPS_INIT_MSS
    fi
  done
}

apply_family iptables
apply_family ip6tables
EOF
  chmod 0755 "$MSS_HELPER"
}

setup_mss() {
  require_root
  require_supported_os
  local requested=${1:-clamp}
  local mode value

  if [[ "$requested" == "clamp" ]]; then
    mode="clamp"
    value="1380"
  elif [[ "$requested" =~ ^[0-9]+$ ]] && (( 10#$requested >= 1200 && 10#$requested <= 1460 )); then
    mode="fixed"
    value=$((10#$requested))
  else
    die "MSS must be 'clamp' or a value from 1200 through 1460."
  fi

  apt_install iptables
  cat >"$MSS_CONFIG" <<EOF
MSS_MODE=${mode}
MSS_VALUE=${value}
EOF
  write_mss_helper

  cat >"$MSS_UNIT" <<EOF
[Unit]
Description=Apply vps-init-suite TCP MSS policy
After=network-pre.target
Before=network-online.target

[Service]
Type=oneshot
ExecStart=${MSS_HELPER}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable vps-init-suite-mss.service >/dev/null
  systemctl restart vps-init-suite-mss.service
  if [[ "$mode" == "fixed" ]]; then
    log "Persistent MSS policy applied with fixed value ${value}."
  else
    log "Persistent path-MTU MSS clamping applied."
  fi
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

install_shortcut() {
  require_root
  require_supported_os
  local source_path=${BASH_SOURCE[0]:-}
  local temporary

  mkdir -p "$INSTALL_DIR" "$(dirname "$LAUNCHER_PATH")"
  temporary=$(mktemp "${INSTALL_DIR}/setup.sh.XXXXXX")

  if [[ -n "$source_path" && "$source_path" != "bash" && "$source_path" != "/dev/stdin" && -f "$source_path" ]]; then
    install -m 0755 "$source_path" "$temporary"
  else
    apt_install ca-certificates curl
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 --silent --show-error --fail \
      "https://raw.githubusercontent.com/${REPO_SLUG}/main/setup.sh" -o "$temporary"
    chmod 0755 "$temporary"
  fi

  bash -n "$temporary"
  mv -f -- "$temporary" "$INSTALLED_SCRIPT"
  ln -sfn "$INSTALLED_SCRIPT" "$LAUNCHER_PATH"
  log "Shortcut installed: sudo ${LAUNCHER_NAME}"
}

full_init() {
  local timezone=${1:-${VPS_TIMEZONE:-auto}}
  require_root
  require_supported_os
  tune_kernel
  setup_timezone "$timezone"
  setup_swap
  setup_mss clamp
  install_shortcut
  log "VPS initialization completed."
  show_status
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
  local temporary
  temporary=$(mktemp)
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 --silent --show-error --fail --location \
    "https://raw.githubusercontent.com/${REPO_SLUG}/main/setup.sh" -o "$temporary"
  bash -n "$temporary"
  install -m 0755 "$temporary" "$target"
  rm -f -- "$temporary"
  log "Downloaded the latest script to ${target}."
}

usage() {
  cat <<'EOF'
Usage: setup.sh <command> [option]

Commands:
  full [auto|keep|ZONE]    Apply all defaults; auto-detect timezone
  kernel                   Apply BBR, FQ, TFO, and TCP buffer settings
  mss [clamp|1200..1460]   Persist MSS clamping (default: clamp)
  swap                     Create managed 2/4 GiB swap if none exists
  timezone [auto|keep|ZONE] Detect, retain, or set an IANA timezone
  install                  Install the 'vps-init' shortcut command
  status                   Show current settings
  uninstall-3xui [--yes]   Permanently remove 3X-UI and known data paths
  update                   Download or pull the latest project version
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
    printf '%s\n' "VPS Initialization & Kernel Tuning Suite v${VERSION}"
    show_status
    cat <<'EOF'
  1. Full initialization (recommended)
  2. Kernel and network tuning
  3. MSS clamp-to-PMTU
  4. Fixed MSS 1380
  5. Create swap
  6. Auto-detect timezone and enable NTP
  7. Remove 3X-UI
  8. Update this project
  9. Install/refresh shortcut (vps-init)
  0. Exit
EOF
    read -r -p "Select [0-9]: " choice
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
      0) return 0 ;;
      *) warn "Invalid choice."; pause_menu ;;
    esac
  done
}

main() {
  case "${1:-menu}" in
    full) full_init "${2:-${VPS_TIMEZONE:-auto}}" ;;
    kernel) tune_kernel ;;
    mss) setup_mss "${2:-clamp}" ;;
    swap) setup_swap ;;
    timezone) setup_timezone "${2:-auto}" ;;
    install|shortcut) install_shortcut ;;
    status) show_status ;;
    uninstall-3xui) uninstall_3xui "${2:-}" ;;
    update) update_self ;;
    menu) menu ;;
    version|--version|-v) printf '%s\n' "$VERSION" ;;
    help|--help|-h) usage ;;
    *) usage; exit 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
