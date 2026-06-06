#!/bin/bash
# Fetches FFmpegKit xcframeworks from faroukbmiled/ffmpeg-kit releases and
# extracts the arm64 device frameworks into modules/ffmpegkit/.
#
# Env overrides:
#   SCI_FFMPEGKIT_TAG=<tag>    pin a specific release (default: latest)
#   SCI_FFMPEGKIT_REFRESH=1    force re-fetch even if already installed
#   SCI_FFMPEGKIT_KEEP_FAT=1   skip lipo thinning (keep arm64+arm64e fat)

set -e

REPO="faroukbmiled/ffmpeg-kit"
ASSET="ffmpeg-kit-ios-xcframework-xcode-16.2.zip"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/modules/ffmpegkit"
CACHE_ROOT="$DEST/.cache"

mkdir -p "$DEST" "$CACHE_ROOT"

if [ -f "$DEST/ffmpegkit.framework/ffmpegkit" ] && [ -d "$DEST/libavcodec.framework" ] && [ -z "$SCI_FFMPEGKIT_REFRESH" ]; then
    echo "[ffmpegkit] Already present (${DEST}). Set SCI_FFMPEGKIT_REFRESH=1 to re-fetch."
    exit 0
fi

if [ -n "$SCI_FFMPEGKIT_TAG" ]; then
    TAG="$SCI_FFMPEGKIT_TAG"
else
    REDIRECT=$(curl -fsLI -o /dev/null -w '%{url_effective}\n' "https://github.com/$REPO/releases/latest" 2>/dev/null || true)
    TAG="${REDIRECT##*/tag/}"
    [ -z "$TAG" ] || [ "$TAG" = "$REDIRECT" ] && { echo "[ffmpegkit] ERROR: could not resolve latest release at https://github.com/$REPO/releases" >&2; exit 1; }
fi
echo "[ffmpegkit] Using release $TAG"

CACHE_DIR="$CACHE_ROOT/$TAG"
URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"

for old in "$DEST"/*.framework; do [ -d "$old" ] && rm -rf "$old"; done

if [ -d "$CACHE_DIR" ] && [ "$(ls -A "$CACHE_DIR"/*.framework 2>/dev/null | head -1)" ]; then
    echo "[ffmpegkit] Cache hit ($CACHE_DIR)"
    cp -R "$CACHE_DIR"/*.framework "$DEST/"
else
    rm -rf "$CACHE_DIR"
    mkdir -p "$CACHE_DIR"
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    echo "[ffmpegkit] Downloading $ASSET..."
    curl -fL --progress-bar -o "$TMP/asset.zip" "$URL" || { echo "[ffmpegkit] ERROR: download failed from $URL" >&2; exit 1; }
    unzip -q "$TMP/asset.zip" -d "$TMP/unpacked"

    for xcfw in "$TMP/unpacked"/*.xcframework; do
        [ -d "$xcfw" ] || continue
        NAME=$(basename "$xcfw" .xcframework)
        SLICE="$xcfw/ios-arm64_arm64e/$NAME.framework"
        [ -d "$SLICE" ] || SLICE="$xcfw/ios-arm64/$NAME.framework"
        [ -d "$SLICE" ] || { echo "[ffmpegkit]   $NAME: no ios-arm64 slice, skipping"; continue; }
        cp -R "$SLICE" "$CACHE_DIR/"
        if [ -z "$SCI_FFMPEGKIT_KEEP_FAT" ] && command -v lipo >/dev/null 2>&1; then
            BIN="$CACHE_DIR/$NAME.framework/$NAME"
            if lipo -archs "$BIN" 2>/dev/null | grep -q arm64e; then
                lipo "$BIN" -thin arm64 -output "$BIN.thin" && mv "$BIN.thin" "$BIN"
            fi
        fi
        echo "[ffmpegkit]   $NAME.framework"
    done

    cp -R "$CACHE_DIR"/*.framework "$DEST/"
    rm -rf "$TMP"
    trap - EXIT
fi

ls -1t "$CACHE_ROOT" 2>/dev/null | tail -n +3 | while read -r old; do rm -rf "$CACHE_ROOT/$old"; done

FW_TOTAL=$(du -shc "$DEST"/*.framework 2>/dev/null | tail -1 | cut -f1)
echo "[ffmpegkit] Done — $(ls -d "$DEST"/*.framework 2>/dev/null | wc -l | tr -d ' ') frameworks installed (${FW_TOTAL})."
