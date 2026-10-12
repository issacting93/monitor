#!/bin/bash
# package-appstore.sh — archive the sandboxed macOS app and export an
# App Store Connect upload package.
#
# This is the Mac App Store pipeline and is separate from the ad-hoc
# package.sh dev build. It needs a real Apple Developer Team ID and
# signing certificate, so it only works after enrolment (plan Part 4).
#
# Prerequisites:
#   1. Enrolled in the Apple Developer Program.
#   2. DEVELOPMENT_TEAM set in Tape08/Tape08.xcodeproj (or passed here).
#   3. teamID filled in ExportOptions.plist.
#
# Usage:
#   Tools/package-appstore.sh [TEAM_ID]
set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="Tape08"
PROJECT="Tape08/Tape08.xcodeproj"
ARCHIVE=".build/Tape08.xcarchive"
EXPORT_DIR=".build/appstore"

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

TEAM_ID="${1:-}"
if [ -z "${TEAM_ID}" ]; then
    echo "error: no Team ID given. Pass it as an argument or set DEVELOPMENT_TEAM in Xcode." >&2
    echo "       e.g. Tools/package-appstore.sh ABCDE12345" >&2
    exit 1
fi

mkdir -p .build

echo "==> Archiving ${SCHEME}..."
xcodebuild -project "${PROJECT}" -scheme "${SCHEME}" \
    -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "${ARCHIVE}" \
    DEVELOPMENT_TEAM="${TEAM_ID}" \
    archive

echo "==> Exporting App Store package..."
rm -rf "${EXPORT_DIR}"
mkdir -p "${EXPORT_DIR}"
xcodebuild -exportArchive \
    -archivePath "${ARCHIVE}" \
    -exportPath "${EXPORT_DIR}" \
    -exportOptionsPlist ExportOptions.plist

echo "==> Done. Upload package(s) in: ${EXPORT_DIR}"
echo "    Upload with:  xcrun altool --upload-app -f <file>.pkg -t macos \\"
echo "                    --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>"
echo "    or open the archive in Xcode Organizer and click Distribute App."
