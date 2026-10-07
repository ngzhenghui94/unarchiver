import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum DestinationMode: String, CaseIterable, Identifiable {
    case sameFolder = "Same folder as archive"
    case ask = "Ask every time"
    case fixed = "Fixed folder"
    var id: String { rawValue }
}

enum OperationMode: String, CaseIterable, Identifiable {
    case extract = "Extract"
    case compress = "Compress"

    var id: String { rawValue }
}

let defaultDestination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path

enum Prefs {
    static var d: UserDefaults { .standard }
    static var destinationMode: DestinationMode {
        DestinationMode(rawValue: d.string(forKey: "destinationMode") ?? "") ?? .sameFolder
    }
    static var fixedDestination: String { d.string(forKey: "fixedDestination") ?? defaultDestination }
    static var openAfter: Bool { d.bool(forKey: "openAfter") }
    static var trashAfter: Bool { d.bool(forKey: "trashAfter") }
    static var extractNested: Bool { d.bool(forKey: "extractNested") }
}
struct Job: Identifiable {
    enum Operation {
        case extract(URL)
        case compress(sources: [URL], output: URL)

        var displayName: String {
            switch self {
            case .extract(let archive): return archive.lastPathComponent
            case .compress(_, let output): return output.lastPathComponent
            }
        }

        var verb: String {
            switch self {
            case .extract: return "Extract"
            case .compress: return "Compress"
            }
        }
    }

    enum State { case queued, running(Double), done(URL, [String]), failed(String) }
    let id = UUID()
    let operation: Operation
    var state: State = .queued
}

// Cleared after the worker finishes even while its completed queue task is retained.
private final class CompressionPassword: @unchecked Sendable {
    var value: String?
    init(_ value: String?) { self.value = value }
}

@MainActor
final class Queue: ObservableObject {
    static let shared = Queue()
    @Published var jobs: [Job] = []
    private var tail: Task<Void, Never>?
    private var rejectsNewJobs = false
    private var quitWhenDone = false

    var isBusy: Bool {
        jobs.contains {
            switch $0.state {
            case .queued, .running: return true
            case .done, .failed: return false
            }
        }
    }

    func open(_ urls: [URL]) {
        guard !rejectsNewJobs else { return }
        for url in urls where url.isFileURL {
            let job = Job(operation: .extract(url), state: .queued)
            jobs.insert(job, at: 0)
            let previous = tail
            tail = Task { @MainActor in
                if let previous { await previous.value }
                await self.run(job)
                self.finishIfDrained()
            }
        }
    }

