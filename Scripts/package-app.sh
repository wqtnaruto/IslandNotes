#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
PRODUCT_NAME=${PRODUCT_NAME:-IslandNotes}
BUNDLE_ID=${BUNDLE_ID:-dev.islandnotes.app}
VERSION=${VERSION:-0.2.0}
BUILD_NUMBER=${BUILD_NUMBER:-1}
OUTPUT_DIR=${OUTPUT_DIR:-${PROJECT_DIR}/dist.noindex}
APP_DIR=${OUTPUT_DIR}/${PRODUCT_NAME}.app
CONTENTS_DIR=${APP_DIR}/Contents

cd "${PROJECT_DIR}"
rm -rf ".build/release/IslandNotes_IslandNotes.bundle"
swift build -c release --disable-sandbox

rm -rf "${APP_DIR}"
mkdir -p "${CONTENTS_DIR}/MacOS" "${CONTENTS_DIR}/Resources"
install -m 755 ".build/release/IslandNotes" "${CONTENTS_DIR}/MacOS/${PRODUCT_NAME}"
install -m 644 "Resources/Info.plist" "${CONTENTS_DIR}/Info.plist"
RESOURCE_BUNDLE=".build/release/IslandNotes_IslandNotes.bundle"
if [[ -d "${RESOURCE_BUNDLE}" ]]; then
  ditto "${RESOURCE_BUNDLE}" "${CONTENTS_DIR}/Resources/IslandNotes_IslandNotes.bundle"
  for LANGUAGE_DIR in "${RESOURCE_BUNDLE}"/Contents/Resources/*.lproj(N); do
    if [[ -d "${LANGUAGE_DIR}" ]]; then
      ditto "${LANGUAGE_DIR}" "${CONTENTS_DIR}/Resources/${LANGUAGE_DIR:t}"
    fi
  done
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${PRODUCT_NAME}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ${PRODUCT_NAME}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ${PRODUCT_NAME}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${CONTENTS_DIR}/Info.plist"

NESTED_BUNDLE="${CONTENTS_DIR}/Resources/IslandNotes_IslandNotes.bundle"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  if [[ -d "${NESTED_BUNDLE}" ]]; then
    codesign --force --sign "${SIGN_IDENTITY}" "${NESTED_BUNDLE}"
  fi
  codesign --force --options runtime --sign "${SIGN_IDENTITY}" "${APP_DIR}"
else
  if [[ -d "${NESTED_BUNDLE}" ]]; then
    codesign --force --sign - "${NESTED_BUNDLE}"
  fi
  codesign --force --sign - "${APP_DIR}"
fi

rm -f "${OUTPUT_DIR}/${PRODUCT_NAME}.zip" "${OUTPUT_DIR}/${PRODUCT_NAME}.zip.sha256"
ditto -c -k --sequesterRsrc --keepParent "${APP_DIR}" "${OUTPUT_DIR}/${PRODUCT_NAME}.zip"
(cd "${OUTPUT_DIR}" && shasum -a 256 "${PRODUCT_NAME}.zip" > "${PRODUCT_NAME}.zip.sha256")

echo "Created ${APP_DIR}"
echo "Created ${OUTPUT_DIR}/${PRODUCT_NAME}.zip"
