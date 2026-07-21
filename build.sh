#!/bin/bash
# Build the atlas (Android Translation Layer) runtime plus Telegram
# (Mercurygram) and assemble the click package tree.
#
# Modeled on the flathub packaging of ATL:
#   https://github.com/flathub/io.gitlab.android_translation_layer.BaseApp
#   https://github.com/flathub/net.newpipe.NewPipe
#
# Runs inside a NATIVE arm64 clickable container (art_standalone cannot be
# cross-compiled). On an x86_64 host docker runs the container via
# qemu-user/binfmt_misc — slow but fully unattended. All stages are stamped
# and cached in ${ROOT}/build, so subsequent builds only redo what changed.
set -euo pipefail

APP_ID="mercurygram.nekit"
APP_HOOK="mercurygram"

# click maintains a version-independent 'current' symlink to the active
# package version. Baking it into the meson prefix makes compiled-in paths
# (rpath, INSTALL_DATADIR, AOT dex locations) valid at runtime regardless of
# the installed package version.
CLICK_BASE="/opt/click.ubuntu.com/${APP_ID}/current"
CLICK_PREFIX="${CLICK_BASE}/usr"

# --- pinned sources -----------------------------------------------------

# Telegram fork "Mercurygram" from F-Droid; per-ABI APKs (versionCode encodes
# the ABI): 6916018 = arm64-v8a, 6916014 = x86_64, 6916013 = x86.
MERCURYGRAM_VERSION="12.8.1.1"

# r8/d8 desugars core-oj + core-libart lambdas at dex time (see the D8 step and
# the art_standalone submodule pin). Pure-Java, arch-independent, from Google
# Maven.
R8_VERSION="8.13.19"
R8_SHA256="7712edbae6a71f35937ffc1bd5f4c202919ef2a5e58d3c3544015a868a3cf457"

GLFW_VERSION="3.4"
GLFW_SHA256="b5ec004b2712fd08e8861dc271428f048775200a2df719ccf575143ba749a3e9"

VIXL_VERSION="8.0.0"
VIXL_SHA256="6aebbebcd9b66686ea246b450af529e1fc50fe25209522cc9ab42beae2377d38"

LIBUNWIND_VERSION="1.8.2"
LIBUNWIND_SHA256="7f262f1a1224f437ede0f96a6932b582c8f5421ff207c04e3d9504dfa04c8b82"

# --- environment from clickable's custom builder ------------------------

ROOT="${ROOT:?not run through clickable}"
BUILD_DIR="${BUILD_DIR:?}"
INSTALL_DIR="${INSTALL_DIR:?}"
ARCH="${ARCH:-arm64}"
JOBS="${NUM_PROCS:-$(nproc)}"

case "${ARCH}" in
    arm64) ART_ARCH="arm64";  APK_ABI="arm64-v8a"; APK_CODE="6916018"
           APK_SHA256="8168dd3a0da48e11925b2c3ead2ed47e66561f28ed632dfc9a30a5c43e80c650" ;;
    amd64) ART_ARCH="x86_64"; APK_ABI="x86_64";    APK_CODE="6916014"
           APK_SHA256="" ;; # untested; fill in when enabling amd64
    *) echo "unsupported arch: ${ARCH}" >&2; exit 1 ;;
esac
APK_URL="https://f-droid.org/repo/it.belloworld.mercurygram_${APK_CODE}.apk"

STAGE="${BUILD_DIR}/stage"          # build-time sysroot for the whole chain
PREFIX="${STAGE}/usr"
DL="${BUILD_DIR}/downloads"
STAMPS="${BUILD_DIR}/stamps"
mkdir -p "${PREFIX}" "${DL}" "${STAMPS}"

export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PREFIX}/share/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
export PATH="${PREFIX}/bin:${PATH}"
export LD_LIBRARY_PATH="${PREFIX}/lib:${PREFIX}/lib/art${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export LIBRARY_PATH="${PREFIX}/lib"
# include/vixl is needed because art includes vixl headers as e.g.
# "aarch64/disasm-aarch64.h" without the vixl/ prefix
export CPATH="${PREFIX}/include:${PREFIX}/include/vixl"
export CMAKE_PREFIX_PATH="${PREFIX}"
JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
export JAVA_HOME

