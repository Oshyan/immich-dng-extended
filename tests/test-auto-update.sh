#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT_DIR/immich-dng-extended.sh"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# Isolate state from the developer's real acceptance files.
CACHE_DIR="$TEST_DIR/cache"
LIB_DIR="$TEST_DIR/dng-libs"
LIB_STAGE_DIR="$TEST_DIR/dng-libs.new"
LIB_BACKUP_DIR="$TEST_DIR/dng-libs.bak"
MANIFEST="$LIB_DIR/.immich-dng-manifest"
LOCK_FILE="$CACHE_DIR/.immich-dng.lock"
EULA_ACCEPT_FILE="$CACHE_DIR/eula-accepted"
EULA_ACCEPT_XDG="$TEST_DIR/xdg/eula-accepted"
mkdir -p "$CACHE_DIR" "$LIB_DIR"

IMAGE_ID="sha256:test-image"
IMMICH_VER="v9.9.9"
TARGET_PLATFORM="linux/amd64"
BASE_REF="202601010000"

# 1. Staged manifest write carries all pinned fields.
manifest_write_to "$LIB_STAGE_DIR/.immich-dng-manifest"
grep -qxF "image_id=$IMAGE_ID" "$LIB_STAGE_DIR/.immich-dng-manifest"
grep -qxF "immich_version=$IMMICH_VER" "$LIB_STAGE_DIR/.immich-dng-manifest"
grep -qxF "target_platform=$TARGET_PLATFORM" "$LIB_STAGE_DIR/.immich-dng-manifest"
grep -qxF "base_ref=$BASE_REF" "$LIB_STAGE_DIR/.immich-dng-manifest"

# 2. EULA acceptance: missing -> accepted -> SDK bump invalidates.
if eula_accepted; then
  printf 'FAIL: eula should start unaccepted\n' >&2
  exit 1
fi
# Simulate the interactive/--yes path without prompting.
eula_mark_accepted
if ! eula_accepted; then
  printf 'FAIL: eula should be accepted after marking\n' >&2
  exit 1
fi
LIBDNG_REVISION="9999_test-bump"
if eula_accepted; then
  printf 'FAIL: eula should invalidate on SDK revision bump\n' >&2
  exit 1
fi
LIBDNG_REVISION="2573_20260512"

# 3. Automation gate: missing acceptance exits 2, never prompts.
# 3b. -y on a no-op run still records acceptance (the unattended-update case).
rm -f "$EULA_ACCEPT_FILE" "$EULA_ACCEPT_XDG"
ASSUME_YES=0
record_assumed_eula
if eula_accepted; then
  printf 'FAIL: plain run must not record acceptance\n' >&2
  exit 1
fi
ASSUME_YES=1
record_assumed_eula
ASSUME_YES=0
if ! eula_accepted; then
  printf 'FAIL: -y no-op run should persist acceptance\n' >&2
  exit 1
fi
rm -f "$EULA_ACCEPT_FILE" "$EULA_ACCEPT_XDG"
if ( require_eula_noninteractive ) 2>/dev/null; then
  printf 'FAIL: require_eula_noninteractive should fail when unaccepted\n' >&2
  exit 1
fi
code=$?
# NOTE: `if ( ... )` above swallows the code, so re-probe explicitly.
( require_eula_noninteractive ) 2>/dev/null || code=$?
[ "$code" = 2 ] || { printf 'FAIL: expected exit 2, got %s\n' "$code" >&2; exit 1; }
ASSUME_YES=1 require_eula_noninteractive
[ -f "$EULA_ACCEPT_FILE" ] || { printf 'FAIL: --yes should persist acceptance\n' >&2; exit 1; }
ASSUME_YES=0

# 4. CLI surface: new commands are advertised, old ones still work.
# NOTE: capture before grepping — `help | grep -q` would SIGPIPE the writer
# under `set -o pipefail` (grep exits on first match, help keeps writing).
HELP_OUT=$(bash "$ROOT_DIR/immich-dng-extended.sh" help)
grep -q "ensure" <<<"$HELP_OUT"
grep -q "update" <<<"$HELP_OUT"
if bash "$ROOT_DIR/immich-dng-extended.sh" bogus 2>/dev/null; then
  printf 'FAIL: unknown command should fail\n' >&2
  exit 1
fi

printf 'PASS: auto-update (eula/stage/cli) regression cases\n'
