#!/usr/bin/env bash

set -Eeuo pipefail

TEST_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly TEST_ROOT

# shellcheck disable=SC1091
source "$TEST_ROOT/setup.sh"

assert_equal() {
  local expected=$1
  local actual=$2
  [[ "$actual" == "$expected" ]] || {
    printf 'Expected %s, got %s\n' "$expected" "$actual" >&2
    exit 1
  }
}

assert_equal "4" "$(buffer_profile 1024)"
assert_equal "4" "$(buffer_profile 1499)"
assert_equal "16" "$(buffer_profile 1500)"
assert_equal "16" "$(buffer_profile 4096)"
assert_equal "8" "$(memory_buffer_cap_mib 1024)"
assert_equal "12" "$(memory_buffer_cap_mib 1499)"
assert_equal "16" "$(memory_buffer_cap_mib 2048)"
assert_equal "32" "$(memory_buffer_cap_mib 4096)"
assert_equal "64" "$(memory_buffer_cap_mib 8192)"
assert_equal "64" "$(memory_buffer_cap_mib 16384)"
assert_equal "4194304" "$(calculate_buffer_max 100 160 1024)"
assert_equal "8388608" "$(calculate_buffer_max 200 160 1024)"
assert_equal "16777216" "$(calculate_buffer_max 500 160 4096)"
assert_equal "262144" "$(proxy_nofile_limit 1024)"
assert_equal "524288" "$(proxy_nofile_limit 4096)"
assert_equal "on" "$(normalize_ipv6_mode on)"
assert_equal "on" "$(normalize_ipv6_mode enabled)"
assert_equal "off" "$(normalize_ipv6_mode disabled)"
assert_equal "off" "$(resolve_ipv6_mode "")"
assert_equal "on" "$(resolve_ipv6_mode on)"
assert_equal "auto" "$(normalize_conntrack_mode auto)"
assert_equal "on" "$(normalize_conntrack_mode on)"
assert_equal "off" "$(normalize_conntrack_mode off)"
assert_equal "off" "$(resolve_conntrack_mode off)"
sysctl() {
  [[ "${1:-}" == "-n" ]] || return 1
  printf '%s\n' "${MOCK_SYSCTL_VALUE:-}"
}
MOCK_SYSCTL_VALUE=bbr
verify_sysctl_value net.ipv4.tcp_congestion_control bbr
MOCK_SYSCTL_VALUE=cubic
if verify_sysctl_value net.ipv4.tcp_congestion_control bbr; then
  printf '%s\n' "mismatched runtime sysctl value passed verification" >&2
  exit 1
fi
is_root_command uninstall
is_root_command select
if is_root_command status; then
  printf '%s\n' "read-only status unexpectedly requires root" >&2
  exit 1
fi
if normalize_ipv6_mode maybe >/dev/null 2>&1; then
  printf '%s\n' "invalid IPv6 mode was accepted" >&2
  exit 1
fi

TEST_TEMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_TEMP_DIR"' EXIT
PROMPT_INPUTS=(invalid 0200 0160)
PROMPT_INDEX=0
PROMPT_TEXTS=()
read() {
  local prompt target has_prompt=0 arg
  for arg in "$@"; do
    [[ "$arg" == "-p" ]] && has_prompt=1
  done
  if (( !has_prompt )); then
    builtin read "$@"
    return $?
  fi
  while (($#)); do
    case "$1" in
      -r) shift ;;
      -p) prompt=$2; shift 2 ;;
      *) target=$1; shift ;;
    esac
  done
  PROMPT_TEXTS+=("$prompt")
  printf -v "$target" '%s' "${PROMPT_INPUTS[PROMPT_INDEX]}"
  PROMPT_INDEX=$((PROMPT_INDEX + 1))
}
PROMPT_BANDWIDTH=""
prompt_tuning_value PROMPT_BANDWIDTH "VPS 标称带宽" "请输入带宽：" auto 1 100000 1 100 Mbps >"$TEST_TEMP_DIR/prompt-output"
assert_equal "200" "$PROMPT_BANDWIDTH"
assert_equal "2" "$PROMPT_INDEX"
assert_equal "请输入带宽：" "${PROMPT_TEXTS[0]}"
assert_equal "请输入带宽：" "${PROMPT_TEXTS[1]}"
grep -qF '已确认VPS 标称带宽：200 Mbps。' "$TEST_TEMP_DIR/prompt-output"