log()   { echo -e "\033[1;34m[build.sh]\033[0m $*"; }
stamp() { [ -f "${STAMPS}/$1.done" ]; }
done_stamp() { touch "${STAMPS}/$1.done"; }

# Stamp names carry the pinned version (or submodule commit) so a stale
# build/CI cache can never mask a version bump: the renamed stamp simply
# doesn't exist and the stage rebuilds. Completed stages also delete their
# build trees — only stage/ is needed afterwards, and CI runners are
# disk-constrained.
WOLFSSL_REV="$(git -C "${ROOT}/wolfssl" rev-parse --short HEAD 2>/dev/null || echo unknown)"
BIONIC_REV="$(git -C "${ROOT}/bionic_translation" rev-parse --short HEAD 2>/dev/null || echo unknown)"
# the stage carries our patches, so its stamp must change when a patch does
BIONIC_REV="${BIONIC_REV}-$(cat "${ROOT}/patches/bionic_translation-ut.patch" "${ROOT}/patches/bionic_translation-stdio-glibc.patch" | sha256sum | cut -c1-8)"
ART_REV="$(git -C "${ROOT}/art_standalone" rev-parse --short HEAD 2>/dev/null || echo unknown)"
ART_REV="${ART_REV}-$(sha256sum "${ROOT}/patches/art_standalone-d8.patch" | cut -c1-8)"

fetch() { # fetch <url> <sha256> <outfile>
    local url="$1" sha="$2" out="${DL}/$3"
    if [ -f "${out}" ] && echo "${sha}  ${out}" | sha256sum -c - >/dev/null 2>&1; then
        return 0
    fi
    log "downloading $3"
    curl -Lf --retry 3 -o "${out}.tmp" "${url}"
    echo "${sha}  ${out}.tmp" | sha256sum -c -
    mv "${out}.tmp" "${out}"
}

# --- 0. prebuilt ATL SDK (skip the whole ATL compile) ---------------------
# The atl-touch CI publishes a per-commit "ATL SDK" tarball: atlas plus art,
# skia, wolfSSL, GLFW, vixl, libunwind and bionic_translation — the multi-hour
# part of a click build. When a release matching the atl-touch submodule commit
# exists we drop it straight into the stage and skip building any of it; only
# the app-specific steps (APK, stubs, AOT, packaging) then run.
#
# ATL_SDK_TAG:
#   unset  -> auto: derive sdk-<submodule-sha> and use it when the atl-touch
#             working tree is clean and the release downloads; otherwise build
#             atlas from source (so local atlas edits are never overridden).
#   off    -> always build from source.
#   sdk-X  -> force that release (explicit; skips the clean-tree check).
ATL_SDK_REPO="${ATL_SDK_REPO:-NotKit/atl-touch}"
ATL_SDK_TAG="${ATL_SDK_TAG-auto}"
USE_SDK=""

if [ -n "${ATL_SDK_TAG}" ] && [ "${ATL_SDK_TAG}" != "off" ] && [ "${ATL_SDK_TAG}" != "none" ]; then
    tag="${ATL_SDK_TAG}"; forced=1
    if [ "${ATL_SDK_TAG}" = "auto" ]; then
        forced=""
        sha="$(git -C "${ROOT}/atl-touch" rev-parse --short HEAD 2>/dev/null || true)"
        tag="${sha:+sdk-${sha}}"
        if [ -z "${tag}" ]; then
            log "SDK: can't read atl-touch commit — building atlas from source"
        elif ! git -C "${ROOT}/atl-touch" diff --quiet 2>/dev/null \
             || ! git -C "${ROOT}/atl-touch" diff --cached --quiet 2>/dev/null; then
            log "SDK: atl-touch working tree is dirty — building atlas from source"
            tag=""
        fi
    fi
    if [ -n "${tag}" ]; then
        archive="${DL}/atl-sdk-${ARCH}-${tag}.tar.zst"
        url="https://github.com/${ATL_SDK_REPO}/releases/download/${tag}/atl-sdk-${ARCH}.tar.zst"
        ok=1
        if [ ! -f "${archive}" ]; then
            if curl -Lf --retry 3 -o "${archive}.tmp" "${url}"; then
                mv "${archive}.tmp" "${archive}"
            else
                rm -f "${archive}.tmp"; ok=""
            fi
        fi
        if [ -z "${ok}" ]; then
            [ -n "${forced}" ] && { echo "SDK ${tag} download failed: ${url}" >&2; exit 1; }
            log "SDK ${tag} not available — building atlas from source"
        else
            # verify against the published sidecar (compare the digest only; its
            # path column is the CI build path, not our filename)
            if curl -Lf --retry 3 -so "${archive}.sha256" "${url}.sha256"; then
                want="$(awk '{print $1}' "${archive}.sha256")"
                have="$(sha256sum "${archive}" | awk '{print $1}')"
                [ "${want}" = "${have}" ] || { echo "SDK ${tag} checksum mismatch" >&2; exit 1; }
            fi
            log "using prebuilt ATL SDK ${tag} (${ATL_SDK_REPO})"
            rm -rf "${BUILD_DIR}/atl-sdk"
            mkdir -p "${BUILD_DIR}/atl-sdk"
            zstd -dc "${archive}" | tar -C "${BUILD_DIR}/atl-sdk" -x
            # stage the whole prebuilt runtime (atlas + deps); the app-specific
            # steps below run on top of it
            rsync -a "${BUILD_DIR}/atl-sdk/usr/" "${PREFIX}/"
            USE_SDK=1
        fi
    fi
