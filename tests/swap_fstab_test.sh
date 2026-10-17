#!/usr/bin/env bash

set -Eeuo pipefail

TEST_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$TEST_ROOT/setup.sh"

TEST_TEMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_TEMP_DIR"' EXIT
TEST_FSTAB="$TEST_TEMP_DIR/fstab"

# Appending after a file without a final newline must not merge fstab rows.
printf '%s' '/dev/vda1 / ext4 defaults 0 1' >"$TEST_FSTAB"
ensure_managed_swap_fstab_entry "$TEST_FSTAB"
[[ "$(wc -l <"$TEST_FSTAB")" -eq 2 ]] || die "Swap append did not preserve the final fstab row boundary."
grep -qFx '/dev/vda1 / ext4 defaults 0 1' "$TEST_FSTAB" || die "Existing fstab row was modified."
grep -qFx "$SWAP_FILE none swap sw,nofail 0 0" "$TEST_FSTAB" || die "Managed swap entry is missing nofail."

# Re-running is idempotent, and upgrades the legacy suite row to nofail.
ensure_managed_swap_fstab_entry "$TEST_FSTAB"
[[ "$(grep -Fc "$SWAP_FILE" "$TEST_FSTAB")" -eq 1 ]] || die "Repeated setup created a duplicate swap row."
printf '%s none swap sw 0 0' "$SWAP_FILE" >"$TEST_FSTAB"
ensure_managed_swap_fstab_entry "$TEST_FSTAB"
[[ "$(<"$TEST_FSTAB")" == "$SWAP_FILE none swap sw,nofail 0 0" ]] || die "Legacy swap row was not normalized to nofail."

# Removal tolerates old and new options without touching unrelated swaps.
printf '%s\n' \
  "$SWAP_FILE none swap sw,nofail 0 0" \
  '/swapfile-other none swap sw 0 0' \
  "$SWAP_FILE none swap sw 0 0" >"$TEST_FSTAB"
remove_managed_swap_fstab_entry "$TEST_FSTAB"
[[ "$(<"$TEST_FSTAB")" == '/swapfile-other none swap sw 0 0' ]] || die "Swap removal changed unrelated fstab rows."

printf '%s\n' "swap fstab tests passed"
