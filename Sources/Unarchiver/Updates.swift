import AppKit
import Sparkle
import SwiftUI

@MainActor
final class AppUpdates: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdates()
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var installing = false
    private var controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?
    private var installationTask: Task<Void, Never>?
    private var installInvoked = false

    func start() {
        guard controller == nil, !CommandLine.arguments.contains("--selftest") else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
        updater.sendsSystemProfile = false
        observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            Task { @MainActor [weak self] in self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
        controller.startUpdater()
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    func updater(_ updater: SPUUpdater, mayPerform check: SPUUpdateCheck) throws { try requireManualCheck(check) }

    func requireManualCheck(_ check: SPUUpdateCheck) throws {
        guard check == .updates, !Queue.shared.isBusy, !installing else {
            throw NSError(domain: "Archiver.Updates", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Choose Check for Updates… after archive operations finish. Updates are manual only."])
        }
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeInstallation(installHandler)
        return true
    }

    func postponeInstallation(_ installHandler: @escaping () -> Void) {
        guard installationTask == nil else { return }
        installing = true
        installationTask = Task { @MainActor in
            while Queue.shared.isBusy {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            installInvoked = true
            installHandler()
        }
    }

    func cancelInstallation() {
        installationTask?.cancel()
        installationTask = nil
        installInvoked = false
        installing = false
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { cancelInstallation() }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor check: SPUUpdateCheck, error: Error?) {
        if error != nil || !installInvoked { cancelInstallation() }
    }

    static func selfTest() async throws {
        let updates = shared
        let queue = Queue.shared
        try updates.requireManualCheck(.updates)
        do { try updates.requireManualCheck(.updatesInBackground); preconditionFailure("Background check accepted") } catch { }
        let job = Job(operation: .extract(URL(fileURLWithPath: "/unused-test-fixture.zip")))
        queue.jobs.append(job)
        do { try updates.requireManualCheck(.updates); preconditionFailure("Busy check accepted") } catch { }
        var invoked = false
        updates.postponeInstallation { invoked = true }
        let count = queue.jobs.count
        queue.open([URL(fileURLWithPath: "/unused-test-fixture.zip")])
        precondition(queue.jobs.count == count && updates.installing && !invoked)
        queue.jobs.removeAll()
        await updates.installationTask?.value
        precondition(invoked && updates.installing)
        updates.cancelInstallation()
        precondition(!updates.installing)
        print("update safety selftest ok: manual checks, busy rejection, drain and consumer guard")
    }
}

@main
struct Main {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--selftest") {
            do { try await AppUpdates.selfTest() } catch { fatalError(error.localizedDescription) }
            return
        }
        UnarchiverApp.main()
    }
}