fi

# --- 1. GLFW 3.4 (noble ships 3.3, atlas needs the libdecor init hint) ---

if [ -z "${USE_SDK}" ] && ! stamp "glfw-${GLFW_VERSION}"; then
    log "building GLFW ${GLFW_VERSION}"
    fetch "https://github.com/glfw/glfw/releases/download/${GLFW_VERSION}/glfw-${GLFW_VERSION}.zip" \
          "${GLFW_SHA256}" "glfw-${GLFW_VERSION}.zip"
    rm -rf "${BUILD_DIR}/glfw"
    unzip -q "${DL}/glfw-${GLFW_VERSION}.zip" -d "${BUILD_DIR}"
    mv "${BUILD_DIR}/glfw-${GLFW_VERSION}" "${BUILD_DIR}/glfw"
    cmake -S "${BUILD_DIR}/glfw" -B "${BUILD_DIR}/glfw/build" -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DBUILD_SHARED_LIBS=ON \
        -DGLFW_BUILD_WAYLAND=ON \
        -DGLFW_BUILD_X11=OFF \
        -DGLFW_BUILD_EXAMPLES=OFF -DGLFW_BUILD_TESTS=OFF -DGLFW_BUILD_DOCS=OFF
    ninja -C "${BUILD_DIR}/glfw/build" -j"${JOBS}" install
    done_stamp "glfw-${GLFW_VERSION}"
    rm -rf "${BUILD_DIR}/glfw"
fi

# --- 2. WPE WebKit stack: GONE. The WebView backend is now the Qt WebEngine
# module (libatl_webview_qt.so) against the system Qt 6.10 of 24.04-2.x;
# scrub WPE leftovers from cached stages so they never get shipped again.

if [ -z "${USE_SDK}" ] && ! stamp "wpe-removed"; then
    log "scrubbing WPE artifacts from cached stage"
    rm -rf "${PREFIX}"/lib/libWPE* "${PREFIX}"/lib/libwpe* \
           "${PREFIX}"/lib/wpe-webkit-2.0 "${PREFIX}"/libexec/wpe-webkit-2.0 \
           "${PREFIX}"/include/wpe* "${PREFIX}"/lib/pkgconfig/wpe* \
           "${PREFIX}"/lib/pkgconfig/libwpe* "${PREFIX}"/share/wpe* \
           "${STAMPS}"/libwpe-*.done "${STAMPS}"/wpebackend-fdo-*.done \
           "${STAMPS}"/wpewebkit-*.done
    done_stamp "wpe-removed"
fi

# --- 3. wolfSSL with JNI (distro package has JNI disabled) ---------------

