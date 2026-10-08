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

fetch_timezone_text "https://example.invalid/timezone" >/dev/null 2>&1 || true
REQUEST=$(<"$TEST_FILE")
[[ " $REQUEST " == *" --connect-timeout 2 "* ]] || die "Timezone requests need a short connection timeout."
[[ " $REQUEST " == *" --max-time 3 "* ]] || die "Timezone requests need a short total timeout."
[[ " $REQUEST " != *" --retry "* ]] || die "Timezone requests must not retry and multiply startup delays."

printf '%s\n' "timezone speed tests passed"
