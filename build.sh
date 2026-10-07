#!/bin/sh
# Builds build/Archiver.app (release, ad-hoc signed).
set -e
cd "$(dirname "$0")"

if [ ! -f Vendor/XADMaster/XADMaster.xcodeproj/project.pbxproj ] ||
   [ ! -f Vendor/UniversalDetector/UniversalDetector.xcodeproj/project.pbxproj ]; then
    git submodule update --init
fi

DEPS_DIR="$PWD/build/deps"
mkdir -p "$DEPS_DIR"

# An absolute product path keeps Xcode from writing build output into Vendor/.
xcodebuild -quiet \
    -project Vendor/XADMaster/XADMaster.xcodeproj \
    -scheme XADMaster \
    -configuration Release \
    -sdk macosx \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DEPS_DIR/DerivedData" \
    CONFIGURATION_BUILD_DIR="$DEPS_DIR" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    MACOSX_DEPLOYMENT_TARGET=14.0 \
    CODE_SIGNING_ALLOWED=NO \
    build

XADMASTER_FRAMEWORK="$DEPS_DIR/XADMaster.framework"
UNIVERSALDETECTOR_FRAMEWORK="$DEPS_DIR/UniversalDetector.framework"
MODULE_MAP="$XADMASTER_FRAMEWORK/Modules/module.modulemap"

# Xcode normally generates this from the framework umbrella header.
if [ ! -f "$MODULE_MAP" ]; then
    mkdir -p "$(dirname "$MODULE_MAP")"
    cat > "$MODULE_MAP" <<'EOF'
framework module XADMaster {
    umbrella header "XADMaster.h"
    export *
    module * { export * }
}
EOF
fi

for header in XADSimpleUnarchiver.h XADArchiveParser.h XADString.h XADPath.h XADException.h; do
    if [ ! -f "$XADMASTER_FRAMEWORK/Headers/$header" ]; then
        echo "XADMaster.framework is missing $header" >&2
        exit 1
    fi
done
if [ ! -d "$UNIVERSALDETECTOR_FRAMEWORK" ]; then
    echo "XADMaster build did not produce UniversalDetector.framework" >&2
    exit 1
fi

APP=build/Archiver.app
swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Archiver" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
ditto "$UNIVERSALDETECTOR_FRAMEWORK" "$APP/Contents/Frameworks/UniversalDetector.framework"
ditto "$XADMASTER_FRAMEWORK" "$APP/Contents/Frameworks/XADMaster.framework"
# Sign the dependency before its parent framework, then the app bundle.
codesign --force --sign - "$APP/Contents/Frameworks/UniversalDetector.framework"
codesign --force --sign - "$APP/Contents/Frameworks/XADMaster.framework"
codesign --force --sign - "$APP"
echo "Built $APP"
