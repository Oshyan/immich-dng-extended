#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT_DIR/immich-dng-extended.sh"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

LIB_DIR="$TEST_DIR/dng-libs"
MANIFEST="$LIB_DIR/.immich-dng-manifest"
IMAGE_ID="sha256:current-image"
TARGET_PLATFORM="linux/arm64"

mkdir -p "$LIB_DIR"
touch "$LIB_DIR/libraw_r.so.25"

write_manifest() {
  local image_id="$1"
  local target_platform="${2:-}"
  printf 'image_id=%s\n' "$image_id" > "$MANIFEST"
  if [ -n "$target_platform" ]; then
    printf 'target_platform=%s\n' "$target_platform" >> "$MANIFEST"
  fi
}

assert_current() {
  local description="$1"
  if ! libs_current; then
    printf 'FAIL: expected current: %s\n' "$description" >&2
    exit 1
  fi
}

assert_stale() {
  local description="$1"
  if libs_current; then
    printf 'FAIL: expected stale: %s\n' "$description" >&2
    exit 1
  fi
}

write_manifest "$IMAGE_ID"
assert_current "matching image with legacy manifest"

write_manifest "$IMAGE_ID" "$TARGET_PLATFORM"
assert_current "matching image and platform"

write_manifest "sha256:old-image"
assert_stale "changed image with legacy manifest"

write_manifest "sha256:old-image" "$TARGET_PLATFORM"
assert_stale "changed image with matching platform"

write_manifest "$IMAGE_ID" "linux/amd64"
assert_stale "matching image with different platform"

rm "$MANIFEST"
assert_stale "missing manifest"

rm "$LIB_DIR/libraw_r.so.25"
write_manifest "$IMAGE_ID" "$TARGET_PLATFORM"
assert_stale "missing overlay library"

printf 'PASS: libs_current regression cases\n'