if [ -z "${USE_SDK}" ] && ! stamp "wolfssl-${WOLFSSL_REV}"; then
    log "building wolfSSL"
    rsync -a --delete --exclude=.git "${ROOT}/wolfssl/" "${BUILD_DIR}/wolfssl/"
    (
        cd "${BUILD_DIR}/wolfssl"
        autoreconf -i
        ./configure --prefix="${PREFIX}" \
            --enable-shared --disable-opensslall --disable-opensslextra \
            --enable-aescbc-length-checks --enable-curve25519 --enable-ed25519 \
            --enable-ed25519-stream --enable-oldtls --enable-base64encode \
            --enable-tlsx --enable-scrypt --disable-examples --enable-crl \
            --enable-jni --enable-sessioncerts
        make -j"${JOBS}"
        make install
    )
    done_stamp "wolfssl-${WOLFSSL_REV}"
    rm -rf "${BUILD_DIR}/wolfssl"
fi

# --- 4. vixl (ARM codegen backend for the art compiler; not in noble) ----

if [ -z "${USE_SDK}" ] && [ "${ARCH}" = "arm64" ] && ! stamp "vixl-${VIXL_VERSION}"; then
    log "building vixl ${VIXL_VERSION}"
    fetch "https://github.com/Linaro/vixl/archive/refs/tags/${VIXL_VERSION}.tar.gz" \
          "${VIXL_SHA256}" "vixl-${VIXL_VERSION}.tar.gz"
    rm -rf "${BUILD_DIR}/vixl"
    tar -xf "${DL}/vixl-${VIXL_VERSION}.tar.gz" -C "${BUILD_DIR}"
    mv "${BUILD_DIR}/vixl-${VIXL_VERSION}" "${BUILD_DIR}/vixl"
    patch -d "${BUILD_DIR}/vixl" -p1 < "${ROOT}/patches/vixl_meson_support.patch"
    meson setup "${BUILD_DIR}/vixl/build" "${BUILD_DIR}/vixl" \
        --prefix="${PREFIX}" --libdir=lib --buildtype=release -Dsimulator=none
    ninja -C "${BUILD_DIR}/vixl/build" -j"${JOBS}" install
    done_stamp "vixl-${VIXL_VERSION}"
    rm -rf "${BUILD_DIR}/vixl"
fi

# --- 4b. libunwind >= 1.8 (bionic_translation requires it; noble has 1.6) --

if [ -z "${USE_SDK}" ] && ! stamp "libunwind-${LIBUNWIND_VERSION}"; then
    log "building libunwind ${LIBUNWIND_VERSION}"
    fetch "https://github.com/libunwind/libunwind/releases/download/v${LIBUNWIND_VERSION}/libunwind-${LIBUNWIND_VERSION}.tar.gz" \
          "${LIBUNWIND_SHA256}" "libunwind-${LIBUNWIND_VERSION}.tar.gz"
    rm -rf "${BUILD_DIR}/libunwind"
    tar -xf "${DL}/libunwind-${LIBUNWIND_VERSION}.tar.gz" -C "${BUILD_DIR}"
    mv "${BUILD_DIR}/libunwind-${LIBUNWIND_VERSION}" "${BUILD_DIR}/libunwind"
    (
        cd "${BUILD_DIR}/libunwind"
        ./configure --prefix="${PREFIX}" --disable-tests --disable-documentation
        make -j"${JOBS}"
        make install
    )
    done_stamp "libunwind-${LIBUNWIND_VERSION}"
    rm -rf "${BUILD_DIR}/libunwind"
fi

# --- 5. bionic_translation ------------------------------------------------

if [ -z "${USE_SDK}" ] && ! stamp "bionic_translation-${BIONIC_REV}"; then
    log "building bionic_translation"
    rsync -a --delete --exclude=.git "${ROOT}/bionic_translation/" "${BUILD_DIR}/bionic_translation/"
    patch -d "${BUILD_DIR}/bionic_translation" -p1 < "${ROOT}/patches/bionic_translation-ut.patch"
    patch -d "${BUILD_DIR}/bionic_translation" -p1 < "${ROOT}/patches/bionic_translation-stdio-glibc.patch"
    meson setup "${BUILD_DIR}/bionic_translation/build" "${BUILD_DIR}/bionic_translation" \
        --prefix="${PREFIX}" --libdir=lib --buildtype=release
    ninja -C "${BUILD_DIR}/bionic_translation/build" -j"${JOBS}" install
    done_stamp "bionic_translation-${BIONIC_REV}"
    rm -rf "${BUILD_DIR}/bionic_translation"
fi

