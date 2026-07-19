#!/bin/sh
# Launcher: run Telegram (Mercurygram) through the bundled atlas runtime.

APP_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PKG_NAME=mercurygram.nekit

# Prefer the version-independent 'current' click path: compiled-in rpaths
# and the AOT dex locations point there. Fall back to our own directory
# (e.g. when running from an unpacked tree on a desktop).
PKG_ROOT="/opt/click.ubuntu.com/${PKG_NAME}/current"
[ -x "${PKG_ROOT}/usr/bin/android-translation-layer" ] || PKG_ROOT="${APP_DIR}"

export LD_LIBRARY_PATH="${PKG_ROOT}/usr/lib/art:${PKG_ROOT}/usr/lib:${PKG_ROOT}/usr/lib/java/dex/android_translation_layer/natives${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export PATH="${PKG_ROOT}/usr/bin:${PATH}"

# TLS trust store for wolfssljni ($JAVA_HOME/lib/security/cacerts)
export JAVA_HOME="${PKG_ROOT}/usr/share/java_home"

# bionic_translation reads its library-override rules (libc.so -> libc_bio.so.0,
# libm.so -> libm.so.6, libjnigraphics.so -> libandroid.so.0, libOpenSLES.so ->
# libOpenSLES.so.1, ...) from $XDG_DATA_DIRS/bionic_translation/cfg.d; without
# this Telegram's libtmessages.49.so fails to link its native deps.
export XDG_DATA_DIRS="${PKG_ROOT}/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"

# Telegram opens in-app browsers / bot web apps in a WebView; use the Qt
# WebEngine backend against the system Qt 6.10. Qt's wayland QPA needs a
# shell-integration plugin, which the device image lacks — the click bundles
# xdg-shell.
export ATL_UGLY_ENABLE_WEBVIEW=1
export ATL_WEBVIEW_MODULE=qt
export QT_QPA_PLATFORM=wayland
export QT_PLUGIN_PATH="${PKG_ROOT}/usr/lib/qt6-plugins${QT_PLUGIN_PATH:+:${QT_PLUGIN_PATH}}"

# Wayland app_id must match the desktop file id (<pkg>_<app>_<version>) for
# Lomiri to associate the window with the launcher entry; atlas picks this
# up via $APP_ID (see patches/atlas-ut-window.patch)
if [ -z "${APP_ID:-}" ] && [ -L "/opt/click.ubuntu.com/${PKG_NAME}/current" ]; then
    PKG_VERSION="$(basename "$(readlink -f "/opt/click.ubuntu.com/${PKG_NAME}/current")")"
    export APP_ID="${PKG_NAME}_mercurygram_${PKG_VERSION}"
fi

# Keep app data in one dedicated place
export ANDROID_APP_DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/${PKG_NAME}"
mkdir -p "${ANDROID_APP_DATA_DIR}"

exec "${PKG_ROOT}/usr/bin/android-translation-layer" \
    --gapplication-app-id=${PKG_NAME}_mercurygram \
    "${PKG_ROOT}/usr/share/mercurygram/Mercurygram.apk" \
    -l org/telegram/ui/LaunchActivity "$@"
