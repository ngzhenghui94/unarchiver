import CLibArchive
import Darwin
import Foundation

enum CompressionError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

enum Compressor {
    private struct Entry {
        let url: URL
        let name: String
        let info: stat
    }

    static func compress(
        _ sources: [URL], to output: URL, password: String?,
        progress: @escaping (Double) -> Void
    ) throws -> URL {
        let fm = FileManager.default
        guard !sources.isEmpty, sources.allSatisfy(\.isFileURL), output.isFileURL else {
            throw CompressionError.failed("Choose local files or folders to compress.")
        }
        guard password?.contains("\0") != true else {
            throw CompressionError.failed("The password cannot contain a null character.")
        }
        let destination = output.standardizedFileURL.resolvingSymlinksInPath()
        var entries: [Entry] = []
        var names = Set<String>()
        func collect(_ url: URL, name: String) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                throw CompressionError.failed("Cannot read “\(url.lastPathComponent)”: \(String(cString: strerror(errno)))")
            }
            let type = info.st_mode & S_IFMT
            guard type == S_IFREG || type == S_IFDIR || type == S_IFLNK else {
                throw CompressionError.failed("Unsupported file type: “\(name)”.")
            }
            entries.append(Entry(url: url, name: name, info: info))
            if type == S_IFDIR {
                for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    try collect(child, name: name + "/" + child.lastPathComponent)
                }
            }
        }
        for source in sources {
            let url = source.standardizedFileURL
            let name = url.lastPathComponent
            guard !name.isEmpty, name != "/", names.insert(name).inserted else {
                throw CompressionError.failed("Selected items must have distinct names.")
            }
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                throw CompressionError.failed("Cannot read “\(name)”.")
            }
            let resolved = url.resolvingSymlinksInPath()
            guard destination != resolved,
                  (info.st_mode & S_IFMT != S_IFDIR || !destination.path.hasPrefix(resolved.path + "/")) else {
                throw CompressionError.failed("Save the ZIP outside the selected files and folders.")
            }
            try collect(url, name: name)
        }
        let staging = output.deletingLastPathComponent().appendingPathComponent(".compressing-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let staged = staging.appendingPathComponent("archive.zip")
        guard let writer = archive_write_new() else { throw CompressionError.failed("Cannot allocate ZIP writer.") }
        defer { archive_write_free(writer) }
        func check(_ status: Int32) throws {
            guard status == CLIB_ARCHIVE_OK else {
                let message = archive_error_string(writer).map { String(cString: $0) } ?? "ZIP creation failed."
                throw CompressionError.failed(message)
            }
        }
        try check(archive_write_set_format_zip(writer))
        if let password, !password.isEmpty {
            try check(archive_write_set_option(writer, "zip", "encryption", "aes256"))
            try check(archive_write_set_passphrase(writer, password))
        }
        try check(archive_write_open_filename(writer, staged.path))
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 128 * 1024, alignment: 16)
        defer { buffer.deallocate() }
        progress(0)
        for (index, item) in entries.enumerated() {
            guard let entry = archive_entry_new() else { throw CompressionError.failed("Cannot allocate ZIP entry.") }
            defer { archive_entry_free(entry) }
            let type = item.info.st_mode & S_IFMT
            archive_entry_set_pathname(entry, item.name)
            archive_entry_set_filetype(entry, type)
            archive_entry_set_perm(entry, item.info.st_mode & 0o777)
            archive_entry_set_mtime(entry, item.info.st_mtimespec.tv_sec, item.info.st_mtimespec.tv_nsec)
            archive_entry_set_size(entry, type == S_IFREG ? item.info.st_size : 0)
            if type == S_IFLNK {
                archive_entry_set_symlink(entry, try fm.destinationOfSymbolicLink(atPath: item.url.path))
            }
            var fd: Int32 = -1
            if type == S_IFREG {
                fd = Darwin.open(item.url.path, O_RDONLY | O_NOFOLLOW)
                var current = stat()
                guard fd >= 0 else { throw CompressionError.failed("Cannot open “\(item.name)”.") }
                guard fstat(fd, &current) == 0, current.st_ino == item.info.st_ino,
                      current.st_dev == item.info.st_dev, current.st_size == item.info.st_size else {
                    Darwin.close(fd)
                    throw CompressionError.failed("“\(item.name)” changed during compression. Try again.")
                }
            }
            defer { if fd >= 0 { Darwin.close(fd) } }
            try check(archive_write_header(writer, entry))
            if fd >= 0 {
                var remaining = item.info.st_size
                while remaining > 0 {
                    let count = Darwin.read(fd, buffer, min(128 * 1024, Int(remaining)))
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw CompressionError.failed("Cannot finish reading “\(item.name)”.") }
                    var offset = 0
                    while offset < count {
                        let written = archive_write_data(writer, buffer.advanced(by: offset), count - offset)
                        guard written > 0 else { throw CompressionError.failed(archive_error_string(writer).map { String(cString: $0) } ?? "Cannot write ZIP data.") }
                        offset += Int(written)
                    }
                    remaining -= Int64(count)
                }
            }
            try check(archive_write_finish_entry(writer))
            progress(Double(index + 1) / Double(entries.count + 1))
        }
        try check(archive_write_close(writer))
        // Hard-link publication is atomic and never replaces an existing file or symlink.
        var candidate = output
        var suffix = 2
        while Darwin.link(staged.path, candidate.path) != 0 {
            guard errno == EEXIST else { throw CompressionError.failed("Cannot save ZIP: \(String(cString: strerror(errno)))") }
            candidate = output.deletingLastPathComponent().appendingPathComponent("\(output.deletingPathExtension().lastPathComponent) \(suffix).zip")
            suffix += 1
        }
        progress(1)
        return candidate
    }
}
