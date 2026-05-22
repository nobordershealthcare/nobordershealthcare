#!/bin/bash
# sync-to-xcode.sh — Copy repo source files into the separate Xcode project.
#
# The canonical source of truth is noborders-repo.
# Run this after every change to propagate edits into nobordershealthcare-app.
#
# Usage: ./scripts/sync-to-xcode.sh

set -euo pipefail

REPO=~/Projects/Claude/nobordershealthcare/noborders-repo
XCODE=~/Projects/Claude/nobordershealthcare/nobordershealthcare-app/nobordershealthcare-app

cp "$REPO/ios/App/ContentView.swift"                                              "$XCODE/"
cp "$REPO/ios/App/nobordershealthcare_appApp.swift"                               "$XCODE/"
cp "$REPO/ios/Sources/nobordershealthcare/Location/NetworkCountryDetector.swift"  "$XCODE/"
cp "$REPO/ios/Sources/nobordershealthcare/Support/SupportProfile.swift"           "$XCODE/"

echo "✅ Synced to Xcode project"
