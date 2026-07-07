# immich-dng-extended

Extend [Immich](https://immich.app)'s DNG support to the files stock Immich can't decode: Lightroom HDR and panorama merges, recent iPhone/Samsung RAW, and other DNGs that need Adobe's DNG SDK. If your library has DNGs stuck with the error `Unsupported file format or not RAW file` or thumbnails that never generate, this is for you.

**One script. No Immich fork, no custom image, nothing redistributed, instant rollback, survives Immich updates.**

> **Status: early release (beta).** This works, but so far it has been verified on exactly one instance: Immich v3.0.1, arm64, Docker on macOS. The design is conservative and the rollback paths are tested (see [Safety](#the-key-facts-up-front)), but treat it accordingly. If you try it, please [open an issue](../../issues) to report success *or* failure, including your architecture, host OS, and Immich version — every report helps. PRs are very welcome.

```sh
cd /path/to/your/immich    # the folder containing docker-compose.yml
curl -fsSLO https://raw.githubusercontent.com/Oshyan/immich-dng-extended/main/immich-dng-extended.sh
chmod +x immich-dng-extended.sh
./immich-dng-extended.sh apply
```

Not affiliated with Immich/FUTO or Adobe.

## The key facts up front

1. **Why this is needed.** Immich decodes RAW files through libraw. Certain DNG variants (notably lossy-compressed DNGs, which Lightroom's HDR/pano merges and modern phone RAW produce) are only supported when libraw is compiled against the Adobe DNG SDK. Immich can't ship that SDK for licensing reasons ([immich#13029](https://github.com/immich-app/immich/issues/13029)). This tool compiles it **on your machine, for your use**, which the SDK license permits. Nothing Adobe-owned is ever redistributed.

2. **It is minimally invasive by design.** The stock Immich image is never modified and no Immich file is touched. The entire change is: two patched `libraw` library files in a `./dng-libs/` folder, mounted read-only into the container, plus one `docker-compose.override.yml` that prepends one path to `LD_LIBRARY_PATH`. That's it. Delete the override file and you are 100% stock.

3. **It checks its own work and rolls back automatically.** After activating, the script waits for the Immich API, confirms the patched library is actually loaded, and pushes a real image through Immich's own processing pipeline (sharp/libvips). If any check fails, it **automatically restores the stock configuration** and tells you what happened. This failure path was tested by deliberately corrupting the library and watching it recover.

4. **The build takes time: expect 10 to 40 minutes the first run.** It compiles libjxl, the Adobe DNG SDK, the XMP toolkit, and libraw from source inside Docker. You'll see a lot of compiler output scroll by; that is normal. Let it run. It ends with a clear green `✔ SUCCESS` banner when everything is built, activated, and verified. Re-runs use Docker's cache and are much faster. The build phase cannot affect your running server: it only writes files next to the script, and activation only happens after the build fully succeeds.

## Requirements

- Immich running via **docker compose** (the standard install)
- `bash`, `curl`, and docker with the compose plugin (or `docker-compose`)
- No compilers or dev tools on the host; the build runs inside Docker
- Should work on amd64 and arm64, since the build runs on your machine and always matches your architecture — but see the status note above; only arm64 is verified so far

## Commands

```sh
./immich-dng-extended.sh apply     # detect, build if needed, activate, verify
./immich-dng-extended.sh status    # what's running, what's built, what's needed
./immich-dng-extended.sh remove    # instant return to 100% stock
./immich-dng-extended.sh rebuild   # force a full rebuild
./immich-dng-extended.sh apply -y  # non-interactive (accepts the license prompt)
```

`apply` walks through: detect your exact Immich version from the running container → look up which official build recipe that release used → ask you to accept Adobe's DNG SDK license → build → activate with one container restart → verify. It is idempotent: re-running when nothing changed does nothing.

## After applying

Existing DNGs that previously failed won't fix themselves until Immich retries them. In the Immich web UI go to **Administration → Jobs → Generate Thumbnails → Missing**. If metadata was also incomplete for those files, run **Extract Metadata → Missing** too. New uploads just work.

## After an Immich update

Run `./immich-dng-extended.sh apply` again. It compares the running image against what the libraries were built for and rebuilds only if they actually differ; otherwise it's a no-op. Until you re-run it after a major update, the worst case is that DNG decoding reverts to stock behavior (the same files failing that failed before). If an update ever makes the overlay incompatible, `remove` gets you to stock instantly and the next `apply` rebuilds clean.

## Rollback / uninstall

Any of these, at any time:

- `./immich-dng-extended.sh remove` (also restarts and verifies for you)
- or manually: delete `docker-compose.override.yml`, then `docker compose up -d immich-server`
- to remove every trace: also delete `dng-libs/`, `.immich-dng-cache/`, the `immich-dng-build` Docker image, and the script itself

Your Immich install, library, and database are never touched by any of this.

## How it works (the details)

1. **Version detection.** Reads `org.opencontainers.image.version` from your running `immich-server` container, so it works even if your compose file uses the `release` tag.
2. **Recipe matching.** Every Immich release is built from a pinned tag of [immich-app/base-images](https://github.com/immich-app/base-images), which pins the exact libraw/libjxl/libvips versions. The script reads that tag from the release's `server/Dockerfile` and downloads those exact recipes, so the overlay build uses the same base image and same library versions as your server. ABI compatibility by construction, not by luck.
3. **The DNG additions.** The Adobe DNG SDK and XMP toolkit are compiled as static libraries, and libraw is compiled against them with `USE_DNGSDK`, plus an 8-line patch that lazily creates a default `dng_host` inside libraw. That patch is the key insight (credit: PseudoResonance): because host creation lives inside libraw, consumers like libvips/sharp need **zero changes**.
4. **The overlay.** The only artifacts are patched `libraw.so` / `libraw_r.so` files (~18 MB each; the SDK is statically inside them). Immich's pipeline is sharp → libvips → `libraw_r`, and the dynamic linker picks up the patched copy via `LD_LIBRARY_PATH` before the stock one in `/usr/local/lib`. Remove the env var and the stock library is used again, untouched.
5. **Verification.** `ldd` inside the container must show `libraw_r` resolving to `/opt/dng/lib/`, the API must answer, and a real image must survive the sharp pipeline. Any failure triggers automatic rollback and invalidates the build so the next `apply` starts clean.

## Troubleshooting

- **`status` says STALE**: Immich was updated; run `apply` to rebuild.
- **`status` says BROKEN or the container is restarting**: run `remove` to get back to stock immediately, then `apply` to rebuild from scratch.
- **You already have a `docker-compose.override.yml`**: the script refuses to touch it and prints the two stanzas to merge by hand.
- **Build fails**: nothing was changed on your server; the failure is contained to the build. Please [open an issue](../../issues) with the output.
- **Non-standard service name**: set `IMMICH_DNG_SERVICE=<name>` if your compose service isn't called `immich-server`.

Something not covered here, or something worked/failed in an interesting way? [Issues](../../issues) and [PRs](../../pulls) are welcome for anything: bug reports, success/failure reports on other architectures and Immich versions, docs fixes, or improvements to the script.

## Testing so far

Verified end to end on one instance, Immich v3.0.1 (arm64, Docker on macOS): Lightroom HDR and pano DNGs that stock Immich rejects render correctly with the overlay; a control ARW renders byte-identically before and after; and the corruption/auto-rollback path was exercised deliberately. Full write-up with method and results in [PROOF.md](PROOF.md). Reports from other setups, successful or not, are the main thing this project needs right now.

## Credits

- **[PseudoResonance](https://github.com/PseudoResonance)** did the hard part: the libraw host-creation patch and the libdng/XMP build recipes (see [their base-images branch](https://github.com/PseudoResonance/immich-base-images/tree/dng) and [immich-dng-images](https://github.com/PseudoResonance/immich-dng-images), their custom-image workflow), plus proposing the runtime-mount approach this tool implements. This project packages and automates their work; the ideas are theirs.
- The **[Immich](https://github.com/immich-app/immich)** team, whose clean, pinned [base-images](https://github.com/immich-app/base-images) build system makes an ABI-exact local rebuild possible at all.
- The sample HDR DNG from the [original issue report](https://github.com/immich-app/immich/issues/13029) was used for verification.
- [LibRaw](https://github.com/LibRaw/LibRaw), and Adobe's publicly downloadable DNG SDK and XMP Toolkit, which make DNG support possible in the first place.

## License

[AGPL-3.0](LICENSE), matching immich-app/base-images, from which the embedded build scripts derive (via PseudoResonance's fork). The Adobe DNG SDK itself is **not** included in this repository or in any built artifact you are asked to share; it is downloaded from Adobe by each user, for that user's own build, per its license. "DNG" is a trademark of Adobe; this project refers to it only to describe compatibility.
