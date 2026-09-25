import Compression
import Foundation

enum ExtractError: LocalizedError {
    case failed(String)
    case needsPassword
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .failed(let msg): return msg
        case .needsPassword: return "This archive is encrypted and needs a password."
        case .unsupported(let ext): return "Unsupported format: .\(ext)"
        }
    }
}

/// Extracts archives. Multi-file archives go through libarchive (`bsdtar`), which reads
/// zip, 7z, rar, tar(.gz/.bz2/.xz), iso, cab, lha, xar, cpio and more. Bare compressed
/// single files (.gz, .bz2, .xz, .lzma) are not archives, so they are decoded directly.
enum Extractor {
    static let streamExtensions: Set<String> = ["gz", "gzip", "bz2", "bzip2", "xz", "lzma"]

    /// Extracts `archive` into `destinationDir`. Returns the URL of the created item.
    /// If the archive holds exactly one top-level item it is placed directly in the
    /// destination; otherwise everything goes into a folder named after the archive.
    static func extract(_ archive: URL, to destinationDir: URL, password: String?) throws -> URL {
        let fm = FileManager.default
        let ext = archive.pathExtension.lowercased()
        let staging = destinationDir.appendingPathComponent(".unarchiving-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let isTarStream = streamExtensions.contains(ext)
            && archive.deletingPathExtension().pathExtension.lowercased() == "tar"
        if streamExtensions.contains(ext) && !isTarStream {
            let out = staging.appendingPathComponent(archive.deletingPathExtension().lastPathComponent)
            try decompressStream(archive, ext: ext, to: out)
        } else {
            try runBsdtar(archive, into: staging, password: password)
        }

        propagateQuarantine(from: archive, into: staging)
        let items = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
        let base = baseName(of: archive)
        let source: URL
        let name: String
        if items.count == 1 {
            source = items[0]
            name = items[0].lastPathComponent
        } else {
            source = staging
            name = base
        }
        let target = uniqueURL(destinationDir.appendingPathComponent(name))
        if source == staging {
            // Staging becomes the result folder; the deferred cleanup then finds nothing.
            try fm.moveItem(at: staging, to: target)
        } else {
            try fm.moveItem(at: source, to: target)
        }
        return target
    }

    static func baseName(of url: URL) -> String {
        var u = url.deletingPathExtension()
        if u.pathExtension.lowercased() == "tar" { u = u.deletingPathExtension() }
        return u.lastPathComponent
    }

    static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var i = 2
        while true {
            let name = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }

    private static func runBsdtar(_ archive: URL, into dir: URL, password: String?) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        var args = ["-x", "-f", archive.path, "-C", dir.path]
        // Always pass a passphrase so libarchive never tries to prompt. bsdtar rejects an
        // empty one, so use a random placeholder; encrypted entries then fail and we ask.
        args += ["--passphrase", password ?? UUID().uuidString]
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus != 0 else { return }
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map {
                $0.replacingOccurrences(of: "bsdtar: ", with: "")
                    .replacingOccurrences(of: ": Unknown error: -1", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty && !$0.contains("Error exit delayed") }
        let lower = lines.joined(separator: "\n").lowercased()
        // libarchive reports "Passphrase required…" / "Incorrect passphrase" for encryption it
        // can decrypt; encryption it can't handle (RAR, 7z headers) says "unsupported" or
        // "unavailable", and asking for a password there would loop forever.
        let unsupported = ["unsupported", "not supported", "unavailable"].contains { lower.contains($0) }
        if lower.contains("passphrase") && !unsupported {
            throw ExtractError.needsPassword
        }
        // Unknown bytes fall through libarchive's format probes; plain text ends up parsed as
        // an mtree spec, which yields a baffling error.
        if lower.contains("unrecognized archive format") || lower.contains("mtree") {
            throw ExtractError.failed("Not a recognized archive, or the file is damaged.")
        }
        throw ExtractError.failed(lines.isEmpty
            ? "Extraction failed (exit \(p.terminationStatus))."
            : lines.joined(separator: "\n"))
    }

    /// Copies the archive's Gatekeeper quarantine flag onto everything extracted, as Archive
    /// Utility does. Otherwise a downloaded app unpacked here would skip Gatekeeper checks.
    private static func propagateQuarantine(from archive: URL, into root: URL) {
        let name = "com.apple.quarantine"
        let size = getxattr(archive.path, name, nil, 0, 0, 0)
        guard size > 0 else { return }
        var value = [UInt8](repeating: 0, count: size)
        guard getxattr(archive.path, name, &value, size, 0, 0) == size else { return }
        let apply = { (url: URL) in _ = setxattr(url.path, name, value, size, 0, XATTR_NOFOLLOW) }
        guard let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        apply(root)
        for case let url as URL in items { apply(url) }
    }

    private static func decompressStream(_ input: URL, ext: String, to output: URL) throws {
        switch ext {
        case "gz", "gzip": try pipeTool("/usr/bin/gzip", ["-dc", input.path], to: output)
        case "bz2", "bzip2": try pipeTool("/usr/bin/bzip2", ["-dc", input.path], to: output)
        case "xz", "lzma": try decodeLZMA(input, to: output)
        default: throw ExtractError.unsupported(ext)
        }
    }

    private static func pipeTool(_ tool: String, _ args: [String], to output: URL) throws {
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let out = try FileHandle(forWritingTo: output)
        defer { try? out.close() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = out
        let err = Pipe()
        p.standardError = err
        try p.run()
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw ExtractError.failed(String(decoding: data, as: UTF8.self))
        }
    }

    /// Streams an .xz/.lzma file through Apple's Compression framework (COMPRESSION_LZMA = xz).
    private static func decodeLZMA(_ input: URL, to output: URL) throws {
        let inHandle = try FileHandle(forReadingFrom: input)
        defer { try? inHandle.close() }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: output)
        defer { try? outHandle.close() }

        let filter = try OutputFilter(.decompress, using: .lzma) { data in
            if let data { try outHandle.write(contentsOf: data) }
        }
        do {
            while let chunk = try inHandle.read(upToCount: 1 << 20), !chunk.isEmpty {
                try filter.write(chunk)
            }
            try filter.finalize()
        } catch is FilterError {
            throw ExtractError.failed("Corrupt or truncated xz/lzma data.")
        }
    }
}
