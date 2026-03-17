#!/usr/bin/env bash
set -euo pipefail

PROJECT_PATH="${PROJECT_PATH:-CommandHub.xcodeproj}"
SCHEME="${SCHEME:-CommandHub}"
CONFIGURATION="${CONFIGURATION:-Release}"
APP_NAME="${APP_NAME:-CommandHub}"

DERIVED_DATA="${DERIVED_DATA:-$PWD/build/DerivedData}"
OUT_DIR="${OUT_DIR:-$PWD/build/release}"
STAGE_DIR="${STAGE_DIR:-$PWD/build/dmg-stage}"

VERSION="${VERSION:-}"
if [[ -z "${VERSION}" ]]; then
  if command -v git >/dev/null 2>&1; then
    VERSION="$(git describe --tags --always --dirty 2>/dev/null || true)"
  fi
fi
VERSION="${VERSION:-dev}"

echo "Building ${APP_NAME} (${SCHEME}, ${CONFIGURATION})..."
rm -rf "${DERIVED_DATA}" "${OUT_DIR}" "${STAGE_DIR}"
mkdir -p "${OUT_DIR}" "${STAGE_DIR}"

xcode_args=(
  build
  -project "${PROJECT_PATH}"
  -scheme "${SCHEME}"
  -configuration "${CONFIGURATION}"
  -derivedDataPath "${DERIVED_DATA}"
  -destination "generic/platform=macOS"
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  ONLY_ACTIVE_ARCH=NO
)

# If VERSION is a simple semver tag (e.g. v1.3.0), propagate it into the app's Info.plist
# via Xcode build settings so the released app reports the correct version.
if [[ "${VERSION}" =~ ^v?([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  APP_VERSION="${BASH_REMATCH[1]}"
  xcode_args+=(MARKETING_VERSION="${APP_VERSION}" CURRENT_PROJECT_VERSION="${APP_VERSION}")
fi

if [[ -n "${ARCHS:-}" ]]; then
  xcode_args+=(ARCHS="${ARCHS}")
fi

xcodebuild "${xcode_args[@]}"

APP_PATH=""
while IFS= read -r -d '' candidate; do
  APP_PATH="${candidate}"
  break
done < <(find "${DERIVED_DATA}/Build/Products" -maxdepth 4 -type d -name "${APP_NAME}.app" -path "*${CONFIGURATION}*" -print0)

if [[ -z "${APP_PATH}" || ! -d "${APP_PATH}" ]]; then
  echo "ERROR: Built app not found under ${DERIVED_DATA}/Build/Products" >&2
  exit 1
fi

echo "App: ${APP_PATH}"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  echo "Codesigning with identity: ${CODESIGN_IDENTITY}"
  ENTITLEMENTS_ARGS=()
  if [[ -n "${CODESIGN_ENTITLEMENTS:-}" ]]; then
    ENTITLEMENTS_ARGS=(--entitlements "${CODESIGN_ENTITLEMENTS}")
  fi
  codesign --force --deep --options runtime --timestamp --sign "${CODESIGN_IDENTITY}" "${ENTITLEMENTS_ARGS[@]}" "${APP_PATH}"
  codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
fi

echo "Staging DMG..."
cp -R "${APP_PATH}" "${STAGE_DIR}/"
ln -sf /Applications "${STAGE_DIR}/Applications"

DMG_PATH="${OUT_DIR}/${APP_NAME}-${VERSION}.dmg"
SHA_PATH="${DMG_PATH}.sha256"

echo "Creating DMG: ${DMG_PATH}"
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGE_DIR}" -ov -format UDZO "${DMG_PATH}"
shasum -a 256 "${DMG_PATH}" > "${SHA_PATH}"

if [[ -n "${APPLE_ID:-}" && -n "${APPLE_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
  echo "Notarizing DMG..."
  xcrun notarytool submit "${DMG_PATH}" --wait --apple-id "${APPLE_ID}" --password "${APPLE_PASSWORD}" --team-id "${APPLE_TEAM_ID}"
  xcrun stapler staple "${DMG_PATH}"
fi

echo "Done."
echo "DMG: ${DMG_PATH}"
echo "SHA: ${SHA_PATH}"
