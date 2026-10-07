#!/bin/sh
# Package an existing build; never installs or publishes anything.
set -eu
cd "$(dirname "$0")"

MODE=${1:---local}
case "$MODE" in
    --local|--release) ;;
    *) echo "Usage: $0 [--local|--release]" >&2; exit 1 ;;
esac
if [ "$#" -gt 1 ]; then
    echo "Usage: $0 [--local|--release]" >&2
    exit 1
fi

APP="$PWD/build/Archiver.app"
if [ ! -x "$APP/Contents/MacOS/Archiver" ]; then
    echo "Build Archiver first with ./build.sh" >&2
    exit 1
fi
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
case "$VERSION" in
    ''|*[!0-9.]*|.*|*.|*..*) echo "Expected a numeric dotted app version, got: $VERSION" >&2; exit 1 ;;
esac

OUT="$PWD/build/homebrew/${MODE#--}"
mkdir -p "$OUT/Casks"
ARCHIVE="$OUT/Archiver-$VERSION-arm64.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"

# Ruby is included with macOS. Its string and URI escaping keeps spaces and
# other special characters in checkout paths safe in the generated cask.
/usr/bin/ruby - "$MODE" "$VERSION" "$ARCHIVE" "$OUT/Casks/archiver.rb" <<'RUBY'
require "digest"
require "uri"

mode, version, archive, cask = ARGV
url = if mode == "--local"
  "file://#{URI::DEFAULT_PARSER.escape(archive, /[^a-zA-Z0-9\/._~-]/)}"
else
  "https://github.com/ngzhenghui94/unarchiver/releases/download/v#{version}/Archiver-#{version}-arm64.zip"
end
File.write(cask, <<~CASK)
  cask "archiver" do
    version #{version.dump}
    sha256 #{Digest::SHA256.file(archive).hexdigest.dump}

    url #{url.dump}
    name "Archiver"
    desc "Native archive extraction and ZIP creation"
    homepage "https://github.com/ngzhenghui94/unarchiver"

    depends_on arch: :arm64
    depends_on macos: :sonoma

    app "Archiver.app"
  end
CASK
RUBY

printf 'Archive: %s\nCask: %s\n' "$ARCHIVE" "$OUT/Casks/archiver.rb"
if [ "$MODE" = --release ]; then
    printf 'Publication required: upload this exact ZIP to release v%s, then publish the cask in a Homebrew tap.\n' "$VERSION"
fi
