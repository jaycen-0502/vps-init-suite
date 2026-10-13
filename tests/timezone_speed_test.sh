#!/usr/bin/env bash

set -Eeuo pipefail

TEST_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$TEST_ROOT/setup.sh"

TEST_FILE=$(mktemp)
trap 'rm -f -- "$TEST_FILE"' EXIT
curl() {
  printf '%s\n' "$*" >"$TEST_FILE"
  return 1
}
timeout() {
  printf '%s\n' "$*" >"$TEST_FILE"
  return 0
}
timedatectl() { return 0; }

fetch_timezone_text "https://example.invalid/timezone" >/dev/null 2>&1 || true
REQUEST=$(<"$TEST_FILE")
[[ " $REQUEST " == *" --connect-timeout 2 "* ]] || die "Timezone requests need a short connection timeout."
[[ " $REQUEST " == *" --max-time 3 "* ]] || die "Timezone requests need a short total timeout."
[[ " $REQUEST " != *" --retry "* ]] || die "Timezone requests must not retry and multiply startup delays."

run_timedatectl 5 show --property=Timezone --value
REQUEST=$(<"$TEST_FILE")
[[ "$REQUEST" == "--signal=TERM 5s timedatectl show --property=Timezone --value" ]] ||
  die "timedatectl requests need a short hard timeout."

[[ "$(github_raw_url setup.sh)" == https://raw.githubusercontent.com/jaycen-0502/vps-init-suite/main/setup.sh\?cache=* ]] ||
  die "Raw GitHub URLs should include a cache-busting query parameter."

printf '%s\n' "timezone speed tests passed"
