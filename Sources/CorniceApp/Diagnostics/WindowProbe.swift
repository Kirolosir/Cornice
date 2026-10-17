import AppKit
import CorniceKit

@MainActor
extension Probes {
    static func probeWindow() async {
        func check(_ condition: Bool, _ message: String) {
            guard condition else { print("FAIL: \(message)"); exit(1) }
            print("PASS: \(message)")
        }
        let model = AppModel(services: PreviewServices.container())
        var preferences = PreviewServices.previewPreferences()
        preferences.mediaAccessEnabled = false
        preferences.hoverDwell = 0
        model.applyPreferences(preferences)
        let controller = NotchWindowController(model: model)
        let panel = controller.installProbePanel()

        controller.toggle()
        controller.pointerChanged(hovering: true)
        controller.pointerChanged(hovering: false)
        try? await Task.sleep(for: .milliseconds(300))
        check(model.surfaceState == .expanded, "keyboard opening stays open when the pointer leaves")
        controller.open()
        check(model.surfaceState == .expanded, "opening a selected panel never toggles it closed")
        model.select(module: .stats)
        try? await Task.sleep(for: .milliseconds(300))
        check(model.surfaceState == .expanded && model.activeModule == .stats,
              "keyboard module changes work with the pointer outside the panel")
        panel.cancelOperation(nil)
        check(model.surfaceState == .collapsed, "Escape follows the panel's close action")

        controller.pointerChanged(hovering: true)
        check(model.surfaceState == .expanded, "hover still opens the measured surface")
        controller.pointerChanged(hovering: false)
        try? await Task.sleep(for: .milliseconds(300))
        check(model.surfaceState == .collapsed, "a hover-opened panel still retracts after pointer exit")

        controller.toggle()
        model.isPresentingPopover = true
        controller.pointerChanged(hovering: false)
        controller.handleOutsideClick()
        check(model.surfaceState == .expanded, "a popover does not dismiss its keyboard-opened parent")
        model.isPresentingPopover = false
        controller.pointerChanged(hovering: false)
        try? await Task.sleep(for: .milliseconds(300))
        check(model.surfaceState == .expanded, "popover hover reevaluation preserves keyboard opening")
        controller.handleOutsideClick()
        check(model.surfaceState == .collapsed, "a click outside dismisses explicit opening")
        controller.toggle()
        controller.toggle()
        check(model.surfaceState == .collapsed, "the keyboard toggle also closes the panel")

        controller.tearDown()
        model.shutDown()

        let preview = PreviewServices.container().media
        let first = await preview.snapshot()!
        try? await Task.sleep(for: .milliseconds(120))
        let second = await preview.snapshot()!
        check(second.position > first.position, "the preview player reports an advancing playhead")
        try? await preview.perform(.playPause, on: .spotify)
        let paused = await preview.snapshot()!
        try? await Task.sleep(for: .milliseconds(120))
        let stillPaused = await preview.snapshot()!
        check(paused.state == .paused && paused.position == stillPaused.position,
              "pausing the preview freezes the reported playhead")
        try? await preview.perform(.playPause, on: .spotify)
        try? await Task.sleep(for: .milliseconds(120))
        let resumed = await preview.snapshot()!
        check(resumed.state == .playing && resumed.position > paused.position,
              "resuming the preview continues from its paused position")
        print("Window interaction probe passed")
        exit(0)
    }
}
