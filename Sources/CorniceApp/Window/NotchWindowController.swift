import AppKit
import SwiftUI
import CorniceKit

/// Place the panel over the notch and handle pointer and screen changes. SwiftUI animates
/// inside the fixed window.
@MainActor
final class NotchWindowController {

    private let model: AppModel
    private var panel: NotchPanel?
    private var contentView: NotchContentView?

    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var observers: [any NSObjectProtocol] = []
    private var workspaceObservers: [any NSObjectProtocol] = []
    private var mouseMonitors: [Any] = []
    private var hotKey: GlobalHotKey?
    private var openedExplicitly = false

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

        buildPanel(frame: windowFrame(for: profile, geometry: geometry), geometry: geometry, show: true)
        model.updateGeometry(profile)
    }

    @discardableResult
    private func buildPanel(frame: NSRect, geometry: SurfaceGeometry, show: Bool) -> NotchPanel {
        let panel = NotchPanel(contentRect: frame)

        let container = NotchContentView(frame: CGRect(origin: .zero, size: frame.size))
        container.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: RootView(model: model, geometry: geometry))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        // Everything outside the panel shape needs to stay transparent.
        hosting.layer?.backgroundColor = .clear
        container.addSubview(hosting)

        container.onHoverChanged = { [weak self] hovering in
            self?.pointerChanged(hovering: hovering)
        }

        panel.contentView = container
        panel.onCancel = { [weak self] in self?.close() }
        if show { panel.orderFrontRegardless() }

        self.panel = panel
        self.contentView = container

        model.onSurfaceStateChanged = { [weak self] in self?.syncInteractiveRect() }
        model.onPopoverClosed = { [weak self] in self?.contentView?.reevaluateHover() }
        if show { observeExplicitDismissal(of: panel) }
        syncInteractiveRect()
        return panel
    }

    // The interaction probe uses an offscreen panel without registering a hotkey or
    // watching clicks in the user's other apps.
    func installProbePanel() -> NotchPanel {
        let geometry = SurfaceGeometry(notchSize: CGSize(width: 210, height: 32), notchCornerRadius: 8,
                                       windowWidth: SurfaceGeometry.expandedWidth + 80)
        self.geometry = geometry
        return buildPanel(frame: NSRect(x: -10_000, y: -10_000, width: geometry.windowWidth,
                                       height: geometry.windowHeight), geometry: geometry, show: false)
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
            // Leave room beside the notch for the resting artwork and song title.
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

    /// Update AppKit's interactive area whenever the panel changes state.
    private func syncInteractiveRect() {
        guard let geometry, let contentView else { return }
        if !model.surfaceState.isOpen {
            openedExplicitly = false
            if panel?.isKeyWindow == true { panel?.resignKey() }
        }
        contentView.interactiveRect = model.surfaceState.hud != nil && model.hudContent?.isInteractive != true ? .zero : geometry.appKitRect(
            for: model.surfaceState,
            windowHeight: geometry.windowHeight
        )
        contentView.hoverRect = geometry.hoverRect(
            for: model.surfaceState,
            windowHeight: geometry.windowHeight
        )
    }

    /// Measure again after display changes. Resolution and scaling can change the notch's
    /// size in points without changing the hardware.
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
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
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

    private func observeExplicitDismissal(of panel: NotchPanel) {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            Task { @MainActor in self?.handleOutsideClick() }
        }) { mouseMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.window === self.panel, let contentView = self.contentView,
                   contentView.interactiveRect.contains(contentView.convert(event.locationInWindow, from: nil)) {
                    return
                }
                self.handleOutsideClick()
            }
            return event
        }) { mouseMonitors.append(monitor) }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            // A popover takes key focus too. Let SwiftUI finish presenting it before
            // deciding whether focus moved out of Cornice's panel.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.panel?.isKeyWindow != true else { return }
                self.handleOutsideClick()
            }
        })
    }

    func handleOutsideClick() {
        guard openedExplicitly, model.surfaceState == .expanded, !model.isPresentingPopover else { return }
        close()
    }

    /// Peek immediately, then open after the hover delay. On exit, wait briefly before
    /// closing so a small pointer overshoot doesn't dismiss the panel.
    func pointerChanged(hovering: Bool) {
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
            guard model.surfaceState == .expanded, !model.isPresentingPopover else { return }
            guard !openedExplicitly else { return }
            guard model.preferences.activationStyle == .hover else { return }

            closeTask?.cancel()
            closeTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled, let self, !self.openedExplicitly,
                      !self.model.isHovering, !self.model.isPresentingPopover else { return }
                self.present(.collapsed)
            }
        }
    }

    private func present(_ state: SurfaceState) {
        model.present(state)
        // Update the clickable area straight away so the new controls can receive input
        // during the animation.
        syncInteractiveRect()
    }

    func toggle() {
        if model.surfaceState.isOpen { close() }
        else { open() }
    }

    func open() {
        openTask?.cancel()
        closeTask?.cancel()
        // Selecting a panel should never close one that is already open.
        openedExplicitly = true
        present(.expanded)
        panel?.makeKeyAndOrderFront(nil)
    }

    func close() {
        openTask?.cancel()
        closeTask?.cancel()
        openedExplicitly = false
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
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors.removeAll()
        panel?.orderOut(nil)
    }
}
