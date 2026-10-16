import AppKit
import Observation
import Sparkle

@MainActor
@Observable
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()
    var beforeRelaunch: (() async -> Void)?
    private(set) var canCheck = false
    private(set) var automaticChecks = false
    private(set) var lastCheck: Date?
    private(set) var error: String?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    static var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local"
        return "\(version) (\(build))"
    }

    func start() {
        guard controller == nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
                let canCheck = change.newValue ?? false
                Task { @MainActor in self?.canCheck = canCheck }
            },
            controller.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, change in
                let enabled = change.newValue ?? false
                Task { @MainActor in self?.automaticChecks = enabled }
            },
            controller.updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] _, change in
                let date = change.newValue ?? nil
                Task { @MainActor in self?.lastCheck = date }
            },
        ]
        controller.startUpdater()
    }

    func setAutomaticChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func check() {
        guard canCheck else { return }
        error = nil
        controller?.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard let beforeRelaunch else { return false }
        Task { await beforeRelaunch(); installHandler() }
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        self.error = error.localizedDescription
    }
}
