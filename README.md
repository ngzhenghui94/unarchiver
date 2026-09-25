# Unarchiver

A small native macOS app for extracting archives, in the spirit of [The Unarchiver](https://theunarchiver.com/). Drop an archive on it and the files show up next to the archive.

Built with SwiftUI on top of [XADMaster](https://github.com/MacPaw/XADMaster), the same extraction engine The Unarchiver uses. Extraction runs inside the app, not through a command-line tool.

## Features

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
- **One job at a time:** archives are queued and extracted in order. Quitting during an extraction waits for it to finish instead of leaving half-written files behind.
- **Settings (⌘,):**
  - Choose where to extract: next to the archive, a folder you pick each time, or a fixed folder.
  - Optionally show the results in Finder.
  - Optionally extract archives found inside archives, recursively (up to 8 levels). Zip-based documents such as `.docx` or `.jar` are left alone, and an inner archive is deleted only after it extracts cleanly.
  - Optionally move the archive to the Trash afterwards.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode (not just the Command Line Tools), since XADMaster is built with `xcodebuild`

## Build and install

```sh
git clone --recursive https://github.com/ngzhenghui94/unarchiver.git
cd unarchiver
./build.sh
cp -R build/Unarchiver.app /Applications/
```

`build.sh` does the following:

1. Fetches the `Vendor/` submodules if they're missing.
2. Builds `XADMaster.framework` (with UniversalDetector) into `build/deps/`.
3. Builds the Swift app and embeds both frameworks.
4. Signs everything ad hoc so it can run on your Mac.

The app isn't notarized. If you copy it to another Mac, Gatekeeper will block it until you right-click it and choose **Open**.

## Project layout

| Path | Purpose |
| --- | --- |
| `Sources/Unarchiver/App.swift` | App entry point, window, job queue, password prompt, settings |
| `Sources/Unarchiver/Extractor.swift` | Extraction via XADMaster's `XADSimpleUnarchiver`: output placement, passwords, progress, encoding detection, per-file errors, quarantine |
| `Resources/Info.plist` | Bundle metadata and the file types the app can open |
| `Vendor/XADMaster`, `Vendor/UniversalDetector` | Git submodules for the extraction engine and encoding detector |
| `build.sh` | Builds `build/Unarchiver.app` |

## Known limitations

- **Progress:** the bar tracks the archive as a whole; there's no per-file progress and no Cancel button.
- **Encrypted, damaged archives:** with some encrypted formats (such as 7z with encrypted file names), a damaged archive can look the same as a wrong password, so you may be asked for the password again.

## License

XADMaster and UniversalDetector are licensed under the LGPL 2.1. They're included unmodified as git submodules and are linked as separate dynamic frameworks inside the app bundle.
