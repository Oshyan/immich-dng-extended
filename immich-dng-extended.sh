#!/usr/bin/env bash
#
# immich-dng-extended — extend Immich's DNG support to files stock libraw
# can't decode (Lightroom HDR/pano merges, recent iPhone/Samsung RAW, etc.)
#
# https://github.com/Oshyan/immich-dng-extended
#
# It builds a DNG-SDK-enabled libraw ON YOUR MACHINE (Adobe's SDK is downloaded
# from Adobe, never redistributed) and overlays it onto the stock immich-server
# container via LD_LIBRARY_PATH. The stock image is never modified; removal is
# instant and Immich updates keep working (run `update`, or `ensure` from
# cron/systemd, after a new image is pulled).
#
# Usage: put this script next to your Immich docker-compose.yml, then:
#
#   ./immich-dng-extended.sh apply    # detect version, build if needed, activate
#   ./immich-dng-extended.sh status   # show what's active / whether rebuild is due
#   ./immich-dng-extended.sh remove   # back to 100% stock (keeps built libs)
#   ./immich-dng-extended.sh rebuild  # force a rebuild (e.g. after Immich update)
#   ./immich-dng-extended.sh update   # pull new image, rebuild if needed, activate
#   ./immich-dng-extended.sh ensure   # automation-safe apply (cron/systemd/Watchtower)
#
# Options: -y / --yes  accept the Adobe DNG SDK license prompt non-interactively
#          --auto      alias for automation mode (implies --yes if EULA already
#                      accepted; never prompts, exits 2 if acceptance is missing)
#
# Requirements: bash, docker (with compose), curl. The build itself runs in
# Docker, so no compilers are needed on the host. First build takes ~10-40 min.
#
# Safety: the build never touches the running server — it stages into
# dng-libs.new/ and swaps atomically. Activation is a single container
# recreate, after which
# the script health-checks Immich (API up + image pipeline works); if anything
# fails it automatically rolls back to the stock configuration. 'remove' or
# deleting docker-compose.override.yml returns you to 100% stock at any time.
#
# Based on PseudoResonance's proof of concept:
#   https://github.com/immich-app/immich/issues/13029
#   https://github.com/PseudoResonance/immich-base-images/tree/dng

set -euo pipefail

SCRIPT_VERSION="0.2.0"
SERVICE="${IMMICH_DNG_SERVICE:-immich-server}"
LIB_DIR="dng-libs"
LIB_STAGE_DIR="${LIB_DIR}.new"
LIB_BACKUP_DIR="${LIB_DIR}.bak"
OVERRIDE_FILE="docker-compose.override.yml"
MARKER="managed by immich-dng-extended"
CACHE_DIR="${IMMICH_DNG_CACHE:-.immich-dng-cache}"
MANIFEST="$LIB_DIR/.immich-dng-manifest"
LOCK_FILE="$CACHE_DIR/.immich-dng.lock"
# EULA acceptance is persisted here (plus $XDG_CONFIG_HOME copy, see below) so
# unattended runs (cron/systemd/Watchtower hooks) never have to re-prompt.
EULA_ACCEPT_FILE="$CACHE_DIR/eula-accepted"
_EULA_XDG_BASE="${XDG_CONFIG_HOME:-${HOME:-/tmp}/.config}"
EULA_ACCEPT_XDG="$_EULA_XDG_BASE/immich-dng-extended/eula-accepted"
ADOBE_EULA_URL="https://helpx.adobe.com/camera-raw/digital-negative.html"

# Pinned Adobe DNG SDK + XMP toolkit (what the patched libraw is built against)
LIBDNG_VERSION="1.7.1"
LIBDNG_REVISION="2573_20260512"
LIBXMP_REVISION="581c41213ddcee1fbc72cbb532531102a6617a25"

COMPOSE_CMD=()
ASSUME_YES=0
AUTO=0
if [ "${IMMICH_DNG_ASSUME_YES:-0}" = 1 ]; then ASSUME_YES=1; fi

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- detection

detect_compose() {
  [ -f docker-compose.yml ] || [ -f docker-compose.yaml ] || [ -f compose.yml ] || [ -f compose.yaml ] \
    || die "No compose file here. Run this from the directory containing Immich's docker-compose.yml."
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
  else
    die "docker compose not found."
  fi
  command -v curl >/dev/null 2>&1 || die "curl is required."
}

compose() { "${COMPOSE_CMD[@]}" "$@"; }

