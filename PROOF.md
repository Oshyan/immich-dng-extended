# Immich v3.1.0 compatibility recheck (2026-08-13)

Target: `immich-server:v3.1.0` (arm64, OrbStack Docker on macOS), built from
`immich-app/base-images` tag `202607211135`.

The existing v3.0.1 overlay was removed before the Immich update, then rebuilt
from the v3.1.0-pinned base-images recipe and reapplied. After activation:

- the container was healthy with restart count `0`;
- `ldd /usr/local/lib/libvips.so.42` resolved `libraw_r.so.25` to
  `/opt/dng/lib/libraw_r.so.25`;
- the API and built-in Sharp image-pipeline checks passed; and
- the same Lightroom panorama `IMGP3836-Pano.dng` decoded through Sharp/libvips
  to a 1440x356 JPEG (34,951 bytes).

This was a compatibility recheck of the known-good DNG, not a repeat of every
stock-versus-overlay control below. It confirms the overlay build, linkage, and
problem-DNG decode path on v3.1.0.

# Stage 1 proof (2026-07-07)

Target: stock `immich-server:v3.0.1` (arm64, OrbStack Docker on macOS), built from
`immich-app/base-images` tag `202606161235` (libraw 0.22.1 @ `b860248`, soname
`libraw.so.25`).

## Chain verified

`sharp-linux-arm64.node` → `/usr/local/lib/libvips.so.42` → `libraw_r.so.25`.
With the overlay env set, `ldd` resolves `libraw_r.so.25 => /opt/dng/lib/libraw_r.so.25`.
The DNG SDK and XMP toolkit are statically linked into the patched libraw, so the
overlay is exactly two files (plus soname symlinks): `libraw.so.25.0.0` and
`libraw_r.so.25.0.0` (~18 MB each vs ~1 MB stock — that's the embedded SDK).

## Results

Test method: `node` + `sharp` inside the running container — the same pipeline
Immich's thumbnail job uses (`.rotate().resize(1440).jpeg()`).

| File | Stock v3.0.1 | With overlay |
|---|---|---|
| Sony a7 IV Lightroom HDR DNG (sample from issue #13029) | FAIL: "dcrawload: unable to unpack: Unsupported file format or not RAW file" | OK, 1440x960 JPEG, correct image |
| Real library pano `IMGP3836-Pano.dng` (Lightroom pano merge, never had a thumbnail in Immich) | FAIL (no thumbnail asset existed) | OK, 1440x356 JPEG, correct image |
| Control: Sony ARW (`DSC00187.ARW`) | OK, 49919 bytes | OK, 49919 bytes — identical size, decode path unaffected |

## Conclusions

- The core thesis holds: swapping one library via `LD_LIBRARY_PATH`, with libvips
  and the stock image untouched, is sufficient. Apply and remove are pure overlay
  operations (one override file + one read-only mount).
- The overlay must be rebuilt when the server image's base changes; the tag is
  discoverable from the release's `server/Dockerfile` (`base-server-dev:<TAG>`),
  which is what `immich-dng-extended.sh` automates.
- PseudoResonance's branch tip (`386aaa83`) is the recipe that works; the earlier
  commit `ddd2662c` had two since-fixed shell bugs (unquoted `mv`, quoted glob in
  `ln -s`).
