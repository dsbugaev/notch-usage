#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="build/NotchUsage.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -parse-as-library src/main.swift -o "$APP/Contents/MacOS/NotchUsage"
codesign --force -s - "$APP" 2>/dev/null
echo "OK: $APP"
