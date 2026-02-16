#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
APP_BUNDLE_PATH="${APP_BUNDLE_PATH:-${REPO_ROOT}/build/VdeNotifierApp.app}"
OUTPUT_NAME="${OUTPUT_NAME:-VdeNotifierApp.app.tar.gz}"
OUTPUT_PATH="${OUTPUT_PATH:-${REPO_ROOT}/${OUTPUT_NAME}}"

"${SCRIPT_DIR}/build-app.sh"

if [[ ! -d "${APP_BUNDLE_PATH}" ]]; then
  echo "app bundle not found: ${APP_BUNDLE_PATH}" >&2
  exit 1
fi

rm -f "${OUTPUT_PATH}"
tar -C "$(dirname "${APP_BUNDLE_PATH}")" -czf "${OUTPUT_PATH}" "$(basename "${APP_BUNDLE_PATH}")"

echo "Created release asset: ${OUTPUT_PATH}"
shasum -a 256 "${OUTPUT_PATH}"
