import AppKit
import Sparkle

/// Check the real updater against a supplied feed without downloading or installing it.
@MainActor
final class UpdateProbe: NSObject, SPUUpdaterDelegate {
    private static var active: UpdateProbe?
    private let feed: String
    private let expected: String
    private var controller: SPUStandardUpdaterController?

    private init(feed: String, expected: String) { self.feed = feed; self.expected = expected }

    static func run(feed: String, expected: String) {
        let probe = UpdateProbe(feed: feed, expected: expected)
        active = probe
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: probe, userDriverDelegate: nil)
        probe.controller = controller
        do {
            try controller.updater.start()
            controller.updater.checkForUpdateInformation()
        } catch { probe.finish("configuration", detail: error.localizedDescription) }
        Task {
            try? await Task.sleep(for: .seconds(30))
            probe.finish("timeout", detail: "The feed check took too long")
        }
    }

    func feedURLString(for updater: SPUUpdater) -> String? { feed }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        finish("update", detail: "\(item.displayVersionString) (\(item.versionString))")
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        finish("current", detail: error.localizedDescription)
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        finish("reject", detail: error.localizedDescription)
    }
    private func finish(_ result: String, detail: String) -> Never {
        print("\(result == expected ? "PASS" : "FAIL"): updater \(result): \(detail)")
        exit(result == expected ? 0 : 1)
    }
}
