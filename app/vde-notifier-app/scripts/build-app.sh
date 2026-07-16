#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${PROJECT_DIR}/../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${REPO_ROOT}/build}"
CONFIGURATION="${CONFIGURATION:-release}"
BUNDLE_IDENTIFIER="com.yuki-yano.vde-notifier-app.agent"
APP_VERSION="${APP_VERSION:-}"

# Prefer explicit env, then current app-v tag, then a local development fallback.
if [[ -z "${APP_VERSION}" ]]; then
  TAG="$(git -C "${REPO_ROOT}" describe --tags --exact-match 2>/dev/null || true)"
  if [[ "${TAG}" =~ ^app-v([0-9]+(\.[0-9]+)*)$ ]]; then
    APP_VERSION="${BASH_REMATCH[1]}"
  fi
fi

APP_VERSION="${APP_VERSION:-0.0.0-dev}"
APP_BUILD_VERSION="${APP_BUILD_VERSION:-${GITHUB_RUN_NUMBER:-1}}"

TARGET_TRIPLES=(
  "arm64-apple-macosx14.0"
  "x86_64-apple-macosx14.0"
)
BINARY_PATHS=()

for triple in "${TARGET_TRIPLES[@]}"; do
  env -u LIBRARY_PATH swift build \
    --package-path "${PROJECT_DIR}" \
    --configuration "${CONFIGURATION}" \
    --product vde-notifier-app \
    --triple "${triple}"

  target_directory="${triple%14.0}"
  binary_path="${PROJECT_DIR}/.build/${target_directory}/${CONFIGURATION}/vde-notifier-app"
  if [[ ! -x "${binary_path}" ]]; then
    echo "build output not found: ${binary_path}" >&2
    exit 1
  fi
  BINARY_PATHS+=("${binary_path}")
done

UNIVERSAL_DIR="${PROJECT_DIR}/.build/universal/${CONFIGURATION}"
UNIVERSAL_BINARY="${UNIVERSAL_DIR}/vde-notifier-app"
mkdir -p "${UNIVERSAL_DIR}"
xcrun lipo -create "${BINARY_PATHS[@]}" -output "${UNIVERSAL_BINARY}"
xcrun lipo "${UNIVERSAL_BINARY}" -verify_arch arm64 x86_64
codesign --force --sign - --timestamp=none --identifier "${BUNDLE_IDENTIFIER}" "${UNIVERSAL_BINARY}"

APP_DIR="${BUILD_DIR}/VdeNotifierApp.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${UNIVERSAL_BINARY}" "${MACOS_DIR}/vde-notifier-app"
chmod +x "${MACOS_DIR}/vde-notifier-app"
cp "${UNIVERSAL_BINARY}" "${MACOS_DIR}/vde-notifier"
chmod +x "${MACOS_DIR}/vde-notifier"

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
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${APP_BUILD_VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - --timestamp=none --identifier "${BUNDLE_IDENTIFIER}" "${APP_DIR}"

plutil -lint "${CONTENTS_DIR}/Info.plist"
codesign --verify --deep --strict "${APP_DIR}"
xcrun lipo "${MACOS_DIR}/vde-notifier-app" -verify_arch arm64 x86_64

echo "Built app bundle: ${APP_DIR}"
