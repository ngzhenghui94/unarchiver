import Darwin
import Foundation
import XADMaster

struct ExtractionResult {
    let url: URL
    let failures: [String]
    let volumes: [URL]
}

enum ExtractError: LocalizedError {
    case failed(String)
    case needsPassword(wrong: Bool)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        case .needsPassword: return "This archive is encrypted and needs a password."
        }
    }
}

enum Extractor {
    /// Extracts into a private staging directory. XADMaster handles archive probing,
    /// nested archives, volume discovery, entry sanitization, and filename detection.
    static func extract(
        _ archive: URL,
        to destinationDir: URL,
        password: String?,
        requestPassword: @escaping (Bool) -> String?,
        progress: @escaping (Double) -> Void
    ) throws -> ExtractionResult {
        let fileManager = FileManager.default
        let staging = destinationDir.appendingPathComponent(".unarchiving-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        var openError: Int32 = 0
        guard let unarchiver = XADSimpleUnarchiver(forPath: archive.path, error: &openError) else {
            throw ExtractError.failed("Not a recognized archive, or the file is damaged.")
        }

        let delegate = XADExtractionDelegate(requestPassword: requestPassword, progress: progress, initialPassword: password)
        unarchiver.setDelegate(delegate)
        unarchiver.setDestination(staging.path)
        unarchiver.setEnclosingDirectoryName(baseName(of: archive))
        unarchiver.setRemovesEnclosingDirectoryForSoloItems(true)
        unarchiver.setExtractsSubArchives(true)
        unarchiver.setPropagatesRelevantMetadata(true)
        if let password { unarchiver.setPassword(password) }

        let parseError = unarchiver.parse()
        if delegate.wasCancelled { throw ExtractError.failed("Cancelled: password prompt.") }
        let extractionError = unarchiver.unarchive()
        if delegate.wasCancelled { throw ExtractError.failed("Cancelled: password prompt.") }

        let passwordFailed = delegate.passwordFailed || parseError == Int32(XADPasswordError) || extractionError == Int32(XADPasswordError)
        if passwordFailed {
            throw ExtractError.needsPassword(wrong: password != nil || delegate.requestedPassword)
        }

        var failures = delegate.failures
        if parseError != 0 {
            appendUnique("Archive parsing failed: \(errorDescription(parseError))", to: &failures)
        }
        if extractionError != 0 && extractionError != Int32(XADBreakError) {
            appendUnique("Archive extraction failed: \(errorDescription(extractionError))", to: &failures)
        }
        if extractionError == Int32(XADBreakError) {
            throw ExtractError.failed("Extraction was stopped.")
        }

        guard delegate.successfulEntries > 0 else {
            if let firstFailure = failures.first { throw ExtractError.failed(firstFailure) }
            throw ExtractError.failed("No files were extracted.")
        }

        let stagedItems = try fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
        guard !stagedItems.isEmpty else {
            throw ExtractError.failed(failures.first ?? "No files were extracted.")
        }
        // XADMaster applies its enclosing-directory/solo-item policy within staging.
        // A single staged item is the final result; multiple items are retained together.
        let output = stagedItems.count == 1 ? stagedItems[0] : staging
        propagateQuarantine(from: archive, into: output)

        let outputName = output == staging ? baseName(of: archive) : output.lastPathComponent
        let finalURL = uniqueURL(destinationDir.appendingPathComponent(outputName, isDirectory: true))
        try fileManager.moveItem(at: output, to: finalURL)
        progress(1)

        let volumePaths = unarchiver.outerArchiveParser()?.allFilenames() as? [String] ?? [archive.path]
        let volumes = volumePaths.map { URL(fileURLWithPath: $0) }
        return ExtractionResult(url: finalURL, failures: failures, volumes: volumes)
    }

    /// Container formats only: zip-based documents (docx, jar, apk…) must stay intact.
    private static let nestedExtensions: Set<String> = [
        "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "lzma",
        "cab", "lha", "lzh", "cpio", "xar", "cbz", "cbr", "cb7", "mcpc", "output",
    ]
    /// Bounds archive quines and zip bombs.
    private static let maxNestingDepth = 8

    /// Extracts every archive found under `root` in place, repeating for archives those
    /// produce. An inner archive is deleted only after it extracts without failures.
    static func extractNested(
        in root: URL,
        password: String?,
        requestPassword: @escaping (Bool) -> String?,
        depth: Int = 1
    ) -> [String] {
        guard depth <= maxNestingDepth else {
            return ["Stopped unpacking nested archives deeper than \(maxNestingDepth) levels."]
        }
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if nestedExtensions.contains(root.pathExtension.lowercased()) {
            candidates.append(root)
        } else if let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in enumerator
            where nestedExtensions.contains(url.pathExtension.lowercased())
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                candidates.append(url)
            }
        }