# --- 5b. r8/d8 launcher ---------------------------------------------------
# Telegram triggers core-oj-internal lambdas (streams/Collectors); art dexes
# libcore with old `dx`, so those pass through as live invoke-custom hitting
# AOSP's return-null LambdaMetafactory stub and crash. Desugaring core-oj +
# core-libart with d8 at dex time (what AOSP itself does) fixes it. The
# `make ... D8=<launcher>` option comes from patches/art_standalone-d8.patch;
# wire up a d8 over the prebuilt r8 jar (pure Java, so it runs fine under the
# arm64 container's JDK).

# d8 is only needed to build art's boot jars; the SDK ships them prebuilt.
if [ -z "${USE_SDK}" ]; then
    fetch "${R8_URL:-https://maven.google.com/com/android/tools/r8/${R8_VERSION}/r8-${R8_VERSION}.jar}" \
          "${R8_SHA256}" "r8-${R8_VERSION}.jar"
    D8="${PREFIX}/bin/d8"
    mkdir -p "${PREFIX}/bin"
    cat > "${D8}" <<EOF
#!/bin/sh
exec java -Xmx2G -cp "${DL}/r8-${R8_VERSION}.jar" com.android.tools.r8.D8 "\$@"
EOF
    chmod +x "${D8}"
fi

# --- 6. art_standalone (ART runtime, dex2oat, dx, boot classpath) ---------

if [ -z "${USE_SDK}" ] && ! stamp "art_standalone-${ART_REV}-d8${R8_VERSION}"; then
    log "building art_standalone (self-hosted AOSP frankenbuild, d8-desugared boot jars)"
    rsync -a --delete --exclude=.git "${ROOT}/art_standalone/" "${BUILD_DIR}/art_standalone/"
    patch -d "${BUILD_DIR}/art_standalone" -p1 < "${ROOT}/patches/art_standalone-d8.patch"
    # clickable exports ARCH=arm64, but art's envsetup.mk expects uname-style
    # values (aarch64) and maps 'arm64' to 32-bit arm — override explicitly.
    # D8=<launcher> makes the boot jars desugar lambdas like upstream AOSP.
    make -C "${BUILD_DIR}/art_standalone" -j"${JOBS}" \
        ARCH="$(uname -m)" ____PREFIX="${PREFIX}" ____LIBDIR=lib D8="${D8}"
    make -C "${BUILD_DIR}/art_standalone" \
        ARCH="$(uname -m)" ____PREFIX="${PREFIX}" ____LIBDIR=lib D8="${D8}" install
    done_stamp "art_standalone-${ART_REV}-d8${R8_VERSION}"
    rm -rf "${BUILD_DIR}/art_standalone"
fi

# --- 6b. libOpenSLES stub -------------------------------------------------
# Telegram's libtmessages links libOpenSLES.so (mapped to libOpenSLES.so.1 by
# the base bionic cfg), but no host OpenSL ES exists. Ship a no-op stub:
# slCreateEngine reports "unsupported" so Telegram's audio init bails cleanly
# (no voice messages / calls, but the app runs). libjnigraphics + libm are
# handled by cfg maps to real libs (see stubs/mercurygram-bionic.cfg).

if ! stamp "opensles-stub-$(sha256sum "${ROOT}/stubs/opensles_stub.c" | cut -c1-8)"; then
    log "building libOpenSLES stub"
    cc -shared -fPIC -O2 -o "${PREFIX}/lib/libOpenSLES.so.1" "${ROOT}/stubs/opensles_stub.c"
    done_stamp "opensles-stub-$(sha256sum "${ROOT}/stubs/opensles_stub.c" | cut -c1-8)"
fi

# --- 7. atlas ---------------------------------------------------------------
# Skipped when the prebuilt SDK is used (atlas is already staged in PREFIX).

if [ -z "${USE_SDK}" ]; then
    # Always rsync so source changes in the submodule are picked up; the skia
    # subproject clone (fetched by meson wrap on first setup) is preserved.
    log "building atlas"
    rsync -a --delete \
        --exclude=.git --exclude=/builddir --exclude=/subprojects/skia \
        "${ROOT}/atl-touch/" "${BUILD_DIR}/atlas-src/"
    if [ ! -f "${BUILD_DIR}/atlas-build/build.ninja" ]; then
        meson setup "${BUILD_DIR}/atlas-build" "${BUILD_DIR}/atlas-src" \
            --prefix="${CLICK_PREFIX}" --libdir=lib --buildtype=release
    fi
    ninja -C "${BUILD_DIR}/atlas-build" -j"${JOBS}"
    rm -rf "${BUILD_DIR}/atlas-dest"
    DESTDIR="${BUILD_DIR}/atlas-dest" ninja -C "${BUILD_DIR}/atlas-build" install
