#!/usr/bin/env bash

set -Eeuo pipefail

TEST_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$TEST_ROOT/setup.sh"

TEST_TEMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_TEMP_DIR"' EXIT
mkdir -p "$TEST_TEMP_DIR/bin"

cat >"$TEST_TEMP_DIR/bin/iptables" <<'MOCK'
#!/usr/bin/env bash
set -eu
args=" $* "
printf '%s%s\n' "${0##*/}" "$args" >>"$MSS_TEST_LOG"
case "$args" in
  *" -t mangle -L "*) exit 0 ;;
  *" -t mangle -N VPS_INIT_MSS "*) exit 0 ;;
  *" -t mangle -F VPS_INIT_MSS "*) exit 0 ;;
  *" -t mangle -A VPS_INIT_MSS "*)
    [[ "$args" == *" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS "* ]] || {
      printf '%s\n' 'RULE_APPEND failed (Invalid argument): TCPMSS requires a TCP match' >&2
      exit 2
    }
    exit 0
    ;;
  *" -t mangle -C OUTPUT "*|*" -t mangle -C FORWARD "*) exit 1 ;;
  *" -t mangle -I OUTPUT "*|*" -t mangle -I FORWARD "*) exit 0 ;;
  *) exit 1 ;;
esac
MOCK
cp "$TEST_TEMP_DIR/bin/iptables" "$TEST_TEMP_DIR/bin/ip6tables"
chmod +x "$TEST_TEMP_DIR/bin/iptables" "$TEST_TEMP_DIR/bin/ip6tables"

: >"$TEST_TEMP_DIR/iptables.log"
write_mss_helper "$TEST_TEMP_DIR/apply-mss.sh" "$TEST_TEMP_DIR/state"

run_mss_case() {
  local mode=$1 value=$2 value6=$3 expected4=$4 expected6=$5
  cat >"$TEST_TEMP_DIR/mss.conf" <<EOF
MSS_MODE=${mode}
MSS_VALUE=${value}
MSS_VALUE6=${value6}
EOF
  : >"$TEST_TEMP_DIR/iptables.log"
  PATH="$TEST_TEMP_DIR/bin:$PATH" \
  MSS_TEST_LOG="$TEST_TEMP_DIR/iptables.log" \
  VPS_INIT_MSS_CONFIG="$TEST_TEMP_DIR/mss.conf" \
    "$TEST_TEMP_DIR/apply-mss.sh" >"$TEST_TEMP_DIR/helper.stdout" 2>"$TEST_TEMP_DIR/helper.stderr"

  grep -qF -- "-A VPS_INIT_MSS -p tcp --tcp-flags SYN,RST SYN -j TCPMSS ${expected4}" "$TEST_TEMP_DIR/iptables.log" || {
    printf 'MSS helper did not add the expected IPv4 rule for mode %s.\n' "$mode" >&2
    cat "$TEST_TEMP_DIR/helper.stderr" >&2
    exit 1
  }
  grep -qF -- "ip6tables -w 5 -t mangle -A VPS_INIT_MSS -p tcp --tcp-flags SYN,RST SYN -j TCPMSS ${expected6}" "$TEST_TEMP_DIR/iptables.log" || {
    printf 'MSS helper did not add the expected IPv6 rule for mode %s.\n' "$mode" >&2
    cat "$TEST_TEMP_DIR/helper.stderr" >&2
    exit 1
  }
  ! grep -qF 'RULE_APPEND failed' "$TEST_TEMP_DIR/helper.stderr" || die "MSS helper attempted an invalid TCPMSS rule."
  grep -qF ' -t mangle -I FORWARD ' "$TEST_TEMP_DIR/iptables.log" || die "MSS helper did not attach FORWARD."
  ! grep -qF ' -t mangle -I OUTPUT ' "$TEST_TEMP_DIR/iptables.log" || die "MSS helper must not attach OUTPUT."
}

run_mss_case clamp 1380 1340 --clamp-mss-to-pmtu --clamp-mss-to-pmtu
run_mss_case fixed 1380 1380 '--set-mss 1380' '--set-mss 1380'
run_mss_case dual-fixed 1380 1340 '--set-mss 1380' '--set-mss 1340'

printf '%s\n' "MSS helper rule tests passed"