        var failures: [String] = []
        for archive in candidates {
            do {
                let result = try extract(
                    archive, to: archive.deletingLastPathComponent(),
                    password: password, requestPassword: requestPassword, progress: { _ in })
                failures += result.failures.map { "\(archive.lastPathComponent): \($0)" }
                if result.failures.isEmpty {
                    for volume in result.volumes { try? fileManager.removeItem(at: volume) }
                }
                failures += extractNested(in: result.url, password: password,
                                          requestPassword: requestPassword, depth: depth + 1)
            } catch ExtractError.failed(let message) where message == "Not a recognized archive, or the file is damaged." {
                continue // e.g. a plain-text *.output file
            } catch {
                failures.append("\(archive.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return failures
    }

    static func baseName(of url: URL) -> String {
        var base = url.deletingPathExtension()
        if base.pathExtension.lowercased() == "tar" { base = base.deletingPathExtension() }
        return base.lastPathComponent
    }

    static func uniqueURL(_ url: URL) -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let directory = url.deletingLastPathComponent()
        let extensionName = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let name = extensionName.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(extensionName)"
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private static func errorDescription(_ error: Int32) -> String {
        XADException.describeXADError(error) as String
    }

    private static func appendUnique(_ failure: String, to failures: inout [String]) {
        if !failures.contains(failure) { failures.append(failure) }
    }

    /// XADMaster propagates cloneable metadata, but keep Gatekeeper's quarantine flag
    /// explicit for every output node as not all parser formats preserve it themselves.
    private static func propagateQuarantine(from archive: URL, into root: URL) {
        let attribute = "com.apple.quarantine"
        let size = getxattr(archive.path, attribute, nil, 0, 0, 0)
        guard size > 0 else { return }
        var value = [UInt8](repeating: 0, count: size)
        guard getxattr(archive.path, attribute, &value, size, 0, 0) == size else { return }

        func apply(to url: URL) {
            _ = setxattr(url.path, attribute, value, size, 0, XATTR_NOFOLLOW)
        }

        apply(to: root)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in enumerator { apply(to: url) }
    }
}

/// Objective-C delegate callbacks are invoked synchronously by XADMaster on the
/// extraction worker. Only password UI crosses to the main thread synchronously.
private final class XADExtractionDelegate: NSObject {
    private let requestPassword: (Bool) -> String?
    private let progressHandler: (Double) -> Void
    private let initialPassword: String?
    private var lastProgress = -1.0
    private var lastProgressTime = Date.distantPast

    private(set) var requestedPassword = false
    private(set) var wasCancelled = false
    private(set) var passwordFailed = false
    private(set) var successfulEntries = 0
    private(set) var failures: [String] = []

    init(requestPassword: @escaping (Bool) -> String?, progress: @escaping (Double) -> Void, initialPassword: String?) {
        self.requestPassword = requestPassword
        self.progressHandler = progress
        self.initialPassword = initialPassword
        super.init()
    }

    override func simpleUnarchiverNeedsPassword(_ unarchiver: XADSimpleUnarchiver) {
        guard !wasCancelled else { return }
        let isRetry = initialPassword != nil || requestedPassword
        requestedPassword = true
        let password: String?
        if Thread.isMainThread {
            password = requestPassword(isRetry)
        } else {
            password = DispatchQueue.main.sync { requestPassword(isRetry) }
        }
        guard let password else {
            wasCancelled = true
            return
        }
        unarchiver.setPassword(password)
    }

    override func simpleUnarchiver(_ unarchiver: XADSimpleUnarchiver, encodingNameFor string: any XADStringProtocol) -> String? {
        let detectedEncoding = string.encodingName()
        guard string.confidence() < 0.75 else { return detectedEncoding }

        // The detector defaults uncertain legacy ZIP names to Windows-1252. Try
        // Shift-JIS for a strong Japanese-script decode, then honor ZIP's CP437 default.
        if let japaneseName = String(data: string.data(), encoding: .shiftJIS),
           japaneseName.unicodeScalars.contains(where: isJapaneseScalar) {
            return "Shift_JIS"
        }
        return "ibm437"
    }

    private func isJapaneseScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0x3040...0x30FF).contains(scalar.value) || (0x3400...0x9FFF).contains(scalar.value)
    }

