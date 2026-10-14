#!/bin/sh
# Package an existing build; release mode signs updates, never installs, notarizes, or publishes.
set -eu
cd "$(dirname "$0")"
MODE=${1:---local}
case "$MODE" in
    --local) APP="$PWD/build/Archiver.app" ;;
    --release) APP="$PWD/build/Archiver.app" ;;
    *) echo "Usage: $0 [--local|--release]" >&2; exit 1 ;;
esac
[ "$#" -le 1 ] || { echo "Usage: $0 [--local|--release]" >&2; exit 1; }
BINARY="$APP/Contents/MacOS/Archiver"
[ -x "$BINARY" ] || { echo "Missing app executable: $BINARY" >&2; exit 1; }
PLIST="$APP/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
case "$VERSION" in
    ''|*[!0-9.]*|.*|*.|*..*) echo "Expected a numeric dotted app version, got: $VERSION" >&2; exit 1 ;;
esac
/usr/bin/ruby - "$BINARY" "$PLIST" <<'RUBY'
binary, plist = ARGV
{"CFBundleIdentifier" => "local.unarchiver", "CFBundleExecutable" => "Archiver",
 "CFBundleName" => "Archiver", "CFBundlePackageType" => "APPL"}.each do |key, expected|
  value = IO.popen(["/usr/libexec/PlistBuddy", "-c", "Print :#{key}", plist], &:read)
  abort "Expected #{key}=#{expected}" unless $?.success? && value.strip == expected
end
arches = IO.popen(["/usr/bin/lipo", "-archs", binary], &:read)
abort "Expected an arm64-only executable" unless $?.success? && arches.strip == "arm64"
commands = IO.popen(["/usr/bin/otool", "-l", binary], &:read)
abort "Cannot read executable deployment target" unless $?.success?
build = commands.split(/Load command \d+/).find { |command| command.match?(/\bcmd LC_BUILD_VERSION\b/) }
unless build && build.match?(/\bplatform (?:1|MACOS)\s*$/) && build.match?(/\bminos 14\.0(?:\.0)?\s*$/)
  abort "Expected macOS 14.0 executable deployment target"
end
minimum = IO.popen(["/usr/libexec/PlistBuddy", "-c", "Print :LSMinimumSystemVersion", plist], &:read)
abort "Expected bundle minimum macOS 14.0" unless $?.success? && minimum.strip.match?(/\A14\.0(?:\.0)?\z/)
RUBY
/usr/bin/codesign --verify --deep --strict "$APP"
if [ "$MODE" = --release ]; then
    /usr/sbin/spctl --assess --type execute --verbose=2 "$APP"
    /usr/bin/xcrun stapler validate "$APP"
fi
OUT="$PWD/build/homebrew/${MODE#--}"
if [ "$MODE" = --release ]; then
    OUT="$PWD/build/releases/$VERSION/package"
    [ ! -e "$OUT" ] || { echo "Refusing to overwrite release package: $OUT" >&2; exit 1; }
fi
mkdir -p "$OUT/Casks"
ARCHIVE="$OUT/Archiver-$VERSION-arm64.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
/usr/bin/ruby - "$MODE" "$VERSION" "$ARCHIVE" "$OUT/Casks/archiver.rb" <<'RUBY'
require "digest"
require "uri"
mode, version, archive, cask = ARGV
url_literal = if mode == "--local"
  "file://#{URI::DEFAULT_PARSER.escape(archive, /[^a-zA-Z0-9\/._~-]/)}".dump
else
  '"https://github.com/ngzhenghui94/unarchiver/releases/download/v#{version}/Archiver-#{version}-arm64.zip"'
end
File.write(cask, <<~CASK)
  cask "archiver" do
    version #{version.dump}
    sha256 #{Digest::SHA256.file(archive).hexdigest.dump}

    url #{url_literal}
    name "Archiver"
    desc "Native archive extraction and ZIP creation"
    homepage "https://github.com/ngzhenghui94/unarchiver"

    depends_on arch: :arm64
    depends_on macos: :sonoma

    app "Archiver.app"
  end
CASK
RUBY
if [ "$MODE" = --release ]; then
    # Copy only vendored dependency trees, never authored app source or checkout metadata.
    /usr/bin/ruby - "$PWD/Vendor" "$OUT" "$VERSION" <<'RUBY'
