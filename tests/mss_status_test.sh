#!/usr/bin/env bash

set -Eeuo pipefail

TEST_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$TEST_ROOT/setup.sh"

MOCK_CHAIN=1
MOCK_RULE=1
MOCK_OUTPUT=1
MOCK_FORWARD=1
MOCK_RULE_MODE=clamp
MOCK_RULE_VALUE=1380

iptables() {
  local args=" $* "
  case "$args" in
    *" -L "*) return 0 ;;
    *" -S VPS_INIT_MSS "*) (( MOCK_CHAIN )) && printf '%s\n' '-N VPS_INIT_MSS' ;;
    *" -C VPS_INIT_MSS "*)
      (( MOCK_RULE )) || return 1
      if [[ "$MOCK_RULE_MODE" == "clamp" ]]; then
        [[ "$args" == *" --clamp-mss-to-pmtu "* ]]
      else
        [[ "$args" == *" --set-mss ${MOCK_RULE_VALUE} "* ]]
      fi
      ;;
    *" -C OUTPUT "*) (( MOCK_OUTPUT )) ;;
    *" -C FORWARD "*) (( MOCK_FORWARD )) ;;
    *) return 1 ;;
  esac
}

assert_equal() {
  local expected=$1 actual=$2
  [[ "$actual" == "$expected" ]] || die "Expected '${expected}', got '${actual}'."
}

assert_equal 已生效 "$(mss_family_status iptables clamp 1380 1340)"
MOCK_FORWARD=0
assert_equal 不完整 "$(mss_family_status iptables clamp 1380 1340)"
MOCK_FORWARD=1
MOCK_CHAIN=0
assert_equal 未生效 "$(mss_family_status iptables clamp 1380 1340)"
MOCK_CHAIN=1
MOCK_RULE=0
assert_equal 未生效 "$(mss_family_status iptables clamp 1380 1340)"
MOCK_RULE=1
MOCK_RULE_MODE=fixed
MOCK_RULE_VALUE=1380
assert_equal 已生效 "$(mss_family_status iptables fixed 1380 1380)"
MOCK_RULE_VALUE=1340
assert_equal 未生效 "$(mss_family_status iptables dual-fixed 1380 1340)"

unset -f ip6tables 2>/dev/null || true
assert_equal 未安装 "$(mss_family_status ip6tables clamp 1380 1340)"

printf '%s\n' "MSS status tests passed"