    override func simpleUnarchiver(
        _ unarchiver: XADSimpleUnarchiver?,
        didExtractEntryWith dictionary: [AnyHashable: Any]?,
        to path: String?,
        error: Int32
    ) {
        if error == 0 {
            successfulEntries += 1
            return
        }
        if error == Int32(XADPasswordError) {
            passwordFailed = true
            return
        }

        let entry = dictionary?["XADFileName"]
        let fallbackName = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown entry"
        let name = (entry as? CustomStringConvertible)?.description ?? fallbackName
        let reason = XADException.describeXADError(error) as String
        failures.append("\(name): \(reason)")
    }

    override func simpleUnarchiver(
        _ unarchiver: XADSimpleUnarchiver?,
        replacementPathForEntryWith dictionary: [AnyHashable: Any]?,
        originalPath path: String?,
        suggestedPath: String?
    ) -> String? {
        guard let path else { return suggestedPath }
        return Extractor.uniqueURL(URL(fileURLWithPath: path)).path
    }

    override func simpleUnarchiver(
        _ unarchiver: XADSimpleUnarchiver?,
        deferredReplacementPathForOriginalPath path: String?,
        suggestedPath: String?
    ) -> String? {
        guard let path else { return suggestedPath }
        return Extractor.uniqueURL(URL(fileURLWithPath: path)).path
    }

    override func simpleUnarchiver(
        _ unarchiver: XADSimpleUnarchiver?,
        extractionProgressForEntryWith dictionary: [AnyHashable: Any]?,
        fileProgress: Int64,
        of fileSize: Int64,
        totalProgress: Int64,
        of totalSize: Int64
    ) {
        guard totalSize > 0 else { return }
        report(Double(totalProgress) / Double(totalSize))
    }

    override func simpleUnarchiver(
        _ unarchiver: XADSimpleUnarchiver?,
        estimatedExtractionProgressForEntryWith dictionary: [AnyHashable: Any]?,
        fileProgress: Double,
        totalProgress: Double
    ) {
        report(totalProgress)
    }

    override func extractionShouldStop(for unarchiver: XADSimpleUnarchiver?) -> Bool {
        wasCancelled || passwordFailed
    }

    private func report(_ value: Double) {
        guard value.isFinite else { return }
        let fraction = min(max(value, 0), 1)
        let now = Date()
        guard lastProgress < 0 || fraction - lastProgress >= 0.01 || now.timeIntervalSince(lastProgressTime) >= 0.1 else { return }
        lastProgress = fraction
        lastProgressTime = now
        progressHandler(fraction)
    }
}
