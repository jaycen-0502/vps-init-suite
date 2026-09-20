#!/usr/bin/env bash

set -Eeuo pipefail

TEST_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly TEST_ROOT
# shellcheck disable=SC1091
source "$TEST_ROOT/setup.sh"

MOCK_MODE="primary"

timedatectl() {
  if [[ "${1:-}" == "list-timezones" ]]; then
    printf '%s\n' \
      "America/Los_Angeles" \
      "America/New_York" \
      "Asia/Singapore" \
      "Asia/Tokyo" \
      "Etc/UTC" \
      "Europe/London"
    return 0
  fi
  return 1
}

curl() {
  local url=${!#}
  case "$MOCK_MODE:$url" in
    primary:https://ipwho.is/)
      printf '%s\n' '{"timezone":{"id":"Asia/Tokyo"}}'
      ;;
    fallback:https://ipwho.is/)
      return 1
      ;;
    fallback:https://ipinfo.io/timezone)
      printf '%s\n' 'America/Los_Angeles'
      ;;
    invalid:https://ipwho.is/)
      return 1
      ;;
    invalid:https://ipinfo.io/timezone)
      printf '%s\n' '../../tmp/evil'
      ;;
    invalid:https://ipapi.co/timezone/)
      printf '%s\n' 'Not/AZone'
      ;;
    *)
      return 1
      ;;
  esac
}

jq() {
  if [[ "$MOCK_MODE" == "primary" ]]; then
    printf '%s\n' 'Asia/Tokyo'
    return 0
  fi
  return 1
}

assert_equal() {
  local expected=$1
  local actual=$2
  [[ "$actual" == "$expected" ]] || die "Expected '${expected}', got '${actual}'."
}

is_valid_timezone "Asia/Tokyo"
if is_valid_timezone "../../tmp/evil"; then
  die "Unsafe timezone value passed validation."
fi

assert_equal "Asia/Tokyo" "$(detect_public_timezone)"
MOCK_MODE="fallback"
assert_equal "America/Los_Angeles" "$(detect_public_timezone)"
MOCK_MODE="invalid"
if detect_public_timezone >/dev/null; then
  die "Invalid provider responses should not produce a timezone."
fi

printf '%s\n' "timezone tests passed"
