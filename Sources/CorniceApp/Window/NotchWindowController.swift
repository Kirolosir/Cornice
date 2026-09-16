import AppKit
import SwiftUI
import Combine
import CorniceKit

/// Owns the panel: where it sits, how big it is, and when it opens.
///
/// The interesting problem here is that the window has to change size between
/// its collapsed and expanded forms, and an `NSWindow` frame change is not
/// something SwiftUI can animate. Resizing in step with the content produces
/// visible tearing, and animating the frame with `NSAnimationContext`
/// double-animates against SwiftUI's own transition.
///
/// The resolution is to decouple them: the window is *always* sized to whatever
/// the interface needs at rest, but it grows **before** an expansion animation
/// and shrinks **after** a collapse animation. The user never sees the window
/// bounds, only the content SwiftUI draws inside them, so growing early and
/// shrinking late is invisible — while at rest the window is exactly the size
/// of what is drawn, which is what keeps hit-testing and hover correct.
@MainActor
final class NotchWindowController {

    private let model: AppModel
    private var panel: NotchPanel?
    private var hostingView: NSHostingView<RootView>?
    private var contentView: NotchContentView?

    private var hoverTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var observers: [any NSObjectProtocol] = []
    private var hotKey: GlobalHotKey?
    private var stateObservation: AnyCancellable?

    /// The display currently hosting the surface.
    private var currentProfile: NotchProfile?

    init(model: AppModel) {
        self.model = model
    }

    // MARK: - Setup

    func install() {
        resolveGeometry()
        buildPanel()
        observeScreenChanges()
        installHotKey()
    }

    private func buildPanel() {
        guard let profile = currentProfile else {
            Log.window.error("no display available; the surface cannot be placed")
            return
        }

        let panel = NotchPanel(contentRect: collapsedFrame(for: profile))
        let root = RootView(model: model)
        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let container = NotchContentView()
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        container.onMouseEntered = { [weak self] in self?.pointerEntered() }
        container.onMouseExited = { [weak self] in self?.pointerExited() }
        panel.contentView = container
        panel.onCancel = { [weak self] in self?.collapse() }
        panel.orderFrontRegardless()

        self.panel = panel
        self.hostingView = hosting
        self.contentView = container

        model.updateGeometry(profile)
        applyState(animated: false)
    }

    // MARK: - Geometry

    private func resolveGeometry() {
        let screens = ScreenBridge.allMetrics()
        guard let preferred = NotchGeometryResolver.preferredScreen(from: screens) else {
            currentProfile = nil
            return
        }
        currentProfile = NotchGeometryResolver.resolve(preferred)
    }

    /// Window frame for the collapsed surface.
    ///
    /// Wider than the notch only when there is something to show beside it, so
    /// an idle surface is exactly the notch and cannot be hovered by accident
    /// while reaching for a menu.
    private func collapsedFrame(for profile: NotchProfile) -> NSRect {
        let wings = model.collapsedContent.wingWidth
        let width = profile.rect.width + wings * 2
        let height = profile.rect.height + (wings > 0 ? Theme.Metrics.wingDrop : 0)
        return NSRect(
            x: profile.rect.midX - width / 2,
            y: profile.rect.maxY - height,
            width: width,
            height: height
        )
    }

    /// Window frame for the expanded panel.
    ///
    /// Clamped to the display so the panel cannot hang off the edge on a small
    /// screen or when the notch sits near a corner in a multi-display layout.
    private func expandedFrame(for profile: NotchProfile) -> NSRect {
        let width = min(Theme.Metrics.panelWidth, profile.screenFrame.width - 32)
        let height = ExpandedMetrics.height(for: model.activeModule)
            + profile.rect.height
            + Theme.Metrics.panelDrop

        var x = profile.rect.midX - width / 2
        x = max(profile.screenFrame.minX + 16, min(x, profile.screenFrame.maxX - width - 16))

        return NSRect(
            x: x,
            y: profile.rect.maxY - height,
            width: width,
            height: height
        )
    }

