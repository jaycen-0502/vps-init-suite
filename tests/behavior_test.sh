#!/usr/bin/env bash

set -Eeuo pipefail

TEST_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$TEST_ROOT/setup.sh"

APT_UPDATED=1
TEST_INSTALLED_PACKAGES=(ca-certificates curl)
APT_CALLS=()
package_is_installed() { [[ " ${TEST_INSTALLED_PACKAGES[*]} " == *" $1 "* ]]; }
apt-get() { APT_CALLS+=("$*"); }

apt_install ca-certificates curl
[[ ${#APT_CALLS[@]} -eq 0 ]] || die "Installed packages should not invoke apt-get."

APT_UPDATED=0
apt_install curl jq
[[ ${#APT_CALLS[@]} -eq 2 ]] || die "Missing dependencies should update package lists once, then install."
[[ "${APT_CALLS[0]}" == "update -y" ]] || die "Unexpected apt update call: ${APT_CALLS[0]}"
[[ "${APT_CALLS[1]}" == "install -y --no-install-recommends jq" ]] || die "Unexpected apt install call: ${APT_CALLS[1]}"

FLOW=()
require_root() { :; }
require_supported_os() { :; }
tune_kernel() { FLOW+=(kernel); }
setup_timezone() { FLOW+=(timezone); }
setup_swap() { FLOW+=(swap); }
setup_mss() { FLOW+=(mss); }
install_shortcut() { FLOW+=(shortcut); }
show_status() { FLOW+=(status); }
offer_xui_policy() { FLOW+=(xui-policy); }
full_init keep off
[[ "${FLOW[*]}" == "kernel timezone swap mss shortcut status xui-policy" ]] || die "Full initialization did not offer the 3X-UI policy menu at the end: ${FLOW[*]}"

printf '%s\n' "behavior tests passed"
