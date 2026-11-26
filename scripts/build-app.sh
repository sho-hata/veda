#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Veda"
BUNDLE_ID="com.sho-hata.veda"
APP_VERSION="${VEDA_VERSION:-1.0.0}"
BUILD_NUMBER="${VEDA_BUILD_NUMBER:-1}"
CONFIG="release"
SIGN_IDENTITY="-"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)
            CONFIG="debug"
            shift
            ;;
        --release)
            CONFIG="release"
            shift
            ;;
        --sign)
            SIGN_IDENTITY="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--release|--debug] [--sign <identity>]" >&2
            exit 1
            ;;
    esac
done

APP_BUNDLE="${ROOT_DIR}/dist/${APP_NAME}.app"
BINARY_PATH="${ROOT_DIR}/.build/${CONFIG}/${APP_NAME}"
ICON_PATH="${ROOT_DIR}/dist/.assets/${APP_NAME}.icns"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/veda-clang-module-cache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-/tmp/veda-swift-module-cache}"
mkdir -p "${CLANG_MODULE_CACHE_PATH}" "${SWIFT_MODULECACHE_PATH}" "${ROOT_DIR}/dist/.assets"

echo "Building ${APP_NAME} (${CONFIG})..."
(
    cd "${ROOT_DIR}"
    swift build -c "${CONFIG}" --disable-sandbox
)

echo "Generating ${APP_NAME}.icns..."
swift "${ROOT_DIR}/scripts/generate-assets.swift" --icon "${ICON_PATH}"

rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BINARY_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "${ICON_PATH}" "${APP_BUNDLE}/Contents/Resources/${APP_NAME}.icns"

cat > "${APP_BUNDLE}/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ja</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>残像エフェクトを描画するため、画面収録の許可が必要です。</string>
</dict>
</plist>
EOF

codesign --force --deep --sign "${SIGN_IDENTITY}" --identifier "${BUNDLE_ID}" "${APP_BUNDLE}"
echo "Created signed app bundle: ${APP_BUNDLE}"