    /// Applies the window frame for the current state.
    func applyState(animated: Bool) {
        guard let panel, let profile = currentProfile else { return }

        let target = model.surfaceState == .expanded
            ? expandedFrame(for: profile)
            : collapsedFrame(for: profile)

        guard panel.frame != target else { return }

        switch model.surfaceState {
        case .expanded:
            // Grow first: the extra area is transparent until SwiftUI draws
            // into it, so this is invisible, and it means the panel is never
            // clipped mid-animation.
            panel.setFrame(target, display: true)
        case .collapsed:
            // Shrink last, once the content has finished animating away.
            // Shrinking immediately would clip the outgoing transition.
            collapseTask?.cancel()
            guard animated else {
                panel.setFrame(target, display: true)
                return
            }
            collapseTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(280))
                guard !Task.isCancelled, let self, let panel = self.panel else { return }
                guard self.model.surfaceState == .collapsed else { return }
                panel.setFrame(self.collapsedFrame(for: profile), display: true)
            }
        }
    }

    /// Re-measures after a display change and moves the panel.
    ///
    /// Screen parameters change on: attaching or detaching a display, changing
    /// resolution or scaling, rotating a display, and lid open/close on a
    /// clamshell setup. All of them can move or resize the notch, and two of
    /// them change its size *in points* without any hardware changing.
    private func handleScreenChange() {
        let previous = currentProfile
        resolveGeometry()
        guard let profile = currentProfile else {
            panel?.orderOut(nil)
            model.updateGeometry(nil)
            return
        }
        if previous == nil { panel?.orderFrontRegardless() }
        model.updateGeometry(profile)
        applyState(animated: false)
        Log.window.notice("display change: \(profile.debugSummary, privacy: .public)")
    }

    private func observeScreenChanges() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleScreenChange() }
        })

        // Waking from sleep can reconfigure displays without posting a screen
        // parameter change, leaving the panel on a display that no longer
        // exists or at a stale size.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleScreenChange() }
        })
    }

    // MARK: - Interaction

    private func installHotKey() {
        hotKey = GlobalHotKey { [weak self] in
            guard let self else { return }
            self.model.toggle()
            self.applyState(animated: true)
        }
        hotKey?.register()
    }

    /// Hover, with a dwell delay.
    ///
    /// Without the delay the panel opens every time the pointer crosses the top
    /// of the screen on its way to a menu, which makes the whole app feel like
    /// it is in the way. The delay is configurable and the behaviour can be
    /// switched off entirely in favour of click-only.
    private func pointerEntered() {
        model.setHovering(true)
        collapseTask?.cancel()

        guard model.preferences.activationStyle == .hover else { return }
        guard model.surfaceState == .collapsed else { return }

        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            guard let self else { return }
            let dwell = self.model.preferences.hoverDwell
            if dwell > 0 {
                try? await Task.sleep(for: .seconds(dwell))
            }
            guard !Task.isCancelled, self.model.isHovering else { return }
            self.expand()
        }
    }

    private func pointerExited() {
        hoverTask?.cancel()
        model.setHovering(false)

        guard model.surfaceState == .expanded else {
            applyState(animated: true)
            return
        }
        // A confirmation sheet is a deliberate decision point; closing it
        // because the pointer drifted away would be hostile.
        guard model.pendingConfirmation == nil else { return }
        guard model.preferences.activationStyle == .hover else { return }

        // A short grace period, so crossing a gap between controls — or
        // overshooting the panel edge by a few pixels — does not close it.
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled, let self else { return }
            guard !self.model.isHovering, self.model.pendingConfirmation == nil else { return }
            self.collapse()
        }
    }

    func expand() {
        model.expand()
        applyState(animated: true)
    }

    func collapse() {
        model.collapse()
        applyState(animated: true)
    }

    func toggle() {
        model.toggle()
        applyState(animated: true)
    }

    /// Re-applies the frame after the active module changes, since panes have
    /// different heights.
    func moduleDidChange() {
        applyState(animated: true)
    }

    func tearDown() {
        hoverTask?.cancel()
        collapseTask?.cancel()
        hotKey?.unregister()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        panel?.orderOut(nil)
    }
}
