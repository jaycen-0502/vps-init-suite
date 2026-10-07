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
assert_equal "on" "$(normalize_ipv6_mode on)"
assert_equal "on" "$(normalize_ipv6_mode enabled)"
assert_equal "off" "$(normalize_ipv6_mode disabled)"
assert_equal "off" "$(resolve_ipv6_mode "")"
assert_equal "on" "$(resolve_ipv6_mode on)"
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
