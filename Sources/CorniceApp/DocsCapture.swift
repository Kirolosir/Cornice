import AppKit
import SwiftUI
import CorniceKit

/// Renders the interface to PNG files for the README.
///
/// Run with `cornice --capture-docs <directory>`.
///
/// Uses `ImageRenderer` against the real view hierarchy fed by
/// `PreviewServices`, rather than screen capture: the images are deterministic,
/// reproducible on any machine, regenerable in one command when the design
/// changes, and produced without granting anything Screen Recording permission.
/// They are the actual views, not mockups.
@MainActor
enum DocsCapture {

    private static let scale: CGFloat = 2

    static func run(outputDirectory: String) async -> Never {
        let directory = URL(fileURLWithPath: outputDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let model = AppModel(services: PreviewServices.container())
        await model.start()

        // A 14-inch MacBook Pro at default scaling, so the images are
        // representative rather than tied to whichever machine rendered them.
        let screen = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            backingScaleFactor: 2,
            safeAreaTop: 38,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 944, width: 651, height: 38),
            auxiliaryTopRightArea: CGRect(x: 861, y: 944, width: 651, height: 38),
            isBuiltIn: true,
            localizedName: "Built-in Retina Display"
        )
        let profile = NotchGeometryResolver.resolve(screen)
        model.updateGeometry(profile)

        let geometry = SurfaceGeometry(
            notchSize: profile.rect.size,
            notchCornerRadius: profile.cornerRadius,
            windowWidth: SurfaceGeometry.expandedWidth + 80
        )

        model.refreshNow("media")
        model.refreshNow("telemetry")
        try? await Task.sleep(for: .seconds(2))
        for _ in 0..<40 {
            model.refreshNow("telemetry")
            try? await Task.sleep(for: .milliseconds(12))
        }
        model.addTimer(minutes: 25)
        model.addTimer(minutes: 5)
        try? await Task.sleep(for: .milliseconds(600))

        for (state, module, name) in [
            (SurfaceState.collapsed, ModuleKind.media, "collapsed"),
            (.peek, .media, "peek"),
            (.expanded, .media, "player"),
            (.expanded, .timers, "timers"),
            (.expanded, .stats, "stats"),
        ] {
            model.select(module: module)
            model.present(state)
            try? await Task.sleep(for: .milliseconds(420))
            capture(model: model, geometry: geometry, name: name, to: directory)
        }

        // The wireless-device announcement, which is otherwise only visible for
        // three seconds when something actually connects.
        model.present(.collapsed)
        try? await Task.sleep(for: .milliseconds(200))
        model.showDeviceActivity(
            AppModel.DeviceActivity(name: "AirPods Pro", symbol: "airpods.pro", batteryLevel: 0.78)
        )
        try? await Task.sleep(for: .seconds(1.4))
        capture(model: model, geometry: geometry, name: "airpods", to: directory)

        // Every system HUD, at its measured size. These are otherwise only on
        // screen for a second or two when the machine does something.
        model.present(.collapsed)

        // The timer HUD reads its countdown from the board, so the gallery entry
        // has to name a timer that is actually on it.
        let liveTimer = model.timers.entries.first
        for content in Self.hudGallery(timer: liveTimer) {
            model.presentHUD(content)
            try? await Task.sleep(for: .milliseconds(420))
            capture(model: model, geometry: geometry, name: "hud-\(content.kind.rawValue)", to: directory)
            model.dismissHUD()
            try? await Task.sleep(for: .milliseconds(360))
        }

        print("Wrote documentation images to \(directory.path)")
        exit(0)
    }

    /// One of each, with representative values.
    ///
    /// The numbers here are the design's own specimen values rather than live
    /// readings: these images document the layout, and a screenshot of whatever
    /// the rendering machine's battery happened to be at is not a specification.
    private static func hudGallery(timer: TimerEntry?) -> [HUDContent] { [
        .noInternet,
        .filesReceived(files: ["Debug Report.txt", "Debug Image.png"]),
        .timerRunning(
            id: timer?.id ?? UUID(),
            label: "Timer",
            isRunning: timer?.isRunning ?? true,
            isFinished: false
        ),
        .charging(level: 0.67),
        .batteryLow(level: 0.10),
        .fullBattery,
        .vpn(name: "VPN · utun4", since: Date().addingTimeInterval(-515)),
        .download(name: "ReallyVeryExtremelyImportBigNameForFile.mov", progress: 0.6, bytesPerSecond: 13_421_772),
        .doNotDisturb,
        .handoff,
    ] }

    private static func capture(
        model: AppModel,
        geometry: SurfaceGeometry,
        name: String,
        to directory: URL
    ) {
        let surfaceSize = geometry.size(for: model.surfaceState)
        // Enough room around the surface for its shadow, and enough above to
        // show that it is attached to the top edge of the screen. A floor on the
        // width because the resting state draws its thumbnail and title
        // *outside* the surface, in the menu-bar margins. Crop to the shape and
        // the only two things it shows disappear.
        let canvas = CGSize(
            width: max(surfaceSize.width + 120, 520),
            height: surfaceSize.height + 56
        )

        let content = ZStack(alignment: .top) {
            // A desktop-ish backdrop so a black surface is visible at all.
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.16, blue: 0.19),
                         Color(red: 0.10, green: 0.10, blue: 0.13)],
                startPoint: .top, endPoint: .bottom
            )
            RootView(model: model, geometry: geometry)
                .frame(width: geometry.windowWidth, height: geometry.windowHeight)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .top)
        .clipped()
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        renderer.isOpaque = true

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            print("could not render \(name)")
            return
        }

        try? png.write(to: directory.appendingPathComponent("\(name).png"))
        print("  \(name).png  \(Int(canvas.width))×\(Int(canvas.height))")
    }
}