require "find"
require "fileutils"
require "tmpdir"
vendor, out, version = ARGV
Dir.mktmpdir("archive-sources-", out) do |stage|
  root = File.join(stage, "Archiver-#{version}-archive-sources")
  %w[XADMaster UniversalDetector].each do |dependency|
    source = File.join(vendor, dependency)
    abort "Missing dependency license: #{dependency}" unless File.file?(File.join(source, "LICENSE"))
    Find.find(source) do |path|
      relative = path.delete_prefix(source)
      name = File.basename(path)
      if name.match?(/\A(?:\.git|\.github|\.DS_Store|\.build|build|Build|DerivedData|xcuserdata|__pycache__)\z/) ||
          name.match?(/\.(?:o|a|dylib|so|pyc|app|framework|zip|tar|gz|xcuserstate)\z/)
        File.directory?(path) ? Find.prune : next
      end
      abort "Refusing dependency symlink: #{path}" if File.symlink?(path)
      destination = File.join(root, "Vendor", dependency) + relative
      if File.directory?(path)
        FileUtils.mkdir_p(destination)
      elsif File.file?(path)
        FileUtils.copy_file(path, destination)
      else
        abort "Refusing special dependency file: #{path}"
      end
    end
  end
  File.write(File.join(root, "SOURCE-NOTICES.txt"), <<~NOTICE)
    These are the complete vendored archive dependency sources used by Archiver #{version},
    including retained local XADMaster fixes. No authored Archiver app source is included.
    XADMaster derives from https://github.com/MacPaw/XADMaster
    UniversalDetector derives from https://github.com/MacPaw/universal-detector
    Each library includes its LGPL 2.1 LICENSE. Preserve individual source notices,
    including alternate licenses and third-party copyright notices.
    Both frameworks are dynamically linked. Recipients may modify and rebuild these
    libraries, replace the frameworks in their own app copy, and re-sign that copy
    locally. Replacement invalidates the distributor's signature and notarization.
    This source archive must accompany the matching binary release.
  NOTICE
  File.write(File.join(root, "BUILD-INSTRUCTIONS.txt"), <<~BUILD)
    Requires full Xcode and its macOS SDK. From this archive's root directory:

    xcodebuild -quiet -project Vendor/XADMaster/XADMaster.xcodeproj \\
      -scheme XADMaster -configuration Release -sdk macosx \\
      -destination 'generic/platform=macOS' \\
      -derivedDataPath "$PWD/build/DerivedData" \\
      CONFIGURATION_BUILD_DIR="$PWD/build" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \\
      MACOSX_DEPLOYMENT_TARGET=14.0 CODE_SIGNING_ALLOWED=NO build

    This builds XADMaster.framework and UniversalDetector.framework in build/.
    Copy replacement frameworks into your own Archiver.app/Contents/Frameworks/.
    Re-sign modified frameworks and the app locally before use; do not disable
    Gatekeeper. Original release signatures do not cover modified frameworks.
  BUILD
  archive = File.join(out, "Archiver-#{version}-archive-sources.tar.gz")
  abort "Dependency source archiving failed" unless system({"COPYFILE_DISABLE" => "1"},
    "/usr/bin/tar", "-czf", archive, "-C", stage, File.basename(root))
  puts "Dependency sources: #{archive}"
end
RUBY
fi
if [ "$MODE" = --release ]; then
    /usr/bin/ruby - "$PLIST" "$VERSION" "$ARCHIVE" "$OUT" "$PWD/.build/artifacts/sparkle/Sparkle/bin/sign_update" "$PWD/signing.swift" <<'RUBY'
require "open3"
require "tempfile"
plist, version, archive, out, signer, helper = ARGV
abort "Missing Sparkle signer or noninteractive helper" unless File.executable?(signer) && File.file?(helper)
public_key, key_status = Open3.capture2("/usr/libexec/PlistBuddy", "-c", "Print :SUPublicEDKey", plist)
abort "Missing public update key" unless key_status.success?
public_key = public_key.strip
build, status = Open3.capture2("/usr/libexec/PlistBuddy", "-c", "Print :CFBundleVersion", plist)
build = build.strip
abort "Invalid app build version" unless status.success? && build.match?(/\A\d+(?:\.\d+)*\z/)
sign = lambda do |label, mode, *arguments|
  command = ["/usr/bin/swift", helper, mode]
  command.concat(mode == "sign" ? [signer, "local.swissKnife", public_key] : [public_key])
  output, _errors, status = Open3.capture3(*command, *arguments)
  abort "#{label} failed: #{_errors.strip}" unless status.success?
  output.strip
end
signature = sign.call("Archive signing", "sign", archive)
abort "Invalid Sparkle EdDSA signature" unless signature.match?(/\A[A-Za-z0-9+\/]{86}==\z/)
sign.call("Archive signature verification", "verify", archive, signature)
length = File.size(archive)
abort "Empty update archive" unless length.positive?
url = "https://github.com/ngzhenghui94/unarchiver/releases/download/v#{version}/Archiver-#{version}-arm64.zip"
Tempfile.create(["appcast-", ".xml"], out) do |feed|
  feed.write(<<~XML)
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <title>Archiver Updates</title>
        <link>https://github.com/ngzhenghui94/homebrew-tap</link>
        <description>Signed Archiver updates for Apple Silicon.</description>
        <item>
          <title>Archiver #{version}</title>
          <sparkle:version>#{build}</sparkle:version>
          <sparkle:shortVersionString>#{version}</sparkle:shortVersionString>
          <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
          <enclosure url="#{url}" length="#{length}" type="application/octet-stream" sparkle:edSignature="#{signature}" />
        </item>
      </channel>
    </rss>
  XML
  feed.flush
  sign.call("Appcast signing", "sign", feed.path)
  sign.call("Appcast signature verification", "verify", feed.path)
  File.rename(feed.path, File.join(out, "appcast.xml"))
end
puts "PASS: update archive and appcast EdDSA signatures verified."
RUBY
fi
printf 'Archive: %s\nCask: %s\n' "$ARCHIVE" "$OUT/Casks/archiver.rb"
if [ "$MODE" = --release ]; then
    printf 'Appcast: %s\n' "$OUT/appcast.xml"
fi
