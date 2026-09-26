#!/usr/bin/env bash
# Build LocalDictation (Debug) and launch it.
# Set DEVELOPER_DIR if `xcode-select -p` points at the Command Line Tools, e.g.
#   DEVELOPER_DIR=~/Downloads/Xcode.app/Contents/Developer scripts/run.sh
# -skipPackagePluginValidation: mlx-swift (pinned to an exact version) ships a build-tool
# plugin; Xcode's GUI asks to "Trust & Enable" it, the command line needs this flag.
set -euo pipefail

cd "$(dirname "$0")/.."

xcodebuild \
  -project LocalDictation.xcodeproj \
  -scheme LocalDictation \
  -configuration Debug \
  -derivedDataPath build \
  -skipPackagePluginValidation \
  build | tail -n 5

APP="build/Build/Products/Debug/LocalDictation.app"
pkill -x LocalDictation 2>/dev/null || true
open "$APP"
echo "Launched $APP"
