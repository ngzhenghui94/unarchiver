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

```sh
git clone --recursive https://github.com/ngzhenghui94/unarchiver.git
cd unarchiver
./build.sh
cp -R build/Archiver.app /Applications/
```

To reproduce the v1.0 release, download `XADMaster-local-changes.patch` from the release and apply it from `Vendor/XADMaster` with `git apply /path/to/XADMaster-local-changes.patch` before running `./build.sh`. The release includes both dependency source archives and their licenses.

`build.sh` does the following:

1. Fetches the `Vendor/` submodules if they're missing.
2. Builds `XADMaster.framework` (with UniversalDetector) into `build/deps/`.
3. Builds the Swift app and embeds both frameworks.
4. Signs everything ad hoc so it can run on your Mac.

The app is ad-hoc signed, not notarized. On another Mac, Gatekeeper may require approval in **System Settings → Privacy & Security → Open Anyway** after attempting to open it. Only approve a build whose source you trust. Packaging does not disable quarantine or Gatekeeper.

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

### Prepare a public release

Set the intended version in `Resources/Info.plist`, build (and, for trusted public distribution, Developer ID sign, notarize, and staple the app), then run:

```sh
./package.sh --release
mkdir -p ../homebrew-tap/Casks
cp build/homebrew/release/Casks/archiver.rb ../homebrew-tap/Casks/archiver.rb
```

This creates `build/homebrew/release/Archiver-VERSION-arm64.zip` and `build/homebrew/release/Casks/archiver.rb`, deriving `VERSION` from the built app and computing the ZIP's real SHA-256. The cask targets this repository's GitHub release asset at tag `vVERSION`. Local and release outputs are separate; neither command publishes anything or installs the app.

The copy command stages the release definition in the sibling tap checkout; it does not publish it. The exact release URL is `https://github.com/ngzhenghui94/unarchiver/releases/download/vVERSION/Archiver-VERSION-arm64.zip`.

After publication is authorized, upload that exact ZIP to the matching GitHub release and commit the generated release cask into the `Casks/` directory of `ngzhenghui94/homebrew-tap`. Publish the source and corresponding dependency modifications as required by their licenses. Do not publish the local cask, change the ZIP after generating its checksum, or advertise public installation before the release asset and tap actually exist.

After publishing future versions, consumers can run:

```sh
brew tap ngzhenghui94/tap
brew install --cask ngzhenghui94/tap/archiver
```

Later, use `brew upgrade --cask ngzhenghui94/tap/archiver` or `brew uninstall --cask ngzhenghui94/tap/archiver`. These public commands are not usable yet.

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
