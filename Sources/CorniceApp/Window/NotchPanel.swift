import AppKit

/// The borderless window the whole interface lives in.
///
/// An `NSPanel` rather than an `NSWindow` because a panel can be
/// non-activating: clicking the surface must not steal focus from the editor
/// the user is typing in. That is the difference between a tool that answers a
/// glance and one that interrupts you.
///
/// The window level is pinned above the menu bar so the surface is not occluded
/// by it, and the collection behaviour keeps it visible across Spaces and over
/// full-screen apps — a build failing while you are full-screen in Xcode is
/// exactly when you want to see it.
final class NotchPanel: NSPanel {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // One above the menu bar. `.statusBar` alone still renders beneath the
        // menu bar's own layer on some configurations.
        level = NSWindow.Level(
            rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1
        )
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            // Keeps the surface out of Mission Control and the window cycle,
            // where a notch-shaped window would just be confusing.
            .ignoresCycle,
        ]

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false          // the SwiftUI layer draws its own, shaped to the panel
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        // Without this the panel is excluded from screenshots and screen
        // recordings, which makes it impossible to document or demo.
        sharingType = .readOnly
        animationBehavior = .none
        // The panel never becomes key, so it must not be in the tab bar either.
        tabbingMode = .disallowed
    }

    /// A borderless panel returns `false` by default, which would stop the
    /// keyboard shortcuts and the text fields in Settings from working.
    override var canBecomeKey: Bool { true }

    /// Never becomes main: that would deactivate the user's frontmost app.
    override var canBecomeMain: Bool { false }

    /// Escape collapses the panel.
    ///
    /// Handled here rather than with a SwiftUI `.onKeyPress` because the panel
    /// is only key while something inside it has focus, and Escape should work
    /// whenever the panel is open.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    var onCancel: (() -> Void)?
}

/// Hosts the SwiftUI hierarchy and reports pointer transitions.
///
/// Hover is tracked with an explicit `NSTrackingArea` rather than SwiftUI's
/// `.onHover`. The window resizes as it expands and collapses, and SwiftUI's
/// hover state is derived from view geometry that has not settled yet mid
/// animation — which produces a feedback loop where expanding moves the surface
/// out from under the pointer, which collapses it, which moves it back. Tracking
/// the whole content view against the window's own bounds is stable because it
/// is updated once per resize, after layout.
final class NotchContentView: NSView {

    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }

    /// The panel is non-activating, so a first click must act on the control
    /// under the pointer rather than being swallowed to focus the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
