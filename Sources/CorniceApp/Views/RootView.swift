import SwiftUI
import CorniceKit

/// The whole interface: one surface that morphs between states.
///
/// The central idea is that there is exactly **one** shape on screen at all
/// times, and every state change animates its size, its corner radii, and what
/// is drawn inside it. Nothing is inserted or removed; nothing is a separate
/// window; the window itself never resizes.
///
/// That is what separates this from feeling like a popover that appears. A
/// popover appears — an island *grows*.
struct RootView: View {
    @Bindable var model: AppModel
    let geometry: SurfaceGeometry

    /// Drives the scrubber, the timers, and the visualiser from one place.
    ///
    /// One timer for the whole UI rather than one per component: three separate
    /// 60 Hz timers would wake the main thread three times as often for the
    /// same result. It only runs while the surface is showing something that
    /// moves.
    @State private var frameTimer: Timer?
    @State private var tick = 0

    private var state: SurfaceState { model.surfaceState }

    var body: some View {
        let size = geometry.size(for: state)

        ZStack(alignment: .top) {
            surfaceBackground(size: size)

            // All three layouts are built at all times and cross-faded.
            //
            // Switching between them with a `switch` meant SwiftUI tore down
            // one tree and constructed another *during* the expand animation —
            // building the player, decoding artwork, laying out the transport —
            // which is exactly when there is no spare frame budget. That is
            // what made opening feel like it hitched. Keeping the tree stable
            // costs a little idle layout and removes the stall entirely.
            ZStack(alignment: .top) {
                // Each layer is pinned to the *surface's* size, not to the
                // stack's. Without this the stack sizes to its tallest child —
                // the expanded panel — and any layer using `maxHeight:
                // .infinity` centres itself against that instead, which put the
                // device announcement's content well below the visible area.
                CollapsedContentView(model: model, geometry: geometry)
                    .frame(width: size.width, height: size.height)
                    .opacity(state == .collapsed ? 1 : 0)

                PeekContentView(model: model, geometry: geometry, tick: tick)
                    .frame(width: size.width, height: size.height)
                    .opacity(state == .peek ? 1 : 0)

                DeviceActivityView(model: model, geometry: geometry)
                    .frame(width: size.width, height: size.height)
                    .opacity(state == .activity ? 1 : 0)

                ExpandedContentView(model: model, geometry: geometry, tick: tick)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .opacity(state == .expanded ? 1 : 0)
                    // Scaled very slightly while closed so it arrives with the
                    // surface rather than simply fading in on top of it.
                    .scaleEffect(state == .expanded ? 1 : 0.97, anchor: .top)
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(surfaceShape)
            .allowsHitTesting(state == .expanded)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(animation(for: state), value: state)
        .animation(Theme.Motion.contentSwap, value: model.activeModule)
        // The resting and peek states sit against the physical notch, which is
        // an unlit region of the panel, so they are always dark regardless of
        // the system appearance.
        .environment(\.colorScheme, .dark)
        .onAppear { startFrameTimer() }
        .onDisappear { frameTimer?.invalidate() }
        .onChange(of: needsFrameTimer) { _, needed in
            needed ? startFrameTimer() : stopFrameTimer()
        }
        // The tick rate differs between states, so the timer is rebuilt on a
        // transition rather than left running at the wrong cadence.
        .onChange(of: state) { _, _ in
            if needsFrameTimer { startFrameTimer() } else { stopFrameTimer() }
        }
    }

    private var surfaceShape: SurfaceShape {
        SurfaceShape(
            bottomRadius: geometry.bottomRadius(for: state),
            flareRadius: geometry.flareRadius(for: state)
        )
    }

    /// The surface itself: black, with the artwork bleeding through it.
    private func surfaceBackground(size: CGSize) -> some View {
        surfaceShape
            .fill(Color.black)
            .overlay {
                if let tint = model.artworkTint, state == .peek || state == .expanded {
                    // Artwork colour, layered rather than blended. An earlier
                    // version used `.plusLighter`, which forces an offscreen
                    // compositing pass every frame of the morph — expensive for
                    // something a plain gradient renders identically.
                    surfaceShape
                        .fill(
                            LinearGradient(
                                colors: [
                                    tint.opacity(0.50),
                                    tint.opacity(0.20),
                                    tint.opacity(0.06),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        // A second, tighter wash at the top edge, so the colour
                        // reads as light spilling from the artwork rather than
                        // as a flat tinted panel.
                        .overlay(alignment: .topLeading) {
                            RadialGradient(
                                colors: [tint.opacity(0.42), .clear],
                                center: .topLeading,
                                startRadius: 0,
                                endRadius: size.width * 0.62
                            )
                            .clipShape(surfaceShape)
                        }
                }
            }
            .overlay {
                surfaceShape
                    .strokeBorder(
                        Color.white.opacity(state == .collapsed ? 0 : 0.10),
                        lineWidth: 1
                    )
            }
            // No shadow while resting: a drop shadow under a black shape
            // sitting in a black cut-out just darkens the bezel around it.
            .shadow(
                color: .black.opacity(state == .collapsed ? 0 : 0.5),
                radius: state == .collapsed ? 0 : 22,
                y: state == .collapsed ? 0 : 10
            )
            .frame(width: size.width, height: size.height)
    }

    private func animation(for state: SurfaceState) -> Animation {
        switch state {
        case .collapsed: Theme.Motion.collapse
        case .peek, .activity: Theme.Motion.peek
        case .expanded: Theme.Motion.expand
        }
    }

    /// Whether anything on screen actually needs per-frame updates.
    ///
    /// Originally this returned true whenever music was playing, which meant a
    /// *collapsed* surface — showing only album art and a title, neither of
    /// which changes between tracks — repainted continuously. Profiling put the
    /// cost at several percent of a core for nothing visible. Each clause below
    /// corresponds to something that genuinely moves.
    private var needsFrameTimer: Bool {
        let isPlaying = model.media?.state.isPlaying == true
        // The spectrum moves wherever it is drawn.
        if model.preferences.audioVisualizerEnabled && isPlaying { return true }
        // Countdowns move.
        if model.timers.anyRunning { return true }
        // The scrubber moves, but only when it is on screen.
        if state.isOpen && isPlaying { return true }
        return false
    }

    private func startFrameTimer() {
        frameTimer?.invalidate()
        guard needsFrameTimer else { return }
        // Display rate while open, where the scrubber and spectrum are large
        // and motion is scrutinised. While collapsed the only moving things are
        // a 26-point spectrum and a countdown, so 10 Hz is indistinguishable
        // and costs a sixth as much.
        let interval = state.isOpen ? 1.0 / 60.0 : 1.0 / 10.0
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated {
                model.sampleLevels()
                model.tickTimers()
                tick &+= 1
            }
        }
        // Common mode so it keeps running while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func stopFrameTimer() {
        frameTimer?.invalidate()
        frameTimer = nil
    }
}
