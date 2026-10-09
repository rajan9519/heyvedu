#!/usr/bin/env bash
# Build "HeyVedu Dev" (Debug) and launch it, without Xcode's UI. Day-to-day, open
# HeyVedu.xcodeproj and press ⌘R instead; both build into Xcode's DerivedData, so they share
# one build and nothing is copied into /Applications.
# Set DEVELOPER_DIR if `xcode-select -p` points at the Command Line Tools, e.g.
#   DEVELOPER_DIR=~/Downloads/Xcode.app/Contents/Developer scripts/run.sh
# -skipPackagePluginValidation: mlx-swift (pinned to an exact version) ships a build-tool
# plugin; Xcode's GUI asks to "Trust & Enable" it, the command line needs this flag.
set -euo pipefail

cd "$(dirname "$0")/.."

args=(-project HeyVedu.xcodeproj -scheme HeyVedu -configuration Debug -skipPackagePluginValidation)
xcodebuild "${args[@]}" build | tail -n 5

products="$(xcodebuild "${args[@]}" -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR = / {print $2; exit}')"
APP="$products/HeyVedu Dev.app"
pkill -x "HeyVedu Dev" 2>/dev/null || true
open "$APP"
echo "Launched $APP"
