#!/bin/sh
# Builds build/Unarchiver.app (release, ad-hoc signed).
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/Unarchiver.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Unarchiver" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "Built $APP"
