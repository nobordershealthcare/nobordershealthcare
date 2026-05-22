#!/bin/bash
# sync-to-xcode.sh — Kept for reference; the stale nobordershealthcare-app project.
#
# NOTE: The canonical Xcode project is now ios/nobordershealthcare.xcodeproj,
# generated from ios/project.yml via `xcodegen generate` (run from ios/).
# The separate nobordershealthcare-app project is no longer the primary target.
#
# To regenerate the project after editing project.yml:
#   cd ios && xcodegen generate
#
# To build for simulator:
#   cd ios && xcodebuild -scheme nobordershealthcare \
#     -destination 'platform=iOS Simulator,name=iPhone 17' \
#     CODE_SIGNING_ALLOWED=NO build
#
# Legacy sync (nobordershealthcare-app) kept below for reference:

set -euo pipefail

REPO=~/Projects/Claude/nobordershealthcare/noborders-repo
XCODE=~/Projects/Claude/nobordershealthcare/nobordershealthcare-app/nobordershealthcare-app

cp "$REPO/ios/App/ContentView.swift"                                              "$XCODE/"
cp "$REPO/ios/App/nobordershealthcare_appApp.swift"                               "$XCODE/"
cp "$REPO/ios/Sources/nobordershealthcare/Location/NetworkCountryDetector.swift"  "$XCODE/"
cp "$REPO/ios/Sources/nobordershealthcare/Support/SupportProfile.swift"           "$XCODE/"

echo "✅ Synced to legacy Xcode project (consider switching to ios/nobordershealthcare.xcodeproj)"