fi

# --- 8. Mercurygram APK -----------------------------------------------------

fetch "${APK_URL}" "${APK_SHA256}" "Mercurygram-${MERCURYGRAM_VERSION}-${APK_ABI}.apk"

# --- 9. assemble the click package tree -------------------------------------

log "assembling click tree in ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}/usr"

if [ -n "${USE_SDK}" ]; then
    # atlas + all deps come prebuilt in the SDK (already staged in PREFIX, plus
    # the opensles stub); drop the whole runtime tree in — bin/, lib/, libexec/,
    # share/atl (fonts.xml), share/bionic_translation, ...
    rsync -a \
        --exclude='pkgconfig' --exclude='cmake' \
        --exclude='*.a' --exclude='*.la' \
        "${PREFIX}/" "${INSTALL_DIR}/usr/"
else
    # atlas (built with the click runtime prefix)
    cp -a "${BUILD_DIR}/atlas-dest${CLICK_PREFIX}/." "${INSTALL_DIR}/usr/"

    # staged runtime: art, boot classpath, wolfssl, glfw, bionic libs, ...
    rsync -a \
        --exclude='pkgconfig' --exclude='cmake' \
        --exclude='*.a' --exclude='*.la' \
        "${PREFIX}/lib/" "${INSTALL_DIR}/usr/lib/"
    if [ -d "${PREFIX}/libexec" ]; then
        rsync -a "${PREFIX}/libexec/" "${INSTALL_DIR}/usr/libexec/"
    fi
    if [ -d "${PREFIX}/share/bionic_translation" ]; then
        rsync -a "${PREFIX}/share/bionic_translation" "${INSTALL_DIR}/usr/share/"
    fi
fi
# extra bionic library-override maps for Telegram's libtmessages (libm ->
# libm.so.6, libjnigraphics -> libandroid.so.0); merged with the base cfg
install -D "${ROOT}/stubs/mercurygram-bionic.cfg" \
    "${INSTALL_DIR}/usr/share/bionic_translation/cfg.d/mercurygram.cfg"

