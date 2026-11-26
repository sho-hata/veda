#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Veda"
VOLUME_NAME="Install ${APP_NAME}"
APP_BUNDLE="${ROOT_DIR}/dist/${APP_NAME}.app"
DMG_OUTPUT="${ROOT_DIR}/dist/${APP_NAME}.dmg"
ASSETS_DIR="${ROOT_DIR}/dist/.assets"
BG_DIR="${ASSETS_DIR}/dmg-bg"
ICON_PATH="${ASSETS_DIR}/${APP_NAME}.icns"

SKIP_APP_BUILD="false"
APP_BUILD_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-app-build)
            SKIP_APP_BUILD="true"
            shift
            ;;
        --debug|--release)
            APP_BUILD_ARGS+=("$1")
            shift
            ;;
        --sign)
            APP_BUILD_ARGS+=("$1" "$2")
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--release|--debug] [--sign <identity>] [--skip-app-build]" >&2
            exit 1
            ;;
    esac
done

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/veda-clang-module-cache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-/tmp/veda-swift-module-cache}"
mkdir -p "${CLANG_MODULE_CACHE_PATH}" "${SWIFT_MODULECACHE_PATH}" "${BG_DIR}"

if [[ "${SKIP_APP_BUILD}" != "true" ]]; then
    "${ROOT_DIR}/scripts/build-app.sh" "${APP_BUILD_ARGS[@]}"
fi

if [[ ! -d "${APP_BUNDLE}" ]]; then
    echo "App bundle not found: ${APP_BUNDLE}" >&2
    exit 1
fi

echo "Generating DMG background artwork..."
swift "${ROOT_DIR}/scripts/generate-assets.swift" --dmg-bg "${BG_DIR}"

# TIFF マルチレゾリューション背景を作成（Retina と非 Retina の両方でクッキリ表示される）
DMG_BG_TIFF="${BG_DIR}/background.tiff"
tiffutil -cathidpicheck "${BG_DIR}/background.png" "${BG_DIR}/background@2x.png" -out "${DMG_BG_TIFF}"

WORK_DIR="$(mktemp -d /tmp/veda-dmg-XXXXXX)"
STAGING_DIR="${WORK_DIR}/staging"
RW_DMG="${WORK_DIR}/${APP_NAME}-rw.dmg"
MOUNT_POINT=""

cleanup() {
    if [[ -n "${MOUNT_POINT}" && -d "${MOUNT_POINT}" ]]; then
        hdiutil detach "${MOUNT_POINT}" -quiet || hdiutil detach "${MOUNT_POINT}" -force -quiet || true
    fi
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

mkdir -p "${STAGING_DIR}/.background"
cp -R "${APP_BUNDLE}" "${STAGING_DIR}/${APP_NAME}.app"
ln -s /Applications "${STAGING_DIR}/Applications"
cp "${DMG_BG_TIFF}" "${STAGING_DIR}/.background/background.tiff"

if [[ -f "${ICON_PATH}" ]]; then
    cp "${ICON_PATH}" "${STAGING_DIR}/.VolumeIcon.icns"
fi

echo "Creating read-write DMG..."
hdiutil create \
    -volname "${VOLUME_NAME}" \
    -srcfolder "${STAGING_DIR}" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -ov \
    "${RW_DMG}" >/dev/null

# もし以前のマウントが残っていれば事前に解除する
if [[ -d "/Volumes/${VOLUME_NAME}" ]]; then
    hdiutil detach "/Volumes/${VOLUME_NAME}" -force -quiet || true
fi

echo "Mounting read-write DMG to configure Finder drag-and-drop layout..."
ATTACH_OUTPUT="$(hdiutil attach -readwrite -noverify -noautoopen "${RW_DMG}")"
MOUNT_POINT="$(echo "${ATTACH_OUTPUT}" | awk '/\/Volumes\// { idx = index($0, "/Volumes/"); print substr($0, idx); exit }')"

if [[ -z "${MOUNT_POINT}" ]]; then
    echo "Failed to determine DMG mount point." >&2
    exit 1
fi

MOUNT_NAME="$(basename "${MOUNT_POINT}")"

# ボリュームアイコンを有効化（SetFile が利用可能な場合）
if [[ -f "${MOUNT_POINT}/.VolumeIcon.icns" ]] && command -v SetFile >/dev/null 2>&1; then
    SetFile -a C "${MOUNT_POINT}" || true
fi

# Finder ウィンドウの美しいドラッグ＆ドロップレイアウトを適用（応答がない環境でも最大 15 秒でフォールバック）
APPLESCRIPT_FILE="${WORK_DIR}/configure-finder.applescript"
cat > "${APPLESCRIPT_FILE}" << EOF
with timeout of 12 seconds
    tell application "Finder"
        tell disk "${MOUNT_NAME}"
            open
            delay 0.5
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {200, 140, 860, 520}
            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 112
            set text size of viewOptions to 13
            set background picture of viewOptions to file ".background:background.tiff"
            set position of item "${APP_NAME}.app" of container window to {175, 164}
            set position of item "Applications" of container window to {485, 164}
            close
            open
            update without registering applications
            delay 1
            close
        end tell
    end tell
end timeout
EOF

set +e
perl -e 'alarm 15; exec @ARGV' osascript "${APPLESCRIPT_FILE}"
OSASCRIPT_STATUS=$?
set -e

if [[ "${OSASCRIPT_STATUS}" -ne 0 ]]; then
    echo "Warning: Could not apply Finder window layout via AppleScript (status ${OSASCRIPT_STATUS}). Continuing with standard DMG packaging." >&2
fi

sync
hdiutil detach "${MOUNT_POINT}" -quiet
MOUNT_POINT=""

rm -f "${DMG_OUTPUT}"
echo "Compressing final DMG: ${DMG_OUTPUT}"
hdiutil convert "${RW_DMG}" -format UDZO -imagekey zlib-level=9 -o "${DMG_OUTPUT}" >/dev/null

echo "Created drag-and-drop installer DMG: ${DMG_OUTPUT}"
