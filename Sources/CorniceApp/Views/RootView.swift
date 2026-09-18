import SwiftUI
import CorniceKit

/// The whole interface: one surface that changes size.
///
/// There is exactly one object on screen. It is never a window that appears near
/// the notch — it is the notch becoming larger and then smaller again. So the
/// top edge never moves, the outline is interpolated rather than swapped, and
/// the artwork travels rather than cross-fading between copies.
struct RootView: View {
    @Bindable var model: AppModel
    let geometry: SurfaceGeometry

    /// One timer for the whole UI rather than one per component, running only
    /// while something on screen actually moves.
    @State private var frameTimer: Timer?
    /// Shared with the few views that redraw per frame. The root itself never
    /// reads it, which is what keeps a moving scrubber from re-laying out the
    /// whole surface.
    @State private var clock = FrameClock()

    @Environment(\.colorScheme) private var systemScheme

    private var state: SurfaceState { model.surfaceState }

    /// Light treatment applies to the expanded panel only: the other states sit
    /// flush against an unlit cut-out, where anything but black shows a seam.
    private var scheme: ColorScheme { state == .expanded ? systemScheme : .dark }
    private var ink: Theme.Ink { .of(scheme) }

    var body: some View {
        let size = geometry.size(for: state)
        let artwork = ArtworkPlacement.forState(state, geometry: geometry)

        ZStack(alignment: .top) {
            // The surface and everything clipped inside it.
            ZStack(alignment: .top) {
                surfaceBackground(size: size)

                // Built at all times and cross-faded. Switching with a `switch`
                // tore down one tree and built another *during* the expand
                // animation, which is exactly when there is no spare frame
                // budget — and is what made opening feel like it hitched.
                //
                // The artwork is the exception: it sits outside this stack so it
                // survives the cross-fade and can travel.
                ZStack(alignment: .top) {
                    PeekContentView(model: model, geometry: geometry)
                        .frame(width: size.width, height: size.height)
                        .opacity(state == .peek ? 1 : 0)

                    DeviceActivityView(model: model, geometry: geometry)
                        .frame(width: size.width, height: size.height)
                        .opacity(state == .activity ? 1 : 0)

                    ExpandedContentView(model: model, geometry: geometry, clock: clock)
                        .frame(width: size.width, height: size.height, alignment: .top)
                        .opacity(state == .expanded ? 1 : 0)

                    // Built on demand rather than kept alive: a HUD is not part
                    // of the morph, and most of the time there is nothing to draw.
                    if let hud = model.hudContent {
                        HUDView(content: hud, geometry: geometry, model: model, clock: clock)
                            .frame(width: size.width, height: size.height, alignment: .topLeading)
                            .opacity(state.hud != nil ? 1 : 0)
                            .id(hud.kind)
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(surfaceShape)
                .allowsHitTesting(state == .expanded || isInteractiveHUD)

                // The hole, painted back in above everything else, so a light
                // panel reads as a sheet with a bite taken out of it.
                if scheme == .light && state == .expanded {
                    NotchHoleShape(cornerRadius: geometry.notchCornerRadius)
                        .fill(Theme.Palette.notch)
                        .frame(width: geometry.notchSize.width, height: geometry.notchSize.height)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)

            // Content outside the surface, in the menu-bar margins. At rest the
            // surface is exactly the notch, so this is the only place it fits.
            RestingMarginView(model: model, geometry: geometry)
                .frame(width: geometry.windowWidth, height: geometry.notchSize.height, alignment: .top)
                .opacity(state == .collapsed ? 1 : 0)
                .allowsHitTesting(false)

            // One view for every state, positioned in window coordinates rather
            // than inside any layout, so SwiftUI interpolates its frame along the
            // same spring as the outline.
            if model.showsArtwork {
                // The pulse reads the analyser inside its own body, so a beat
                // invalidates the artwork and nothing else.
                PulsingArtwork(
                    model: model,
                    size: artwork.size,
                    cornerRadius: artwork.cornerRadius
                )
                .shadow(
                    color: .black.opacity(0.4),
                    radius: state == .expanded ? 5 : 1.5,
                    y: state == .expanded ? 3 : 1
                )
                .offset(
                    x: artwork.x + artwork.size / 2 - geometry.windowWidth / 2,
                    y: artwork.y
                )
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(animation(for: state), value: state)
        .animation(Theme.Motion.contentSwap, value: model.activeModule)
        .environment(\.colorScheme, scheme)
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

    /// A HUD that waits to be dealt with — an alert with buttons, a ringing
    /// timer — has to accept clicks. One that retracts on its own must not, or
    /// it swallows a click meant for the desktop on its way out.
    private var isInteractiveHUD: Bool {
        guard let kind = state.hud else { return false }
        return kind.dismissAfter == nil
    }

    private var surfaceShape: SurfaceShape {
        SurfaceShape(
            bottomRadius: geometry.bottomRadius(for: state),
            flareRadius: geometry.flareRadius(for: state)
        )
    }

    /// Never at rest, where the surface must be indistinguishable from the notch
    /// glass, and never on states that are not about the music.
    private var showsTint: Bool {
        guard model.artworkTint != nil else { return false }
        switch state {
        case .collapsed, .activity, .hud: return false
        case .peek: return true
        case .expanded: return model.activeModule == .media
        }
    }

    /// The surface itself.
    private func surfaceBackground(size: CGSize) -> some View {
        surfaceShape
            .fill(Theme.Palette.panel(scheme))
            .overlay {
                if let tint = model.artworkTint, showsTint {
                    tintLayers(tint: tint, size: size)
                        .clipShape(surfaceShape)
                }
            }
            // Stops a black panel dissolving into a dark desktop. Absent at
            // rest, where it would draw a line across the bottom of the cut-out.
            .overlay {
                if state != .collapsed {
                    // Expanded to the full surface *before* clipping: clipping a
                    // 0.5pt-tall view against the surface path evaluates that path
                    // in a 0.5pt rect, which let the hairline escape and draw
                    // straight across the desktop.
                    Rectangle()
                        .fill(ink.hairline)
                        .frame(height: 0.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .clipShape(surfaceShape)
                }
            }
            // No shadow while resting: under a black shape in a black cut-out it
            // only darkens the bezel.
            .shadow(
                color: .black.opacity(state == .collapsed ? 0 : 0.5),
                radius: state == .collapsed ? 0 : 22,
                y: state == .collapsed ? 0 : 10
            )
            .frame(width: size.width, height: size.height)
    }

    /// Artwork colour, layered rather than blended.
    ///
    /// A vertical wash in the cover's strongest colour, then one soft pool per
    /// accent in the corner that accent came from — so a sleeve that is amber at
    /// the top and green at the bottom paints a surface that is amber at the top
    /// and green at the bottom. Averaging the cover to a single colour is what
    /// made every album produce the same generic tint.
    ///
    /// The accents are clamped before they get here, which is what keeps white
    /// text above 4.5:1 however lurid the cover.
    private func tintLayers(tint: Color, size: CGSize) -> some View {
        let strength = model.preferences.tintStrength * (scheme == .light ? 0.55 : 1)
        let reach = max(size.width, size.height)

        return ZStack {
            LinearGradient(
                stops: [
                    .init(color: tint.opacity(0.22 * strength), location: 0),
                    .init(color: tint.opacity(0.08 * strength), location: 0.46),
                    .init(color: tint.opacity(0), location: 0.82),
                    .init(color: tint.opacity(0), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            ForEach(Array(model.artworkAccents.enumerated()), id: \.offset) { _, accent in
                RadialGradient(
                    stops: [
                        .init(color: accent.color.opacity(0.26 * strength * accent.weight), location: 0),
                        .init(color: accent.color.opacity(0.10 * strength * accent.weight), location: 0.45),
                        .init(color: accent.color.opacity(0), location: 1),
                    ],
                    center: accent.position,
                    startRadius: 0,
                    endRadius: reach * 0.75
                )
            }
        }
        .allowsHitTesting(false)
        .animation(Theme.Motion.telemetry, value: model.artworkAccents)
    }

    private func animation(for state: SurfaceState) -> Animation {
        switch state {
        case .collapsed: Theme.Motion.collapse
        case .peek, .activity: Theme.Motion.peek
        case .expanded: Theme.Motion.expand
        // A HUD arrives the way the panel does: it is the same object growing,
        // and it is usually growing about as far.
        case .hud: Theme.Motion.expand
        }
    }

    /// Whether anything on screen actually needs per-frame updates.
    ///
    /// Each clause corresponds to something that genuinely moves. Returning true
    /// whenever music played cost several percent of a core for nothing visible.
    private var needsFrameTimer: Bool {
        // Countdowns move wherever they are drawn, including while resting.
        if model.timers.anyRunning { return true }

        // The analyser is live wherever its indicator is drawn. This used to
        // require a scriptable player to be reporting `playing`, which left the
        // bars frozen through anything the tap could hear but Spotify could not
        // see — a browser tab, most obviously.
        if model.isVisualizerLive {
            if state == .peek || state == .expanded { return true }
            // Only when there is a track to indicate. Without this the timer
            // ran at rest forever on a machine playing nothing at all.
            if state == .collapsed,
               model.preferences.idleDisplay == .artworkAndSpectrum,
               model.media?.hasTrack == true {
                return true
            }
        }

        // The scrubber moves, but only when it is on screen.
        if state.isOpen && model.media?.state.isPlaying == true { return true }
        return false
    }

    private func startFrameTimer() {
        frameTimer?.invalidate()
        guard needsFrameTimer else { return }
        // Display rate while open. Otherwise the only moving things are a few
        // 13-point bars and a countdown, where 10 Hz is indistinguishable.
        let interval = state.isOpen ? 1.0 / 60.0 : 1.0 / 10.0
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated {
                model.sampleLevels()
                model.tickTimers()
                clock.advance()
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
