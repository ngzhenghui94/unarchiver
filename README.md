# Unarchiver

A small native macOS app for extracting archives, in the spirit of [The Unarchiver](https://theunarchiver.com/). Drop an archive on it and the files show up next to the archive.

Built with SwiftUI. Extraction is handled by macOS's built-in `bsdtar` (libarchive), so there are no third-party dependencies.

## Features

- **Many formats:** zip, 7z, rar, tar, tar.gz/tgz, tar.bz2/tbz, tar.xz/txz, gz, bz2, xz, lzma, iso, cab, lha/lzh, xar, cpio, deb, rpm, and comic-book archives (cbz, cbr, cb7).
- **Several ways to open:** drag onto the window or the Dock icon, double-click or use "Open With" in Finder, or press ⌘O.
- **Tidy output:**
  - An archive with a single top-level item puts that item next to the archive.
  - An archive with several items gets its own folder named after the archive.
  - Name clashes become `name 2`, `name 3`, and so on.
- **Password-protected archives:** you're asked for the password and asked again if it's wrong. Supports ZipCrypto and AES zip.
- **Gatekeeper-safe:** the quarantine flag on a downloaded archive is copied to everything extracted from it, as Apple's Archive Utility does.
- **One job at a time:** archives are queued and extracted in order. Quitting during an extraction waits for it to finish instead of leaving half-written files behind.
- **Settings (⌘,):**
  - Choose where to extract: next to the archive, a folder you pick each time, or a fixed folder.
  - Optionally show the results in Finder.
  - Optionally extract archives found inside archives, recursively (up to 8 levels). Zip-based documents such as `.docx` or `.jar` are left alone, and an inner archive is deleted only after it extracts cleanly.
  - Optionally move the archive to the Trash afterwards.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode or the Xcode Command Line Tools (Swift 5.9+) to build

## Build and install

```sh
git clone https://github.com/ngzhenghui94/unarchiver.git
cd unarchiver
./build.sh
cp -R build/Unarchiver.app /Applications/
```

`build.sh` builds a release binary, puts it in an app bundle, and signs it ad hoc so it can run on your Mac. The app isn't notarized. If you copy it to another Mac, Gatekeeper will block it until you right-click it and choose **Open**.

## Project layout

| Path | Purpose |
| --- | --- |
| `Sources/Unarchiver/App.swift` | App entry point, window, job queue, password prompt, settings |
| `Sources/Unarchiver/Extractor.swift` | Extraction: runs `bsdtar`, decodes single compressed files, places the output, copies the quarantine flag |
| `Resources/Info.plist` | Bundle metadata and the file types the app can open |
| `build.sh` | Builds `build/Unarchiver.app` |

## Known limitations

- **RAR:** RAR5 support in libarchive is incomplete, and encrypted RAR and split multi-part RAR archives aren't supported.
- **7z:** archives whose file names are encrypted can't be opened.
- **Damaged archives:** if any file inside is damaged, nothing is kept.
- **Progress:** each archive shows a spinner, not a progress bar.
- **Passwords:** the password is passed to `bsdtar` on its command line, so other processes on the same Mac can briefly see it while extraction runs.
- **File-name encodings:** legacy encodings in old zips (such as Shift-JIS) aren't auto-detected.
