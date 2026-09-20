import AppKit
import SwiftUI
import CorniceKit

/// Places the surface and drives its state.
///
/// The window is created once at its maximum size and never resized. All motion
/// happens inside it, in SwiftUI, at display rate. The controller's remaining
/// jobs are: keep the window over the right notch on the right display, keep
/// the interactive region in step with what is drawn, and translate pointer
/// activity into state changes.
@MainActor
final class NotchWindowController {

    private let model: AppModel
    private var panel: NotchPanel?
    private var contentView: NotchContentView?

    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var observers: [any NSObjectProtocol] = []
    private var hotKey: GlobalHotKey?

    private var profile: NotchProfile?
    private var geometry: SurfaceGeometry?

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
        guard let profile, let geometry else {
            Log.window.error("no display available; the surface cannot be placed")
            return
        }

        let frame = windowFrame(for: profile, geometry: geometry)
        let panel = NotchPanel(contentRect: frame)

        let container = NotchContentView(frame: CGRect(origin: .zero, size: frame.size))
        container.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: RootView(model: model, geometry: geometry))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        // The hosting view must not paint a background: everything outside the
        // surface shape has to be genuinely transparent.
        hosting.layer?.backgroundColor = .clear
        container.addSubview(hosting)

        container.onHoverChanged = { [weak self] hovering in
            self?.pointerChanged(hovering: hovering)
        }

        panel.contentView = container
        panel.onCancel = { [weak self] in self?.close() }
        panel.orderFrontRegardless()

        self.panel = panel
        self.contentView = container

        model.updateGeometry(profile)
        model.onSurfaceStateChanged = { [weak self] in self?.syncInteractiveRect() }
        syncInteractiveRect()
    }

    // MARK: - Geometry

    private func resolveGeometry() {
        let screens = ScreenBridge.allMetrics()
        guard let preferred = NotchGeometryResolver.preferredScreen(from: screens) else {
            profile = nil
            geometry = nil
            return
        }
        let resolved = NotchGeometryResolver.resolve(preferred)
        profile = resolved
        geometry = SurfaceGeometry(
            notchSize: resolved.rect.size,
            notchCornerRadius: resolved.cornerRadius,
            // Wider than the widest surface, because the resting state draws its
            // thumbnail and track title in the menu bar *outside* the shape. The
            // notch is a hole, so that is the only place they can go.
            windowWidth: min(SurfaceGeometry.expandedWidth + 80, resolved.screenFrame.width)
        )
    }

    /// The window's frame: fixed size, centred on the notch, pinned to the top.
    private func windowFrame(for profile: NotchProfile, geometry: SurfaceGeometry) -> NSRect {
        let width = geometry.windowWidth
        let height = geometry.windowHeight
        var x = profile.rect.midX - width / 2
        // Keep it on screen when the notch sits near a display edge in a
        // multi-display arrangement.
        x = max(profile.screenFrame.minX, min(x, profile.screenFrame.maxX - width))
        return NSRect(x: x, y: profile.rect.maxY - height, width: width, height: height)
    }

    /// Keeps the hit-test and hover region in step with what is drawn.
    ///
    /// Called on every state change. This is the counterpart to the fixed
    /// window: SwiftUI knows what it drew, but AppKit does not, so the rect is
    /// published to the content view explicitly.
    private func syncInteractiveRect() {
        guard let geometry, let contentView else { return }
        contentView.interactiveRect = geometry.appKitRect(
            for: model.surfaceState,
            windowHeight: geometry.windowHeight
        )
        contentView.hoverRect = geometry.hoverRect(
            for: model.surfaceState,
            windowHeight: geometry.windowHeight
        )
    }

    /// Re-measures after a display change and moves the window.
    ///
    /// Screen parameters change on attaching or detaching a display, changing
    /// resolution or scaling, rotation, and lid open/close. Several of which
    /// change the notch's size *in points* with no hardware change at all.
    private func handleScreenChange() {
        let hadProfile = profile != nil
        resolveGeometry()

        guard let profile, let geometry else {
            panel?.orderOut(nil)
            model.updateGeometry(nil)
            return
        }
        if !hadProfile { panel?.orderFrontRegardless() }

        panel?.setFrame(windowFrame(for: profile, geometry: geometry), display: true)
        if let panel, let hosting = panel.contentView?.subviews.first as? NSHostingView<RootView> {
            hosting.rootView = RootView(model: model, geometry: geometry)
        }
        model.updateGeometry(profile)
        syncInteractiveRect()
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

        // Waking can reconfigure displays without posting a parameter change,
        // leaving the surface on a display that no longer exists.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleScreenChange() }
        })
    }

    // MARK: - Interaction

    private func installHotKey() {
        hotKey = GlobalHotKey { [weak self] in self?.toggle() }
        hotKey?.register()
    }

    /// Translates pointer presence into surface state.
    ///
    /// The sequence is what makes hover feel instantaneous:
    ///
    /// 1. On entry, go to `peek` **immediately**, with no delay whatsoever.
    ///    Something visibly happens the moment the pointer arrives.
    /// 2. After a short dwell, commit to `expanded`. Because the surface has
    ///    already responded, this reads as the second half of one gesture
    ///    rather than as a delayed reaction.
    /// 3. On exit, close after a short grace period, so crossing a gap between
    ///    controls or overshooting the edge by a few pixels does not dismiss it.
    private func pointerChanged(hovering: Bool) {
        model.setHovering(hovering)

        if hovering {
            closeTask?.cancel()
            closeTask = nil
            guard model.preferences.activationStyle == .hover else { return }
            guard model.surfaceState == .collapsed else { return }

            if model.preferences.hoverDwell <= 0 {
                present(.expanded)
                return
            }
            present(.peek)

            openTask?.cancel()
            openTask = Task { [weak self] in
                guard let self else { return }
                let dwell = self.model.preferences.hoverDwell
                if dwell > 0 { try? await Task.sleep(for: .seconds(dwell)) }
                guard !Task.isCancelled, self.model.isHovering else { return }
                guard self.model.surfaceState == .peek else { return }
                self.present(.expanded)
            }
        } else {
            openTask?.cancel()
            openTask = nil

            // Peek follows the pointer exactly: it is feedback, not a state to
            // linger in.
            if model.surfaceState == .peek {
                present(.collapsed)
                return
            }
            guard model.surfaceState == .expanded else { return }
            guard model.preferences.activationStyle == .hover else { return }

            closeTask?.cancel()
            closeTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled, let self, !self.model.isHovering else { return }
                self.present(.collapsed)
            }
        }
    }

    private func present(_ state: SurfaceState) {
        model.present(state)
        // The drawn shape changes with the state, so the interactive region has
        // to follow it. Done immediately rather than after the animation: the
        // target rect is where the pointer will be interacting, and waiting
        // would leave a window where clicks land nowhere.
        syncInteractiveRect()
    }

    func toggle() {
        openTask?.cancel()
        closeTask?.cancel()
        present(model.surfaceState.isOpen ? .collapsed : .expanded)
    }

    func close() {
        openTask?.cancel()
        closeTask?.cancel()
        if model.surfaceState.hud != nil {
            model.dismissHUD()
        }
        present(.collapsed)
    }

    func tearDown() {
        openTask?.cancel()
        closeTask?.cancel()
        hotKey?.unregister()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        panel?.orderOut(nil)
    }
}