# the Qt backend runs in-process against system Qt, but Qt's wayland QPA
# refuses to load without a shell-integration plugin and the device image
# ships none — bundle xdg-shell from the build container (same Qt version)
install -D /usr/lib/*/qt6/plugins/wayland-shell-integration/libxdg-shell.so \
    "${INSTALL_DIR}/usr/lib/qt6-plugins/wayland-shell-integration/libxdg-shell.so"

# dex2oat so the device can AOT-compile if our prebuilt oat files are unusable
install -D "${PREFIX}/bin/dex2oat" "${INSTALL_DIR}/usr/bin/dex2oat"
# not needed at runtime
rm -f "${INSTALL_DIR}/usr/lib/java/dx.jar"

# Java trust store for TLS (wolfssljni looks in $JAVA_HOME/lib/security)
install -D /etc/ssl/certs/java/cacerts \
    "${INSTALL_DIR}/usr/share/java_home/lib/security/cacerts"

# the app itself
install -D "${DL}/Mercurygram-${MERCURYGRAM_VERSION}-${APK_ABI}.apk" \
    "${INSTALL_DIR}/usr/share/mercurygram/Mercurygram.apk"

# bundle every shared-library dependency that is not part of the UT rootfs
"${ROOT}/scripts/copy-runtime-libs.sh" "${INSTALL_DIR}"

# strip (before AOT so we never touch the generated oat files)
find "${INSTALL_DIR}/usr" -type f \( -name '*.so' -o -name '*.so.*' \) \
    -exec strip --strip-unneeded {} + 2>/dev/null || true
strip --strip-unneeded "${INSTALL_DIR}/usr/bin/android-translation-layer" \
    "${INSTALL_DIR}/usr/bin/dex2oat" 2>/dev/null || true

# click metadata + launcher
install -m 0644 "${ROOT}/manifest.json"       "${INSTALL_DIR}/manifest.json"
install -m 0644 "${ROOT}/${APP_HOOK}.apparmor" "${INSTALL_DIR}/"
install -m 0644 "${ROOT}/${APP_HOOK}.desktop"  "${INSTALL_DIR}/"
install -m 0644 "${ROOT}/${APP_HOOK}.svg"      "${INSTALL_DIR}/"
install -m 0755 "${ROOT}/${APP_HOOK}.sh"       "${INSTALL_DIR}/"

# --- 10. AOT-compile boot classpath, api-impl and the APK (best effort) -----
# Mirrors the flathub BaseApp/NewPipe run-dex2oat modules. dex locations use
# the version-independent 'current' click path so they stay valid on device.
# If anything here fails (e.g. dex2oat unhappy under qemu) the package still
# works: ART falls back to JIT/interpreter and on-device dex2oat.

if [ "${ATLAS_CLICK_SKIP_AOT:-0}" != "1" ]; then
    log "AOT compiling (dex2oat) — best effort"
    ARTLIB="${INSTALL_DIR}/usr/lib/java/dex/art"
    ATLLIB="${INSTALL_DIR}/usr/lib/java/dex/android_translation_layer"
    (
        set -e
        export LD_LIBRARY_PATH="${PREFIX}/lib/art:${PREFIX}/lib"
        BOOT_JARS=(core-oj-hostdex apachehttp-hostdex apache-xml-hostdex \
                   bouncycastle-hostdex core-junit-hostdex core-libart-hostdex \
                   hamcrest-hostdex junit-runner-hostdex okhttp-hostdex \
                   wolfssljni-hostdex)
        DEX_ARGS=()
        for jar in "${BOOT_JARS[@]}"; do
            DEX_ARGS+=(--dex-file="${ARTLIB}/${jar}.jar" \
                       --dex-location="${CLICK_PREFIX}/lib/java/dex/art/${jar}.jar")
        done
        mkdir -p "${ARTLIB}/oat/${ART_ARCH}" "${ATLLIB}/oat/${ART_ARCH}" \
                 "${INSTALL_DIR}/usr/share/mercurygram/oat/${ART_ARCH}"
        "${PREFIX}/bin/dex2oat" -j1 \
            --image="${ARTLIB}/oat/${ART_ARCH}/boot.art" \
            "${DEX_ARGS[@]}" \
            --oat-file="${ARTLIB}/oat/${ART_ARCH}/boot.oat" \
            --base=0x60cf8000 --host
        chmod +x "${ARTLIB}/oat/${ART_ARCH}/"*.oat
        "${PREFIX}/bin/dex2oat" -j"${JOBS}" \
            --boot-image="${ARTLIB}/oat/${ART_ARCH}/boot.art" \
            --dex-file="${ATLLIB}/api-impl.jar" \
            --dex-location="${CLICK_PREFIX}/lib/java/dex/android_translation_layer/api-impl.jar" \
            --oat-file="${ATLLIB}/oat/${ART_ARCH}/api-impl.odex" \
            --host
        "${PREFIX}/bin/dex2oat" -j"${JOBS}" \
            --boot-image="${ARTLIB}/oat/${ART_ARCH}/boot.art" \
            --dex-file="${INSTALL_DIR}/usr/share/mercurygram/Mercurygram.apk" \
            --dex-location="${CLICK_PREFIX}/share/mercurygram/Mercurygram.apk" \
            --oat-file="${INSTALL_DIR}/usr/share/mercurygram/oat/${ART_ARCH}/Mercurygram.odex" \
            --host
        chmod +x "${ATLLIB}/oat/${ART_ARCH}/"*.odex \
                 "${INSTALL_DIR}/usr/share/mercurygram/oat/${ART_ARCH}/"*.odex
    ) || {
        log "WARNING: dex2oat AOT pass failed — shipping without prebuilt oat files"
        rm -rf "${INSTALL_DIR}/usr/lib/java/dex/art/oat" \
               "${INSTALL_DIR}/usr/lib/java/dex/android_translation_layer/oat" \
               "${INSTALL_DIR}/usr/share/mercurygram/oat"
    }
fi

log "done — $(du -sh "${INSTALL_DIR}" | cut -f1) in ${INSTALL_DIR}"