    func compress(_ urls: [URL]) {
        guard !rejectsNewJobs, !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = urls.count == 1 ? urls[0].lastPathComponent + ".zip" : "Archive.zip"
        panel.directoryURL = urls[0].deletingLastPathComponent()
        panel.prompt = "Continue"
        panel.message = "Choose where to save the ZIP. Existing files are kept using a numbered name."
        guard panel.runModal() == .OK, let output = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = "ZIP password (optional)"
        alert.informativeText = "Leave both fields blank for a regular ZIP. A password enables AES-256; filenames remain visible. Open encrypted ZIPs with Archiver or 7-Zip."
        let passwordField = NSSecureTextField()
        passwordField.placeholderString = "Password (optional)"
        passwordField.setAccessibilityLabel("Password (optional)")
        let confirmation = NSSecureTextField()
        confirmation.placeholderString = "Confirm password"
        confirmation.setAccessibilityLabel("Confirm password")
        let fields = NSStackView(views: [passwordField, confirmation])
        fields.orientation = .vertical
        fields.alignment = .leading
        passwordField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        confirmation.widthAnchor.constraint(equalToConstant: 300).isActive = true
        fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 300, height: 56)
        alert.accessoryView = fields
        alert.addButton(withTitle: "Compress")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = passwordField
        defer { passwordField.stringValue = ""; confirmation.stringValue = "" }
        while true {
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if passwordField.stringValue == confirmation.stringValue { break }
            alert.messageText = "Passwords do not match"
        }
        let secret = CompressionPassword(passwordField.stringValue.isEmpty ? nil : passwordField.stringValue)
        let job = Job(operation: .compress(sources: urls, output: output))
        jobs.insert(job, at: 0)
        let previous = tail
        tail = Task { @MainActor in
            if let previous { await previous.value }
            defer { secret.value = nil; self.finishIfDrained() }
            self.update(job.id, .running(0))
            do {
                let result = try await Task.detached {
                    try Compressor.compress(urls, to: output, password: secret.value) { value in
                        Task { @MainActor in self.updateProgress(job.id, value) }
                    }
                }.value
                self.update(job.id, .done(result, []))
                if Prefs.openAfter { NSWorkspace.shared.activateFileViewerSelecting([result]) }
            } catch {
                self.update(job.id, .failed(error.localizedDescription))
            }
        }
    }

    func requestQuitWhenDone() -> Bool {
        rejectsNewJobs = true
        guard isBusy else { return false }
        quitWhenDone = true
        return true
    }

    private func destination(for archive: URL) -> URL? {
        switch Prefs.destinationMode {
        case .sameFolder: return archive.deletingLastPathComponent()
        case .fixed: return URL(fileURLWithPath: Prefs.fixedDestination)
        case .ask:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Extract"
            panel.message = "Extract “\(archive.lastPathComponent)” to:"
            panel.directoryURL = archive.deletingLastPathComponent()
            return panel.runModal() == .OK ? panel.url : nil
        }
    }

    private func run(_ job: Job) async {
        update(job.id, .running(0))
        guard case .extract(let archive) = job.operation else { return }
        guard let dest = destination(for: archive) else {
            jobs.removeAll { $0.id == job.id }
            return
        }
        var password: String?
        while true {
            do {
                let pw = password
                let nested = Prefs.extractNested
                let result = try await Task.detached {
                    let requestPassword: (Bool) -> String? = { retry in
                        if Thread.isMainThread {
                            return MainActor.assumeIsolated { self.askPassword(for: archive, retry: retry) }
                        }
                        return DispatchQueue.main.sync {
                            MainActor.assumeIsolated { self.askPassword(for: archive, retry: retry) }
                        }
                    }
                    let outer = try Extractor.extract(
                        archive,
                        to: dest,
                        password: pw,
                        requestPassword: requestPassword,
                        progress: { value in
                            Task { @MainActor in self.updateProgress(job.id, value) }
                        }
                    )
                    guard nested else { return outer }
                    let failures = Extractor.extractNested(in: outer.url, password: pw, requestPassword: requestPassword)
                    // A lone nested archive is replaced by its own contents.
                    let url = FileManager.default.fileExists(atPath: outer.url.path) ? outer.url : outer.url.deletingLastPathComponent()
                    return ExtractionResult(url: url, failures: outer.failures + failures, volumes: outer.volumes)
                }.value
                update(job.id, .done(result.url, result.failures))
                if Prefs.openAfter { NSWorkspace.shared.activateFileViewerSelecting([result.url]) }
                if Prefs.trashAfter && result.failures.isEmpty {
                    let volumes = result.volumes.isEmpty ? [archive] : result.volumes
                    for volume in volumes { try? FileManager.default.trashItem(at: volume, resultingItemURL: nil) }
                }
                return
            } catch ExtractError.needsPassword(let wrong) {
                guard let pw = askPassword(for: archive, retry: wrong) else {
                    update(job.id, .failed("Cancelled: password required."))
                    return
                }
                password = pw
            } catch {
                update(job.id, .failed(error.localizedDescription))
                return
            }
        }
    }

    private func finishIfDrained() {
        guard quitWhenDone, !isBusy else { return }
        quitWhenDone = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    private func update(_ id: UUID, _ state: Job.State) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].state = state }
    }

    private func updateProgress(_ id: UUID, _ progress: Double) {
        guard let job = jobs.first(where: { $0.id == id }), case .running = job.state else { return }
        update(id, .running(progress))
    }

    private func askPassword(for archive: URL, retry: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = retry ? "Wrong password. Try again." : "Password required"
        alert.informativeText = "“\(archive.lastPathComponent)” is encrypted."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Extract")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Finder "Open With" / double-click / dropping on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in Queue.shared.open(urls) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let queue = Queue.shared
            guard queue.isBusy else { return .terminateNow }

            let alert = NSAlert()
            alert.messageText = "Archive operation in progress"
            alert.informativeText = "The current operation and any queued jobs will finish before the app quits."
            alert.addButton(withTitle: "Quit When Done")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()

            if alert.runModal() == .alertFirstButtonReturn {
                return queue.requestQuitWhenDone() ? .terminateLater : .terminateNow
            }
            return .terminateCancel
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct UnarchiverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("Archiver", id: "main") {
            ContentView().environmentObject(Queue.shared)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Archive…") { chooseArchives() }.keyboardShortcut("o")
                Button("Compress Files…") { chooseFilesToCompress() }.keyboardShortcut("k")
            }
        }
        Settings { SettingsView() }
    }
}

