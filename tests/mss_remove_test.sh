#!/usr/bin/env bash

set -Eeuo pipefail

TEST_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$TEST_ROOT/setup.sh"

TEST_TEMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_TEMP_DIR"' EXIT
cat >"$TEST_TEMP_DIR/mss.conf" <<'EOF'
MSS_MODE=clamp
MSS_VALUE=1380
MSS_VALUE6=1340
EOF

MOCK_CHAIN=1
MOCK_CHILD_RULE=1
MOCK_OUTPUT=1
MOCK_FORWARD=1
iptables() {
  local args=" $* "
  case "$args" in
    *" -t mangle -S VPS_INIT_MSS "*)
      printf '%s\n' '-N VPS_INIT_MSS'
      if (( MOCK_CHILD_RULE )); then
        # iptables -S may serialize the protocol extension with an explicit -m tcp.
        printf '%s\n' '-A VPS_INIT_MSS -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu'
      fi
      ;;
    *" -t mangle -S "*) return 0 ;;
    *" -t mangle -C OUTPUT "*) (( MOCK_OUTPUT )) ;;
    *" -t mangle -C FORWARD "*) (( MOCK_FORWARD )) ;;
    *" -t mangle -D OUTPUT "*) MOCK_OUTPUT=0 ;;
    *" -t mangle -D FORWARD "*) MOCK_FORWARD=0 ;;
    *" -t mangle -C VPS_INIT_MSS "*)
      (( MOCK_CHILD_RULE )) && [[ "$args" == *" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu "* ]]
      ;;
    *" -t mangle -D VPS_INIT_MSS "*)
      [[ "$args" == *" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu "* ]] || return 1
      MOCK_CHILD_RULE=0
      ;;
    *" -t mangle -X VPS_INIT_MSS "*) MOCK_CHAIN=0 ;;
    *) return 1 ;;
  esac
}
ip6tables() { return 1; }

remove_managed_mss_rules "$TEST_TEMP_DIR/mss.conf"
(( !MOCK_OUTPUT && !MOCK_FORWARD && !MOCK_CHILD_RULE && !MOCK_CHAIN )) || die "Uninstall left suite-owned MSS rules or chain behind."

printf '%s\n' "MSS rule removal tests passed"
