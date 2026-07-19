# Mercurygram click packaging (atlas / Android Translation Layer)

Packages the atlas runtime plus the F-Droid Telegram fork **Mercurygram**
(`it.belloworld.mercurygram`, v12.8.1.1) as an Ubuntu Touch click for
`ubuntu-touch-24.04-2.x`, arm64. Mirrors `ankidroid-click-packaging`; see that
repo's README for the shared build chain (GLFW 3.4, vixl, libunwind,
bionic_translation, art_standalone, wolfSSL-JNI, Qt WebEngine backend).

## Telegram-specific bits (vs the AnkiDroid package)

Telegram's native core `libtmessages.49.so` (+ `libmaplibre.so`) links three
bionic libs that AnkiDroid's Rust backend never needed:

- `libm.so` → mapped to the rootfs `libm.so.6` (cfg).
- `libjnigraphics.so` → mapped to atlas' `libandroid.so.0`, which implements
  `AndroidBitmap_getInfo/lockPixels/unlockPixels` (cfg).
- `libOpenSLES.so` → mapped to `libOpenSLES.so.1`, a no-op stub built here
  (`stubs/opensles_stub.c`): `slCreateEngine` returns "unsupported" so Telegram's
  audio init bails cleanly. **No voice messages / calls**; everything else runs.

The maps live in `stubs/mercurygram-bionic.cfg`, installed to
`usr/share/bionic_translation/cfg.d/` and merged with the base cfg at runtime.

Telegram also triggers **core-oj-internal lambdas** (streams/Collectors), which
art's `dx`-dexed libcore turns into live `invoke-custom` against AOSP's
return-null `LambdaMetafactory` stub → crash. The `art_standalone` pin
(98bec995) honors `make ... D8=<launcher>`; `build.sh` fetches the pinned r8 jar
(8.13.19) and desugars `core-oj` + `core-libart` with d8, exactly as AOSP does.

## Pins

- `atl-touch` @ **fab5b775** — includes every Telegram-under-ATL fix (BitmapShader,
  ImageView.setColorFilter, 9-patch color, emoji panel, send, login chain).
  **NOTE: this commit is local-only, not yet pushed to NotKit/atl-touch** — CI
  (`.github/`) will fail until it is pushed.
- `art_standalone` @ **98bec995** (D8 desugar support).
- `bionic_translation` @ ee37eb2, `wolfssl` @ v5.8.2-stable.

## Build & install

    clickable build           # arm64 under qemu (hours on x86_64)
    clickable install --ssh <device-ip>   # or: clickable install (adb)

Status: **not yet device-verified.** Everything above the native-lib gap is
proven on the x86_64 desktop (full MTProto login, chat list, send, emoji panel);
this package is the first attempt to run it on real arm64 Ubuntu Touch.
