#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${PROJECT_DIR}/../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${REPO_ROOT}/build}"
CONFIGURATION="${CONFIGURATION:-release}"
BUNDLE_IDENTIFIER="com.yuki-yano.vde-notifier-app.agent"

env -u LIBRARY_PATH swift build --package-path "${PROJECT_DIR}" --configuration "${CONFIGURATION}" --product vde-notifier-app

BINARY_PATH="${PROJECT_DIR}/.build/arm64-apple-macosx/${CONFIGURATION}/vde-notifier-app"
if [[ ! -x "${BINARY_PATH}" ]]; then
  BINARY_PATH="${PROJECT_DIR}/.build/${CONFIGURATION}/vde-notifier-app"
fi

if [[ ! -x "${BINARY_PATH}" ]]; then
  echo "build output not found: ${BINARY_PATH}" >&2
  exit 1
fi

APP_DIR="${BUILD_DIR}/VdeNotifierApp.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${BINARY_PATH}" "${MACOS_DIR}/vde-notifier-app"
chmod +x "${MACOS_DIR}/vde-notifier-app"

# Copy app icon
ICON_SRC="${PROJECT_DIR}/Resources/AppIcon.icns"
if [[ ! -f "${ICON_SRC}" ]]; then
  echo "app icon not found: ${ICON_SRC}" >&2
  exit 1
fi
cp "${ICON_SRC}" "${RESOURCES_DIR}/AppIcon.icns"

cat > "${CONTENTS_DIR}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>vde-notifier-app</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_IDENTIFIER}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>VdeNotifierApp</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none --identifier "${BUNDLE_IDENTIFIER}" "${MACOS_DIR}/vde-notifier-app"
codesign --force --deep --sign - --timestamp=none --identifier "${BUNDLE_IDENTIFIER}" "${APP_DIR}"

echo "Built app bundle: ${APP_DIR}"
