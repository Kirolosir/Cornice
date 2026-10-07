import AppKit

/// A non-activating panel so clicks don't steal focus. Keep the window at its largest size
/// and animate inside it; resizing the window too caused stuttering. Hit testing lets
/// clicks outside the visible panel pass through.
final class NotchPanel: NSPanel {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // One above the menu bar, so the surface is never occluded by it.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false          // SwiftUI draws a shadow shaped to the surface
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        // Without this the panel is excluded from screen recordings, which
        // makes the app impossible to demo or document.
        sharingType = .readOnly
        animationBehavior = .none
        tabbingMode = .disallowed
    }

    /// A borderless panel returns `false` by default, which would break the
    /// text fields in Settings and any keyboard handling.
    override var canBecomeKey: Bool { true }

    /// Never becomes main: that would deactivate the user's frontmost app.
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    var onCancel: (() -> Void)?
}

/// Host SwiftUI and handle hover and clicks against the visible shape. The transparent part
/// of the fixed-size window mustn't intercept the desktop.
final class NotchContentView: NSView {

    /// The region that accepts clicks, in this view's coordinates. Matches
    /// what is drawn, so clicks never land on invisible space.
    var interactiveRect: CGRect = .zero

    /// The measured notch while resting, or the visible panel while open.
    var hoverRect: CGRect = .zero {
        didSet {
            guard hoverRect != oldValue else { return }
            // A state change can move the surface out from under a stationary
            // pointer, which must register as a hover change even though the
            // mouse has not moved.
            hoverUpdate?.cancel()
            let update = DispatchWorkItem { [weak self] in self?.reevaluateHover() }
            hoverUpdate = update
            DispatchQueue.main.async(execute: update)
        }
    }

    private var hoverUpdate: DispatchWorkItem?
    var onHoverChanged: ((Bool) -> Void)?

    private var trackingArea: NSTrackingArea?
    private(set) var isPointerInside = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // `.mouseMoved` rather than enter/exit: the useful boundary is the
        // shape, not the window.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(for: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(for: convert(event.locationInWindow, from: nil))
    }

    /// Leaving the window is unambiguous, whatever the shape says.
    override func mouseExited(with event: NSEvent) {
        setHover(false)
    }

    /// Re-checks against the pointer's real position, for when the surface
    /// changed shape rather than the pointer moving.
    func reevaluateHover() {
        guard let window else { return }
        let locationInWindow = window.mouseLocationOutsideOfEventStream
        updateHover(for: convert(locationInWindow, from: nil))
    }

    private func updateHover(for point: CGPoint) {
        setHover(hoverRect.contains(point))
    }

    private func setHover(_ hovering: Bool) {
        guard hovering != isPointerInside else { return }
        isPointerInside = hovering
        onHoverChanged?(hovering)
    }

    /// Return nil outside the visible panel so clicks reach the window underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard interactiveRect.contains(local) else { return nil }
        return super.hitTest(point)
    }

    /// The panel is non-activating, so a first click must act on the control
    /// under the pointer rather than being consumed to focus the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
