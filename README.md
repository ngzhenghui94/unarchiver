# Archiver

A small native macOS app for extracting archives and creating ZIP files, in the spirit of [The Unarchiver](https://theunarchiver.com/). Use **Extract** to unpack archives or **Compress** to turn files and folders into a ZIP.

Built with SwiftUI on top of [XADMaster](https://github.com/MacPaw/XADMaster), the same extraction engine The Unarchiver uses. Extraction runs inside the app, not through a command-line tool.

## Features

- **Drag-and-drop compression:** select **Compress**, then drop files or folders onto the window (or use **Choose Files…** / ⌘K). All selected items go into one ZIP. Choose a save location, then enter and confirm an optional password; leave both fields blank for a regular ZIP. Original files are never removed, and existing output names get a numbered suffix. Save outside the selected folders. Selected top-level items must have distinct names.
- **AES-256 ZIP creation:** encrypted ZIP contents require the password, but filenames remain visible. Use this app or another AES-capable reader such as 7-Zip; not every built-in ZIP utility supports AES. Passwords stay in memory for the operation and are not saved to preferences or passed on a command line. Compression uses macOS’s built-in libarchive, with no extra tool installation.

- **Many formats:** zip, 7z, rar, tar, tar.gz/tgz, tar.bz2/tbz, tar.xz/txz, gz, bz2, xz, lzma, iso, cab, lha/lzh, xar, cpio, deb, rpm, and comic-book archives (cbz, cbr, cb7).
- **Several ways to open:** drag onto the window or the Dock icon, double-click or use "Open With" in Finder, or press ⌘O.
- **Tidy output:**
  - An archive with a single top-level item puts that item next to the archive.
  - An archive with several items gets its own folder named after the archive.
  - Name clashes become `name 2`, `name 3`, and so on.
- **Password-protected archives:** you're asked for the password and asked again if it's wrong. This covers encrypted zip (ZipCrypto and AES), RAR4 and RAR5 (including encrypted file names), and 7z (including encrypted file names). The password stays in memory and is never passed on a command line.
- **Multi-part archives:** open the first part (`name.part1.rar`, or `name.rar` for a `.r00`/`.r01` set) and the other parts are found automatically.
- **File-name encodings:** legacy encodings in old zips (such as Shift-JIS or CP437) are detected automatically.
- **Progress bar** for each archive.
- **Damaged archives:** every file that can be recovered is kept, and the job is flagged "Extracted with N problem(s)" with details for each failed file.
- **Gatekeeper-safe:** the quarantine flag on a downloaded archive is copied to everything extracted from it, as Apple's Archive Utility does.
- **One job at a time:** extraction and compression share a queue. Quitting during an operation waits for it and queued jobs to finish instead of leaving half-written files behind.
- **Settings (⌘,):**
  - Choose where to extract: next to the archive, a folder you pick each time, or a fixed folder.
  - Optionally show the results in Finder.
  - Optionally extract archives found inside archives, recursively (up to 8 levels). Zip-based documents such as `.docx` or `.jar` are left alone, and an inner archive is deleted only after it extracts cleanly.
  - Optionally move the archive to the Trash afterwards.

## Requirements

- Apple Silicon Mac running macOS 14 (Sonoma) or later
- To build from source: Xcode (not just the Command Line Tools), since XADMaster is built with `xcodebuild`

## Build and install

Run `./build.sh` from the maintained checkout. Every normal build automatically chooses a new numeric version and increasing build number, builds the app with Sparkle 2.10.0, signs with the existing Developer ID Application certificate for team `F57QJC4XU3`, submits using Keychain profile `notary`, staples and validates Apple's ticket, checks code signatures and Gatekeeper, then publishes a new immutable GitHub release. Xcode, Python 3, authenticated GitHub CLI push access, and the existing organization Sparkle signing key (Keychain account `local.swissKnife`) are required. No signing keys are exported or Keychain permissions changed.

The final notarized app remains `build/Archiver.app`; immutable apps and packages are retained in `build/releases/VERSION/`. The normal build runs the updater safety and numeric release self-tests. Installed copies are never replaced by the build. Quit the installed app, then copy the final app to Applications when you intend to install it; do not disable Gatekeeper or remove quarantine.

### In-app updates

Choose **Archiver → Check for Updates…**. Checks and downloads are manual only; no system profile is sent. Both the feed and ZIP use verified Ed25519 signatures, verification happens before extraction, and the replacement app must retain the bundle identity `local.unarchiver` and publisher's Developer ID identity. Updates reject checks during file work, block new extraction/compression while installation is pending, and wait for queued work to drain before relaunch. Canceling or failing an update releases its own installation guard. An older build without Sparkle must first be replaced manually with a notarized release.

## Homebrew

Install from the public `ngzhenghui94/tap` Homebrew tap:

```sh
brew tap ngzhenghui94/tap
brew install --cask ngzhenghui94/tap/archiver
```

The repository is named `unarchiver`, but the app is **Archiver**. Do not use the unrelated Homebrew `archiver` or `the-unarchiver` casks. Download releases at https://github.com/ngzhenghui94/unarchiver/releases.

### Install a local build with Homebrew

From this checkout, after `./build.sh`, use the following **instead of** manually copying the app into `/Applications`:

```sh
./package.sh --local
brew tap-new --no-git local/archiver # Once per machine
mkdir -p "$(brew --repository)/Library/Taps/local/homebrew-archiver/Casks"
cp build/homebrew/local/Casks/archiver.rb \
  "$(brew --repository)/Library/Taps/local/homebrew-archiver/Casks/archiver.rb"
brew install --cask local/archiver/archiver
```

This installs `/Applications/Archiver.app`. The generated cask contains the actual ZIP SHA-256 and an absolute, escaped `file://` URL; keep the checkout and ZIP in place for reinstalling. It supports Apple Silicon and macOS Sonoma or later. `brew tap-new` may enable Homebrew developer mode; if it was previously off, restore it with `brew developer off`.

For a rebuilt app, run `./package.sh --local`, copy the cask into the tap again, then use `brew reinstall --cask local/archiver/archiver`. To uninstall, use `brew uninstall --cask local/archiver/archiver`; preferences are retained. A pre-existing manually installed app must be moved aside first, or use Homebrew's `--adopt` option only if it is identical to the packaged app.

`./package.sh` defaults to `--local`. For the shared local tap containing all five apps, see `../homebrew-tap/README.md`; the single-app workflow above remains independent.

### Publish a release

Normal `./build.sh` now performs publication end to end. The release destination stays `ngzhenghui94/unarchiver` at tag `vVERSION`, containing `Archiver-VERSION-arm64.zip`, a signed `appcast.xml`, and `Archiver-VERSION-archive-sources.tar.gz`. Only vendored LGPL archive dependency sources and rebuild instructions accompany the binary; authored app source is not included in release assets or copied to the Homebrew tap. Existing releases, including v1.0, are never overwritten.

Publication uploads a draft, downloads and checks every asset's SHA-256, publishes it, verifies HTTPS public downloads, then commits the cask and signed feed to `ngzhenghui94/homebrew-tap`. The app-local `build/update-tap` clone is fetched/rebased before a normal push; the shared sibling tap is never edited. The live feed is `https://raw.githubusercontent.com/ngzhenghui94/homebrew-tap/main/appcasts/archiver.xml`.

`./package.sh --local` packages the final app without publishing; `./package.sh --release` requires a stapled notarized app, signs its update archive/feed, and refuses to overwrite its immutable `build/releases/VERSION/package` directory. The normal release already performs that step.

On failure, preserve `build/releases` and `build/update-tap`. Inspect `notarization.json`, any Apple submission and GitHub draft, and any unpushed tap commit before retrying. Never blindly resubmit an unknown Apple result, overwrite assets, or remove a build lock without checking whether its process is still running. An interrupted attempt may reserve a version; the next build advances past it.

After publishing future versions, consumers can run:

```sh
brew tap ngzhenghui94/tap
brew install --cask ngzhenghui94/tap/archiver
```

Later, use `brew upgrade --cask ngzhenghui94/tap/archiver` or `brew uninstall --cask ngzhenghui94/tap/archiver`. Upgrades become available when a newer release asset and matching tap cask are published.

## Project layout

| Path | Purpose |
| --- | --- |
| `Sources/Unarchiver/App.swift` | App entry point, window, job queue, password prompt, settings |
| `Sources/Unarchiver/Extractor.swift` | Extraction via XADMaster's `XADSimpleUnarchiver`: output placement, passwords, progress, encoding detection, per-file errors, quarantine |
| `Sources/Unarchiver/Compressor.swift` | Streaming ZIP creation, AES-256 encryption, staging, and collision-safe output |
| `Sources/CLibArchive` | Minimal C declarations for the macOS system libarchive writer |
| `Resources/Info.plist` | Bundle metadata and the file types the app can open |
| `Vendor/XADMaster`, `Vendor/UniversalDetector` | Git submodules for the extraction engine and encoding detector |
| `build.sh` | Builds `build/Archiver.app` |
| `package.sh` | Packages the built app and generates a checksummed local or release Homebrew cask |

## Known limitations

- **Compression:** creates ZIP only. Window drops follow the selected mode; Finder/Dock archive opens still extract. ZIP creation keeps file contents, directory structure, symlinks, permissions, and modification times, but does not preserve macOS extended attributes or resource forks.

- **Progress:** the bar tracks the archive as a whole; there's no per-file progress and no Cancel button.
- **Encrypted, damaged archives:** with some encrypted formats (such as 7z with encrypted file names), a damaged archive can look the same as a wrong password, so you may be asked for the password again.

## License

XADMaster and UniversalDetector are licensed under the LGPL 2.1 and are linked as separate dynamic frameworks inside the app bundle. XADMaster has local source fixes for current macOS APIs and decoder warnings; preserve those changes when updating its submodule.