@MainActor
func chooseArchives() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.prompt = "Extract"
    if panel.runModal() == .OK { Queue.shared.open(panel.urls) }
}

@MainActor
func chooseFilesToCompress() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.prompt = "Compress"
    if panel.runModal() == .OK { Queue.shared.compress(panel.urls) }
}

struct ContentView: View {
    @EnvironmentObject var queue: Queue
    @State private var targeted = false
    @State private var mode: OperationMode = .extract
    @AppStorage("extractNested") private var extractNested = false

    var body: some View {
        VStack(spacing: 12) {
            Picker("Operation", selection: $mode) {
                ForEach(OperationMode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            VStack(spacing: 8) {
                Image(systemName: "archivebox").font(.system(size: 44))
                Text(mode == .extract ? "Drop archives here" : "Drop files or folders here").font(.headline)
                Text(mode == .extract ? "zip · 7z · rar · tar · gz · bz2 · xz · iso · cab · lha · cpio · xar" : "Create one ZIP · Optional AES-256 password")
                    .font(.caption).foregroundStyle(.secondary)
                if mode == .extract {
                    Button("Open Archive…") { chooseArchives() }
                    Toggle("Also extract archives found inside archives", isOn: $extractNested)
                        .toggleStyle(.checkbox).font(.callout)
                } else {
                    Button("Choose Files…") { chooseFilesToCompress() }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 170)
            .background(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                .foregroundStyle(targeted ? Color.accentColor : .secondary.opacity(0.5)))
            .dropDestination(for: URL.self) { urls, _ in
                guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
                let operation = mode
                DispatchQueue.main.async {
                    if operation == .extract { queue.open(urls) } else { queue.compress(urls) }
                }
                return true
            } isTargeted: { targeted = $0 }

            if !queue.jobs.isEmpty {
                List(queue.jobs) { job in JobRow(job: job) }
                    .frame(minHeight: 140)
            }
        }
        .padding()
        .frame(width: 440)
    }
}

struct JobRow: View {
    let job: Job
    var body: some View {
        HStack {
            switch job.state {
            case .queued:
                Image(systemName: "clock").foregroundStyle(.secondary)
                Text(job.operation.displayName).foregroundStyle(.secondary)
            case .running(let progress):
                ProgressView(value: progress) {
                    Text("\(job.operation.verb): \(job.operation.displayName)").lineLimit(1)
                }
                .progressViewStyle(.linear)
            case .done(let url, let failures):
                if failures.isEmpty {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(job.operation.displayName)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    VStack(alignment: .leading) {
                        Text(job.operation.displayName)
                        Text("Extracted with \(failures.count) problem(s)")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                        Text(failures[0]).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .help(failures.joined(separator: "\n"))
                }
                Spacer()
                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.link)
            case .failed(let msg):
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                VStack(alignment: .leading) {
                    Text(job.operation.displayName)
                    Text(msg).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }
}

struct SettingsView: View {
    @AppStorage("destinationMode") var mode: DestinationMode = .sameFolder
    @AppStorage("fixedDestination") var fixed: String =
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
    @AppStorage("openAfter") var openAfter = false
    @AppStorage("trashAfter") var trashAfter = false
    @AppStorage("extractNested") var extractNested = false

    var body: some View {
        Form {
            Picker("Extract to:", selection: $mode) {
                ForEach(DestinationMode.allCases) { Text($0.rawValue).tag($0) }
            }
            if mode == .fixed {
                HStack {
                    Text(fixed).lineLimit(1).truncationMode(.middle)
                    Button("Choose…") {
                        let p = NSOpenPanel()
                        p.canChooseDirectories = true
                        p.canChooseFiles = false
                        p.canCreateDirectories = true
                        if p.runModal() == .OK, let u = p.url { fixed = u.path }
                    }
                }
            }
            Toggle("Reveal extracted files in Finder", isOn: $openAfter)
            Toggle("Also extract archives found inside archives", isOn: $extractNested)
            Toggle("Move archive to Trash after extraction", isOn: $trashAfter)
        }
        .padding(20)
        .frame(width: 420)
    }
}