detect_immich() {
  CID=$(compose ps -q "$SERVICE" 2>/dev/null | head -1)
  [ -n "$CID" ] || die "Service '$SERVICE' is not running. Start Immich first (docker compose up -d)."
  IMMICH_VER=$(docker inspect "$CID" --format '{{index .Config.Labels "org.opencontainers.image.version"}}')
  IMAGE_ID=$(docker inspect "$CID" --format '{{.Image}}')
  TARGET_PLATFORM=$(docker image inspect "$IMAGE_ID" \
    --format '{{.Os}}/{{.Architecture}}{{if .Variant}}/{{.Variant}}{{end}}') \
    || die "Could not inspect the running Immich image platform."
  case "$IMMICH_VER" in
    v[0-9]*) ;;
    *) die "Could not detect the Immich version from the container's image labels (got '$IMMICH_VER')." ;;
  esac
  case "$TARGET_PLATFORM" in
    */*) ;;
    *) die "Could not detect the running Immich image platform (got '$TARGET_PLATFORM')." ;;
  esac
}

resolve_base_ref() {
  log "Resolving the base-images tag for Immich $IMMICH_VER"
  local df
  df=$(curl -fsSL "https://raw.githubusercontent.com/immich-app/immich/${IMMICH_VER}/server/Dockerfile") \
    || die "Could not fetch immich's server/Dockerfile for $IMMICH_VER from GitHub."
  BASE_REF=$(printf '%s\n' "$df" \
    | sed -nE 's,^FROM ghcr\.io/immich-app/base-server-(dev|image):([0-9]+).*,\2,p' | head -1)
  [ -n "$BASE_REF" ] || die "Could not find a base-server image tag in immich $IMMICH_VER's Dockerfile."
  log "Immich $IMMICH_VER was built from base-images tag $BASE_REF"
}

require_buildkit() {
  [ "${DOCKER_BUILDKIT:-1}" != "0" ] \
    || die "Docker BuildKit is disabled (DOCKER_BUILDKIT=0). Unset it or set it to 1."
  docker buildx version >/dev/null 2>&1 \
    || die "Docker Buildx/BuildKit is required. Make sure 'docker buildx version' works in the current Docker configuration (including any DOCKER_CONFIG override)."
}

# ---------------------------------------------------------------- manifest

manifest_get() { [ -f "$MANIFEST" ] && sed -nE "s/^$1=//p" "$MANIFEST" || true; }

manifest_write_to() {
  local dest="$1"
  mkdir -p "$(dirname "$dest")"
  cat > "$dest" <<EOF
image_id=$IMAGE_ID
immich_version=$IMMICH_VER
target_platform=$TARGET_PLATFORM
base_ref=$BASE_REF
dng_sdk=${LIBDNG_VERSION}_${LIBDNG_REVISION}
script_version=$SCRIPT_VERSION
built_at=$(date +%Y-%m-%dT%H:%M:%S%z)
EOF
}

manifest_write() { manifest_write_to "$MANIFEST"; }

libs_current() {
  ls "$LIB_DIR"/libraw_r.so.* >/dev/null 2>&1 || return 1
  [ "$(manifest_get image_id)" = "$IMAGE_ID" ] || return 1
  local built_platform
  built_platform=$(manifest_get target_platform)
  [ -z "$built_platform" ] || [ "$built_platform" = "$TARGET_PLATFORM" ]
}

# ---------------------------------------------------------------- eula + locking

# EULA acceptance is a local-machine fact (SDK downloaded for your own use),
# so it persists across Immich updates. Checked by automation entry points.
eula_accepted() {
  local sdk="dng_sdk=${LIBDNG_VERSION}_${LIBDNG_REVISION}"
  [ -f "$EULA_ACCEPT_FILE" ] && grep -qxF "$sdk" "$EULA_ACCEPT_FILE" 2>/dev/null && return 0
  [ -f "$EULA_ACCEPT_XDG" ] && grep -qxF "$sdk" "$EULA_ACCEPT_XDG" 2>/dev/null && return 0
  return 1
}

eula_mark_accepted() {
  local sdk="dng_sdk=${LIBDNG_VERSION}_${LIBDNG_REVISION}"
  mkdir -p "$CACHE_DIR"
  printf '%s\n' "$sdk" > "$EULA_ACCEPT_FILE"
  local xdg_dir
  xdg_dir=$(dirname "$EULA_ACCEPT_XDG")
  if mkdir -p "$xdg_dir" 2>/dev/null; then
    printf '%s\n' "$sdk" > "$EULA_ACCEPT_XDG" 2>/dev/null || true
  fi
}

# Non-blocking lock so overlapping cron runs / parallel `update` + `ensure`
# never run two 10-40 min builds at once. Exit code 3 = "another run active".
with_lock_or_exit() {
  mkdir -p "$CACHE_DIR"
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    flock -n 9 || { warn "Another immich-dng-extended run is in progress; exiting."; exit 3; }
  else
    warn "flock not found; proceeding without a lock (install util-linux flock for safe cron use)."
  fi
}

# ---------------------------------------------------------------- build

confirm_eula() {
  if [ "$ASSUME_YES" = 1 ]; then
    eula_mark_accepted
    return 0
  fi
  if eula_accepted; then
    return 0
  fi
  cat <<EOF

The build downloads the Adobe DNG SDK ${LIBDNG_VERSION} from Adobe's official
server (download.adobe.com) onto YOUR machine, for YOUR use. Nothing of
Adobe's is redistributed by this tool. By continuing, you accept Adobe's
DNG SDK license terms: ${ADOBE_EULA_URL}

Your acceptance is stored locally (see --help) so future updates don't re-prompt.

EOF
  read -r -p "Continue? [y/N] " a || die "Aborted (non-interactive; use --yes)."
  case "$a" in y|Y|yes|YES) ;; *) die "Aborted." ;; esac
  eula_mark_accepted
}

# Records a -y/--yes (or IMMICH_DNG_ASSUME_YES=1) acceptance immediately, so
# even no-op runs (libs already current, no build) persist it for later
# unattended rebuilds. Interactive runs persist via confirm_eula instead.
record_assumed_eula() { if [ "$ASSUME_YES" = 1 ]; then eula_mark_accepted; fi }

# Automation entry points must never block on a prompt (cron has no TTY).
# Pass-through when acceptance was recorded earlier, hard fail otherwise.
require_eula_noninteractive() {
  if [ "$ASSUME_YES" = 1 ]; then
    eula_mark_accepted
    return 0
  fi
  eula_accepted && return 0
  cat >&2 <<EOF
Adobe DNG SDK license acceptance is required before any unattended build.
Run once interactively: ./immich-dng-extended.sh apply
(or re-run this command with -y/--yes to accept non-interactively).
Acceptance is stored in $EULA_ACCEPT_FILE.
EOF
  exit 2
}

build_overlay() {
  require_buildkit
  confirm_eula
  log "Fetching immich-app/base-images @ $BASE_REF"
  rm -rf "$CACHE_DIR/src"
  mkdir -p "$CACHE_DIR/src"
  curl -fsSL "https://github.com/immich-app/base-images/archive/refs/tags/${BASE_REF}.tar.gz" \
    | tar -xz -C "$CACHE_DIR/src" --strip-components=1 \
    || die "Could not download base-images tag $BASE_REF."
  local ctx="$CACHE_DIR/src/server"
  [ -f "$ctx/Dockerfile" ] || die "Unexpected base-images layout."

  write_overlay_files "$ctx"
  patch_dockerfile "$ctx/Dockerfile"

  log "Building the patched libraw in Docker (target: libraw)."
  log "Target platform: $TARGET_PLATFORM (from the running Immich image)."
  log "The FIRST build compiles libjxl + the Adobe DNG SDK + libraw from source:"
  log "expect 10-40 minutes depending on your hardware. You will see a lot of"
  log "compiler output below — that is normal. Re-builds are much faster (cache)."
  log "The running server is untouched during the build; libs swap in atomically."
  local t0=$SECONDS
  docker buildx build --platform "$TARGET_PLATFORM" --load --target libraw \
    -t "immich-dng-build:${BASE_REF}" "$ctx"
  log "Build finished in $(( (SECONDS - t0) / 60 ))m $(( (SECONDS - t0) % 60 ))s."

  log "Extracting the patched libraw"
  local bcid
  bcid=$(docker create "immich-dng-build:${BASE_REF}")
  rm -rf "$CACHE_DIR/extract" "$LIB_STAGE_DIR"
  mkdir -p "$CACHE_DIR/extract" "$LIB_STAGE_DIR"
  docker cp "$bcid:/usr/local/lib/." "$CACHE_DIR/extract/"
  docker rm "$bcid" >/dev/null
  cp -P "$CACHE_DIR/extract"/libraw.so* "$CACHE_DIR/extract"/libraw_r.so* "$LIB_STAGE_DIR/"
  rm -rf "$CACHE_DIR/src" "$CACHE_DIR/extract"
  manifest_write_to "$LIB_STAGE_DIR/.immich-dng-manifest"
  # Atomic swap: the live mount is either the full old set or the full new
  # set — never half-copied. A container restart mid-swap sees one or the
  # other, and rollback just re-points at stock.
  if [ -d "$LIB_DIR" ]; then
    rm -rf "$LIB_BACKUP_DIR"
    mv "$LIB_DIR" "$LIB_BACKUP_DIR"
  fi
  mv "$LIB_STAGE_DIR" "$LIB_DIR"
  rm -rf "$LIB_BACKUP_DIR" "$LIB_STAGE_DIR"
  log "Overlay libs ready in ./$LIB_DIR"
}

# Insert the libdng stage and libraw patch wiring into the stock Dockerfile.
patch_dockerfile() {
  local df="$1"
  grep -q '^FROM base AS libraw$' "$df" \
    || die "base-images Dockerfile layout changed; this script needs an update. Please report this."
  awk '
    !z && /^  zlib1g \\$/ { print "  zlib1g-dev \\"; z=1; next }
    $0 == "FROM base AS libraw" {
      print "FROM libjxl AS libdng"
      print ""
      print "COPY sources/libdng.json sources/libxmp.json sources/libdng.sh ./"
      print "COPY sources/libdng-patches/ ./libdng-patches/"
      print "RUN ./libdng.sh"
      print ""
      print "FROM libdng AS libraw"
      next
    }
    $0 == "COPY sources/libraw.json sources/libraw.sh ./" {
      print
      print "COPY sources/libraw-patches/ ./libraw-patches/"
      next
    }
    { print }
  ' "$df" > "$df.patched" && mv "$df.patched" "$df"
}

# ---------------------------------------------------------------- overlay files
# Everything below is PseudoResonance's work (immich-base-images branch `dng`),
# embedded so this script is fully self-contained.

write_overlay_files() {
  local ctx="$1"
  mkdir -p "$ctx/sources/libdng-patches" "$ctx/sources/libraw-patches"

  cat > "$ctx/sources/libdng.json" <<EOF
{
    "name": "libdng",
    "version": "${LIBDNG_VERSION}",
    "revision": "${LIBDNG_REVISION}"
}
EOF

  cat > "$ctx/sources/libxmp.json" <<EOF
{
    "name": "libxmp",
    "version": "2025.03",
    "revision": "${LIBXMP_REVISION}"
}
EOF

  cat > "$ctx/sources/libdng.sh" <<'IMMICH_DNG_FILE'
#!/usr/bin/env bash

set -e

BUILD_ROOT=$(pwd)

: "${LIBDNG_VERSION:=$(jq -cr '.version' libdng.json)}"
: "${LIBDNG_REVISION:=$(jq -cr '.revision' libdng.json)}"

wget -O "dng_sdk_${LIBDNG_VERSION//./_}.zip" "https://download.adobe.com/pub/adobe/dng/dng_sdk_${LIBDNG_VERSION//./_}_${LIBDNG_REVISION}.zip"
unzip "dng_sdk_${LIBDNG_VERSION//./_}.zip"
rm "dng_sdk_${LIBDNG_VERSION//./_}.zip"
mv "dng_sdk_${LIBDNG_VERSION//./_}" "libdng"

cp "$BUILD_ROOT/libdng-patches/configure.ac" "$BUILD_ROOT/libdng-patches/Makefile.am" "libdng/dng_sdk/source"

: "${LIBXMP_REVISION:=$(jq -cr '.revision' libxmp.json)}"

git clone https://github.com/adobe/XMP-Toolkit-SDK.git libxmp
cd libxmp
git reset --hard "$LIBXMP_REVISION"
cd ..

# Build libxmp

ln -s $BUILD_ROOT/libdng/xmp/toolkit/* $BUILD_ROOT/libdng/xmp
cp -r libxmp/build/shared libdng/xmp/build
cd libdng/xmp/toolkit/build
cat <<EOF >> CMakeLists.txt
install(TARGETS XMPCoreStatic XMPFilesStatic
        ARCHIVE DESTINATION lib)
EOF
sed -i 's|COMMAND  mv ${OUTPUT_DIR}/lib${XMPCORE_LIB}.a  ${OUTPUT_DIR}/${XMPCORE_LIB}.ar|COMMAND  echo "skip mv"|' "$BUILD_ROOT/libdng/xmp/XMPCore/build/CMakeListsCommon.txt"
sed -i 's|COMMAND  mv ${OUTPUT_DIR}/lib${XMPFILES_LIB}.a  ${OUTPUT_DIR}/${XMPFILES_LIB}.ar|COMMAND  echo "skip mv"|' "$BUILD_ROOT/libdng/xmp/XMPFiles/build/CMakeListsCommon.txt"
cmake -DXMP_BUILD_STATIC=True \
  -DCMAKE_BUILD_TYPE=Release \
  "-DXMP_ROOT=$BUILD_ROOT/libdng/xmp/toolkit/" \
  .
echo "Building libxmp using $(nproc) threads"
cmake --build . -- -j"$(nproc)"
cmake --install .
cd "$BUILD_ROOT"

# Build libdng

cd libdng/dng_sdk/source

autoreconf --install
./configure
echo "Building libdng using $(nproc) threads"
make -j"$(nproc)"
make install
cd "$BUILD_ROOT"
ldconfig /usr/local/lib
IMMICH_DNG_FILE

  cat > "$ctx/sources/libraw.sh" <<'IMMICH_DNG_FILE'
#!/usr/bin/env bash

set -e

BUILD_ROOT=$(pwd)

: "${LIBRAW_REVISION:=$(jq -cr '.revision' libraw.json)}"

git clone https://github.com/libraw/libraw.git
cd libraw
git reset --hard "$LIBRAW_REVISION"

echo "Applying libraw patches"
git apply "$BUILD_ROOT/libraw-patches/internal-adobedng.patch"

sed -i -f - configure.ac <<EOF
/^AC_OUTPUT$/i \\
case "$\{host_os}" in \\
    linux*) \\
        AC_DEFINE(qLinux) \\
        ;; \\
    cygwin*|mingw*) \\
        AC_DEFINE(qWinOS) \\
        ;; \\
    darwin*) \\
        AC_DEFINE(qMacOS) \\
        ;; \\
    android*) \\
        AC_DEFINE(qAndroid) \\
        ;; \\
    *) \\
        AC_MSG_ERROR(["$\host_os not supported"]) \\
        ;; \\
esac \\
AC_DEFINE(USE_DNGSDK) \\
AC_DEFINE(USE_JPEG) \\
AC_DEFINE(USE_JPEG8) \\
AC_DEFINE(USE_ZLIB) \\
EOF
ROOT_DIR=$(cd ../libdng; pwd)
EXTRA_INCLUDE="-I$ROOT_DIR/dng_sdk/source -I$ROOT_DIR/xmp/toolkit/public/include"
autoreconf --install
CFLAGS="$CFLAGS $EXTRA_INCLUDE" \
CXXFLAGS="$CXXFLAGS $EXTRA_INCLUDE" \
LDFLAGS="$LDFLAGS \
  -ldng \
  -lstaticXMPCore \
  -lstaticXMPFiles \
  -ljxl \
  -ljxl_cms \
  -ljxl_extras_codec \
  -ljxl_threads \
  -lbrotlidec \
  -lbrotlienc \
  -lbrotlicommon \
  -ljpeg \
  -lhwy \
  -lz \
" ./configure --disable-examples
echo "Building libraw using $(nproc) threads"
make -j"$(nproc)"
make install
cd .. && rm -rf libraw libdng libxmp
ldconfig /usr/local/lib
IMMICH_DNG_FILE

  cat > "$ctx/sources/libraw-patches/internal-adobedng.patch" <<'IMMICH_DNG_FILE'
diff --git a/libraw/libraw.h b/libraw/libraw.h
index a1d23056..34805026 100644
--- a/libraw/libraw.h
+++ b/libraw/libraw.h
@@ -348,6 +348,7 @@ public:
   virtual int adobe_coeff(unsigned, const char *, int internal_only = 0);

   void set_dng_host(void *);
+  void create_dng_host();

 protected:
   static void *memmem(char *haystack, size_t haystacklen, char *needle,
diff --git a/src/decoders/unpack.cpp b/src/decoders/unpack.cpp
index cb9e341e..9afd9d4b 100644
--- a/src/decoders/unpack.cpp
+++ b/src/decoders/unpack.cpp
@@ -87,6 +87,8 @@ int LibRaw::unpack(void)
     imgdata.rawdata.float3_image = 0;

 #ifdef USE_DNGSDK
+    if (!dnghost)
+      create_dng_host();
     if (imgdata.idata.dng_version && dnghost
         && libraw_internal_data.unpacker_data.tiff_samples != 2  // Fuji SuperCCD; it is better to detect is more rigid way
         && valid_for_dngsdk() && load_raw != &LibRaw::pentax_4shot_load_raw)
diff --git a/src/integration/dngsdk_glue.cpp b/src/integration/dngsdk_glue.cpp
index a67f9347..d864640f 100644
--- a/src/integration/dngsdk_glue.cpp
+++ b/src/integration/dngsdk_glue.cpp
@@ -138,6 +138,8 @@ int LibRaw::valid_for_dngsdk()
 	  && load_raw == &LibRaw::lossy_dng_load_raw
 	  )
   {
+      if (!dnghost)
+        create_dng_host();
       if (!dnghost)
           return 0;
 	  try
@@ -209,6 +211,8 @@ int LibRaw::valid_for_dngsdk()
 int LibRaw::try_dngsdk()
 {
 #ifdef USE_DNGSDK
+  if (!dnghost)
+    create_dng_host();
   if (!dnghost)
     return LIBRAW_UNSPECIFIED_ERROR;

@@ -511,3 +515,9 @@ void LibRaw::set_dng_host(void *p)
   dnghost = p;
 #endif
 }
+void LibRaw::create_dng_host()
+{
+#ifdef USE_DNGSDK
+  dnghost = new dng_host;
+#endif
+}
IMMICH_DNG_FILE

  cat > "$ctx/sources/libdng-patches/configure.ac" <<'IMMICH_DNG_FILE'
# Process this file with autoconf to produce a configure script.

AC_PREREQ([2.61])
AC_INIT([dng], [1.7.1], [none@example.com])
AM_INIT_AUTOMAKE([foreign])

# Checks for programs.
AC_PROG_CXX

# Checks for libraries.
AC_PROG_RANLIB

# Checks for header files.

# Checks for typedefs, structures, and compiler characteristics.

# Checks for library functions.

AC_CANONICAL_HOST
case "${host_os}" in
  *linux*)
    AC_DEFINE(qLinux)
    AC_DEFINE(UNIX_ENV)
    AC_DEFINE(XMP_UNIXBuild)
    ;;
  *cygwin*|*mingw*)
    AC_DEFINE(qWinOS)
    ;;
  *darwin*)
    AC_DEFINE(qMacOS)
    ;;
  *android*)
    AC_DEFINE(qAndroid)
    ;;
  *)
    AC_MSG_ERROR(["$host_os not supported"])
    ;;
esac

AC_CONFIG_FILES([Makefile])
AC_OUTPUT
IMMICH_DNG_FILE

  cat > "$ctx/sources/libdng-patches/Makefile.am" <<'IMMICH_DNG_FILE'
## Process this file with automake to generate Makefile.in
lib_LIBRARIES = libdng.a
libdng_a_SOURCES = dng_1d_function.cpp dng_color_spec.cpp dng_hue_sat_map.cpp dng_linearization_info.cpp dng_negative.cpp dng_read_image.cpp dng_stream.cpp dng_xmp.cpp dng_1d_table.cpp dng_date_time.cpp dng_ifd.cpp dng_local_string.cpp dng_opcode_list.cpp dng_rect.cpp dng_string.cpp dng_xmp_sdk.cpp dng_abort_sniffer.cpp dng_exceptions.cpp dng_image.cpp dng_lossless_jpeg.cpp dng_opcodes.cpp dng_ref_counted_block.cpp dng_string_list.cpp dng_xy_coord.cpp dng_area_task.cpp dng_exif.cpp dng_image_writer.cpp dng_lossless_jpeg_shared.cpp dng_orientation.cpp dng_reference.cpp dng_tag_types.cpp dng_bad_pixels.cpp dng_file_stream.cpp dng_info.cpp dng_matrix.cpp dng_parse_utils.cpp dng_render.cpp dng_temperature.cpp dng_big_table.cpp dng_filter_task.cpp dng_iptc.cpp dng_memory.cpp dng_pixel_buffer.cpp dng_resample.cpp dng_tile_iterator.cpp dng_bmff.cpp dng_fingerprint.cpp dng_jpeg_image.cpp dng_memory_stream.cpp dng_point.cpp dng_safe_arithmetic.cpp dng_tone_curve.cpp dng_bottlenecks.cpp dng_gain_map.cpp dng_jpeg_memory_source.cpp dng_misc_opcodes.cpp dng_preview.cpp dng_shared.cpp dng_update_meta.cpp dng_camera_profile.cpp dng_globals.cpp dng_jxl.cpp dng_mosaic_info.cpp dng_pthread.cpp dng_simple_image.cpp dng_utils.cpp dng_color_space.cpp dng_host.cpp dng_lens_correction.cpp dng_mutex.cpp dng_rational.cpp dng_spline.cpp
CPPFLAGS += -fPIC -I../../xmp/toolkit/public/include
IMMICH_DNG_FILE

  chmod +x "$ctx/sources/libdng.sh" "$ctx/sources/libraw.sh"
}

# ---------------------------------------------------------------- apply/remove

write_override() {
  if [ -f "$OVERRIDE_FILE" ] && ! grep -q "$MARKER" "$OVERRIDE_FILE"; then
    cat >&2 <<EOF
You already have a $OVERRIDE_FILE that this tool did not create.
Merge this into it yourself, then re-run 'apply' (it will leave your file alone):

  services:
    $SERVICE:
      volumes:
        - ./$LIB_DIR:/opt/dng/lib:ro
      environment:
        - LD_LIBRARY_PATH=/opt/dng/lib${IMG_LDP:+:$IMG_LDP}
EOF
    die "Existing $OVERRIDE_FILE would be overwritten."
  fi
  cat > "$OVERRIDE_FILE" <<EOF
# $MARKER v$SCRIPT_VERSION — delete this file (or run './immich-dng-extended.sh remove')
# and 'docker compose up -d $SERVICE' to return to a 100% stock Immich.
services:
  $SERVICE:
    volumes:
      - ./$LIB_DIR:/opt/dng/lib:ro
    environment:
      - LD_LIBRARY_PATH=/opt/dng/lib${IMG_LDP:+:$IMG_LDP}
EOF
}

get_image_ldp() {
  IMG_LDP=$(docker inspect "$IMAGE_ID" --format '{{range .Config.Env}}{{println .}}{{end}}' \
    | sed -n 's/^LD_LIBRARY_PATH=//p' | head -1)
}

overlay_active() {
  local cid
  cid=$(compose ps -q "$SERVICE" 2>/dev/null | head -1)
  [ -n "$cid" ] || return 1
  # Match only the "=> /opt/dng/lib/..." resolution form; ldd ERROR lines for a
  # corrupt library also contain the path and must not count as active.
  docker exec "$cid" sh -c '
    f=$(find /usr/src/app -name "sharp-linux-*.node" -path "*Release*" 2>/dev/null | head -1)
    [ -n "$f" ] && ldd "$f" 2>/dev/null | grep -qE "libraw_r\.so[^ ]* => /opt/dng/lib/"
  ' 2>/dev/null
}

# Wait until the Immich API answers inside the container (up to ~2 min).
wait_api() {
  local cid deadline=60
  cid=$(compose ps -q "$SERVICE" 2>/dev/null | head -1)
  [ -n "$cid" ] || return 1
  while [ "$deadline" -gt 0 ]; do
    if docker exec "$cid" curl -sf -m 3 http://localhost:2283/api/server/ping >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    deadline=$((deadline - 1))
  done
  return 1
}

# Prove the image pipeline still works with the overlay loaded: load sharp
# (dlopens libvips + the patched libraw) and process an image with it. A broken
# or ABI-incompatible overlay fails here, triggering rollback.
smoke_test() {
  local cid
  cid=$(compose ps -q "$SERVICE" 2>/dev/null | head -1)
  [ -n "$cid" ] || return 1
  docker exec "$cid" sh -c 'cd /usr/src/app/server && node -e "
    const sharp = require(\"sharp\");
    sharp({ create: { width: 16, height: 16, channels: 3, background: { r: 1, g: 2, b: 3 } } })
      .jpeg().toBuffer()
      .then(() => { console.log(\"smoke ok\"); })
      .catch((e) => { console.error(e.message); process.exit(1); });
  "' >/dev/null 2>&1
}

# Emergency exit: put everything back to stock and confirm Immich recovers.
rollback() {
  warn "Rolling back to the stock configuration..."
  rm -f "$OVERRIDE_FILE"
  # Invalidate the built libs: they are the prime suspect, so the next 'apply'
  # must rebuild from scratch instead of reusing them.
  rm -f "$MANIFEST"
  compose up -d --force-recreate "$SERVICE" || true
  if wait_api; then
    warn "Rollback complete — Immich is running the stock image, exactly as before."
  else
    warn "Immich did not come back within the wait window. The overlay is fully"
    warn "removed ($OVERRIDE_FILE deleted), so your configuration is stock again;"
    warn "check 'docker compose logs $SERVICE'. Nothing from this tool remains active."
  fi
  die "Apply failed and was rolled back. Please report the output above."
}

cmd_apply() {
  with_lock_or_exit
  record_assumed_eula
  detect_compose
  detect_immich
  if libs_current; then
    log "Built libs already match immich $IMMICH_VER (image unchanged) — skipping build."
    BASE_REF=$(manifest_get base_ref)
  else
    resolve_base_ref
    # The build writes to ./$LIB_DIR atomically (via $LIB_STAGE_DIR) — the
    # running server is not touched until the build has fully succeeded.
    build_overlay
  fi
  activate_with_overlay
  printf '\n\033[1;32m✔ SUCCESS\033[0m — immich-dng-extended is active.\n\n'
  log "To backfill previously-failed files: Immich web -> Administration -> Jobs ->"
  log "Generate Thumbnails -> Missing (and the same for Extract Metadata if needed)."
  log "Instant rollback any time: ./immich-dng-extended.sh remove"
}

# Shared activate+verify path: prove the overlay WORKS (smoke test), not just
# that it's configured — a library corrupted on disk after a past apply would
# otherwise be reported healthy while the next restart crash-loops.
activate_with_overlay() {
  get_image_ldp
  if [ -f "$OVERRIDE_FILE" ] && grep -q "$MARKER" "$OVERRIDE_FILE" && libs_current && overlay_active && smoke_test; then
    write_override
    log "Overlay already active, verified working, and up to date. Nothing to do."
  else
    write_override
    log "Restarting $SERVICE with the overlay"
    compose up -d --force-recreate "$SERVICE" || rollback
    log "Waiting for Immich to come up..."
    wait_api || rollback
    overlay_active || rollback
    smoke_test || rollback
    log "Verified: Immich is up, healthy, and using the DNG-SDK-enabled libraw."
  fi
}

notify() {
  if [ -n "${IMMICH_DNG_NOTIFY_CMD:-}" ]; then
    # Best-effort hook for cron/systemd (e.g. mail, ntfy, webhook). Never fail the run.
    sh -c "$IMMICH_DNG_NOTIFY_CMD" _ "$@" || warn "Notify command failed (ignored)."
  fi
}

# Automation-safe apply: never prompts, takes a lock, exits 0 when healthy.
# Exit codes: 0 = healthy (already current or rebuilt+verified),
#             1 = failure (rolled back to stock, see logs),
#             2 = EULA acceptance required (run `apply` once, or re-run with -y),
#             3 = another run in progress.
cmd_ensure() {
  with_lock_or_exit
  record_assumed_eula
  detect_compose
  detect_immich
  if libs_current; then
    BASE_REF=$(manifest_get base_ref)
  else
    require_eula_noninteractive
    resolve_base_ref
    build_overlay
  fi
  if ! (
    activate_with_overlay
  ); then
    notify "immich-dng-extended ensure FAILED for $IMMICH_VER"
    return 1
  fi
  if libs_current && overlay_active; then
    log "ensure: healthy (immich $IMMICH_VER, overlay active)."
    return 0
  fi
  return 1
}

# Pull the latest server image, deploy it, and re-apply the overlay if the
# image changed. Safe to run unattended with -y/--auto after the first
# interactive apply: the long build runs against a healthy stock server.
cmd_update() {
  local was_auto=0
  [ "${AUTO:-0}" = 1 ] && was_auto=1
  with_lock_or_exit
  record_assumed_eula
  detect_compose
  if [ "$was_auto" = 1 ]; then
    require_eula_noninteractive
  fi
  log "Pulling latest image for $SERVICE"
  compose pull "$SERVICE" || die "docker compose pull failed."
  log "Deploying the pulled image"
  compose up -d "$SERVICE" || die "docker compose up failed."
  detect_immich
  if libs_current; then
    log "Image unchanged or libs already match $IMMICH_VER — ensuring overlay."
    BASE_REF=$(manifest_get base_ref)
    if [ "$was_auto" = 1 ]; then
      cmd_ensure_inner_no_lock
    else
      activate_with_overlay
    fi
  else
    if [ "$was_auto" = 1 ]; then
      require_eula_noninteractive
    fi
    resolve_base_ref
    if [ -f "$OVERRIDE_FILE" ] && grep -q "$MARKER" "$OVERRIDE_FILE"; then
      # Don't leave the server crash-looping on stale libs during a 10-40 min
      # build: park it on stock first, then rebuild + re-activate.
      log "Image changed — parking $SERVICE on stock during rebuild"
      rm -f "$OVERRIDE_FILE"
      compose up -d --force-recreate "$SERVICE" || die "Failed to start stock server."
      wait_api || warn "Stock server slow to come up; continuing with build anyway."
    fi
    build_overlay
    detect_immich
    activate_with_overlay
  fi
  printf '\n\033[1;32m✔ SUCCESS\033[0m — immich-dng-extended is active'
  printf ' on %s.\n' "$IMMICH_VER"
  notify "immich-dng-extended update OK for $IMMICH_VER"
}

# Inner ensure without re-locking (called from cmd_update which holds the lock).
cmd_ensure_inner_no_lock() {
  if libs_current; then
    BASE_REF=$(manifest_get base_ref)
  else
    require_eula_noninteractive
    resolve_base_ref
    build_overlay
  fi
  activate_with_overlay
}

cmd_remove() {
  detect_compose
  if [ -f "$OVERRIDE_FILE" ] && grep -q "$MARKER" "$OVERRIDE_FILE"; then
    rm "$OVERRIDE_FILE"
    log "Removed $OVERRIDE_FILE — restarting $SERVICE on the stock image"
    compose up -d --force-recreate "$SERVICE"
    wait_api && log "Immich is back up on the stock configuration." \
      || warn "Immich is still starting; check 'docker compose logs $SERVICE' if it doesn't settle."
    log "Back to stock. Built libs kept in ./$LIB_DIR for instant re-apply (delete freely)."
  elif [ -f "$OVERRIDE_FILE" ]; then
    die "$OVERRIDE_FILE exists but is not managed by immich-dng-extended; not touching it."
  else
    log "No overlay override present; already stock."
  fi
}

cmd_status() {
  detect_compose
  detect_immich
  echo "Immich version:   $IMMICH_VER"
  echo "Image platform:   $TARGET_PLATFORM"
  echo "Image id:         $(printf '%s' "${IMAGE_ID#sha256:}" | cut -c1-12)"
  if [ -f "$MANIFEST" ]; then
    echo "Libs built for:   $(manifest_get immich_version) (base-images $(manifest_get base_ref), DNG SDK $(manifest_get dng_sdk))"
    if [ "$(manifest_get image_id)" = "$IMAGE_ID" ]; then
      echo "Build freshness:  in sync with the running image"
    else
      echo "Build freshness:  STALE — Immich image changed; run './immich-dng-extended.sh apply' to rebuild"
    fi
  else
    echo "Libs built for:   (none built yet)"
  fi
  if [ -f "$OVERRIDE_FILE" ] && grep -q "$MARKER" "$OVERRIDE_FILE"; then
    echo "Override file:    present ($OVERRIDE_FILE)"
  else
    echo "Override file:    absent (stock configuration)"
  fi
  local cstate
  cstate=$(docker inspect "$CID" --format '{{.State.Status}}' 2>/dev/null || echo unknown)
  if [ "$cstate" != "running" ]; then
    echo "Runtime state:    CONTAINER $cstate — check 'docker compose logs $SERVICE';"
    echo "                  './immich-dng-extended.sh remove' returns to stock if the overlay is the cause"
  elif overlay_active; then
    if smoke_test; then
      echo "Runtime state:    ACTIVE — Immich is using the DNG-SDK-enabled libraw"
    else
      echo "Runtime state:    BROKEN — overlay loaded but the image pipeline fails."
      echo "                  Run './immich-dng-extended.sh apply' to repair or 'remove' for stock."
    fi
  else
    echo "Runtime state:    stock libraw"
  fi
}

cmd_rebuild() {
  with_lock_or_exit
  detect_compose
  detect_immich
  resolve_base_ref
  build_overlay
  activate_with_overlay
  printf '\n\033[1;32m✔ SUCCESS\033[0m — immich-dng-extended is active.\n'
}

# ---------------------------------------------------------------- main

main() {
  local cmd="${1:-apply}"
  [ $# -gt 0 ] && shift
  for a in "$@"; do
    case "$a" in
      -y|--yes) ASSUME_YES=1 ;;
      --auto) AUTO=1 ;;
      *) die "Unknown option: $a" ;;
    esac
  done

  case "$cmd" in
    apply)
      if [ "$AUTO" = 1 ]; then cmd_ensure; else cmd_apply; fi ;;
    remove)  cmd_remove ;;
    status)  cmd_status ;;
    rebuild) cmd_rebuild ;;
    update)  cmd_update ;;
    ensure)  cmd_ensure ;;
    -h|--help|help)
      sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'
      cat <<EOF

Commands:
  apply     interactive apply (prompts for Adobe DNG SDK license once)
  update    pull + redeploy + rebuild-if-stale + verify (use -y/--auto after first apply)
  ensure    automation-safe apply for cron/systemd/Watchtower; never prompts
            exits 0=healthy, 1=failed, 2=EULA acceptance needed, 3=another run active
  status    show versions and health
  remove    back to stock
  rebuild   force rebuild

Automation:
  cron:      */15 * * * * cd /path/to/immich && ./immich-dng-extended.sh ensure >>dng-auto.log 2>&1
  systemd:   timer calling 'ensure' with WorkingDirectory=/path/to/immich
  Watchtower: use a post-update hook / notification to run 'ensure --auto'
  notify:    set IMMICH_DNG_NOTIFY_CMD='ntfy publish mytopic ...' to run on update/failure

EULA acceptance is recorded in $CACHE_DIR/eula-accepted (and per-user under
\$XDG_CONFIG_HOME/immich-dng-extended/) so unattended runs don't re-prompt.
Set IMMICH_DNG_ASSUME_YES=1 instead of passing -y in automation.
EOF
      ;;
    *) die "Unknown command '$cmd'. Use: apply | update | ensure | remove | status | rebuild" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
