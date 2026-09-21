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

printf '%s\n' "profile tests passed"
