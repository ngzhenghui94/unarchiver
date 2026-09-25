import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum DestinationMode: String, CaseIterable, Identifiable {
    case sameFolder = "Same folder as archive"
    case ask = "Ask every time"
    case fixed = "Fixed folder"
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
    enum State { case queued, running(Double), done(URL, [String]), failed(String) }
    let id = UUID()
    let archive: URL
    var state: State = .queued
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
            let job = Job(archive: url, state: .queued)
            jobs.insert(job, at: 0)
            let previous = tail
            tail = Task { @MainActor in
                if let previous { await previous.value }
                await self.run(job)
                self.finishIfDrained()
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
        let archive = job.archive
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
            alert.messageText = "Extraction in progress"
            alert.informativeText = "The current extraction and any queued archives will finish before the app quits."
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
        Window("Unarchiver", id: "main") {
            ContentView().environmentObject(Queue.shared)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Archive…") { chooseArchives() }.keyboardShortcut("o")
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

struct ContentView: View {
    @EnvironmentObject var queue: Queue
    @State private var targeted = false
    @AppStorage("extractNested") private var extractNested = false

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 8) {
                Image(systemName: "archivebox").font(.system(size: 44))
                Text("Drop archives here").font(.headline)
                Text("zip · 7z · rar · tar · gz · bz2 · xz · iso · cab · lha · cpio · xar")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Archive…") { chooseArchives() }
                Toggle("Also extract archives found inside archives", isOn: $extractNested)
                    .toggleStyle(.checkbox)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, minHeight: 170)
            .background(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                .foregroundStyle(targeted ? Color.accentColor : .secondary.opacity(0.5)))
            .dropDestination(for: URL.self) { urls, _ in
                queue.open(urls)
                return !urls.isEmpty
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
                Text(job.archive.lastPathComponent).foregroundStyle(.secondary)
            case .running(let progress):
                ProgressView(value: progress) {
                    Text(job.archive.lastPathComponent).lineLimit(1)
                }
                .progressViewStyle(.linear)
            case .done(let url, let failures):
                if failures.isEmpty {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(job.archive.lastPathComponent)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    VStack(alignment: .leading) {
                        Text(job.archive.lastPathComponent)
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
                    Text(job.archive.lastPathComponent)
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
