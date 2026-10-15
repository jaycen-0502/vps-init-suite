#!/usr/bin/env bash

set -Eeuo pipefail

TEST_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly TEST_ROOT
TEST_OUTPUT=$(mktemp)
trap 'rm -f -- "$TEST_OUTPUT"' EXIT
# shellcheck disable=SC1091
source "$TEST_ROOT/setup.sh"

TEST_ZONEINFO=$(mktemp -d)
mkdir -p "$TEST_ZONEINFO/Asia" "$TEST_ZONEINFO/America"
: >"$TEST_ZONEINFO/Asia/Tokyo"
: >"$TEST_ZONEINFO/America/Los_Angeles"
ZONEINFO_DIR=$TEST_ZONEINFO
trap 'rm -rf -- "$TEST_ZONEINFO"; rm -f -- "$TEST_OUTPUT"' EXIT

MOCK_MODE="primary"
TIMEOUT_CALLS=()

timeout() {
  TIMEOUT_CALLS+=("$*")
  shift 2
  "$@"
}

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
  if [[ "${1:-}" == "show" ]]; then
    printf '%s\n' 'Asia/Tokyo'
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
if is_valid_timezone "Etc/../etc/passwd"; then
  die "Timezone path traversal passed validation."
fi

run_timedatectl 5 show --property=Timezone --value >"$TEST_OUTPUT"
assert_equal "Asia/Tokyo" "$(<"$TEST_OUTPUT")"
[[ "${TIMEOUT_CALLS[0]}" == "--signal=TERM 5s timedatectl show --property=Timezone --value" ]] ||
  die "timedatectl should always run with a bounded timeout."

assert_equal "Asia/Tokyo" "$(detect_public_timezone)"
MOCK_MODE="fallback"
assert_equal "America/Los_Angeles" "$(detect_public_timezone)"
MOCK_MODE="invalid"
if detect_public_timezone >/dev/null; then
  die "Invalid provider responses should not produce a timezone."
fi

TIME_SYNC_CALLS=()
apt_install() { TIME_SYNC_CALLS+=("install:$*"); }
run_with_timeout() {
  local seconds=$1
  shift
  TIME_SYNC_CALLS+=("${seconds}:$*")
  "$@"
}
systemctl() { return 0; }
chronyc() { return 0; }
enable_network_time
[[ "${TIME_SYNC_CALLS[*]}" == "install:chrony 10:systemctl disable --now systemd-timesyncd.service 15:systemctl enable --now chrony.service 15:systemctl restart chrony.service 15:chronyc -n makestep" ]] ||
  die "Network time setup should enable chrony and request an immediate step correction."

printf '%s\n' "timezone tests passed"