PROMPT_RTT=""
prompt_tuning_value PROMPT_RTT "代理 RTT" "请输入 RTT：" 160 1 2000 1 160 ms >"$TEST_TEMP_DIR/prompt-output"
assert_equal "160" "$PROMPT_RTT"
assert_equal "3" "$PROMPT_INDEX"
assert_equal "请输入 RTT：" "${PROMPT_TEXTS[2]}"
grep -qF '已确认代理 RTT：160 ms。' "$TEST_TEMP_DIR/prompt-output"

PROMPT_AUTO=""
PROMPT_INPUTS+=(auto)
prompt_tuning_value PROMPT_AUTO "VPS 标称带宽" "请输入带宽：" auto 1 100000 1 100 Mbps >"$TEST_TEMP_DIR/prompt-output"
assert_equal "auto" "$PROMPT_AUTO"
grep -qF '已确认VPS 标称带宽：auto（按保守值 100 Mbps 计算）。' "$TEST_TEMP_DIR/prompt-output"

assert_equal "" "$(tuning_value BANDWIDTH_MBPS "$TEST_TEMP_DIR/missing-tuning.conf")"
cat >"$TEST_TEMP_DIR/tuning.conf" <<'EOF'
BANDWIDTH_MBPS=200
RTT_MS=160
EOF
assert_equal "200" "$(tuning_value BANDWIDTH_MBPS "$TEST_TEMP_DIR/tuning.conf")"
assert_equal "160" "$(tuning_value RTT_MS "$TEST_TEMP_DIR/tuning.conf")"
mkdir -p "$TEST_TEMP_DIR/state" "$TEST_TEMP_DIR/backups/20260101" "$TEST_TEMP_DIR/backups/20260201"
printf '%s\n' 'user setting' >"$TEST_TEMP_DIR/custom.conf"
capture_original_managed_file "$TEST_TEMP_DIR/custom.conf" "$TEST_TEMP_DIR/state"
[[ -e "$TEST_TEMP_DIR/state/original-custom.conf.present" ]]
cmp -s "$TEST_TEMP_DIR/custom.conf" "$TEST_TEMP_DIR/state/original-custom.conf"

printf '%s\n' '# Managed by vps-init-suite.' 'suite setting' >"$TEST_TEMP_DIR/managed.conf"
capture_original_managed_file "$TEST_TEMP_DIR/managed.conf" "$TEST_TEMP_DIR/state"
[[ -e "$TEST_TEMP_DIR/state/original-managed.conf.absent" ]]
[[ ! -e "$TEST_TEMP_DIR/state/original-managed.conf.present" ]]

printf '%s\n' 'legacy user setting' >"$TEST_TEMP_DIR/backups/20260101/conflict.conf"
printf '%s\n' '# Managed by vps-init-suite.' 'suite setting' >"$TEST_TEMP_DIR/backups/20260201/conflict.conf"
assert_equal "$TEST_TEMP_DIR/backups/20260101/conflict.conf" "$(find_latest_unmanaged_backup conflict.conf "$TEST_TEMP_DIR/backups")"

printf '%s\n' '# Managed by vps-init-suite.' 'suite setting' >"$TEST_TEMP_DIR/to-remove.conf"
remove_managed_file "$TEST_TEMP_DIR/to-remove.conf"
[[ ! -e "$TEST_TEMP_DIR/to-remove.conf" ]]
printf '%s\n' 'user setting' >"$TEST_TEMP_DIR/to-preserve.conf"
remove_managed_file "$TEST_TEMP_DIR/to-preserve.conf"
[[ -e "$TEST_TEMP_DIR/to-preserve.conf" ]]

printf '%s\n' "profile tests passed"
