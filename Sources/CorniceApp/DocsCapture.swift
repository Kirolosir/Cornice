import AppKit
import SwiftUI
import CorniceKit

/// Renders the interface to PNG files for the README.
///
/// Run with `cornice --capture-docs <directory>`.
///
/// Uses `ImageRenderer` against the real view hierarchy fed by
/// `PreviewServices`, rather than screen capture. That means the images are
/// deterministic, reproducible on any machine, regenerable in one command when
/// the design changes, and produced without granting anything Screen Recording
/// permission. They are the actual views — not mockups — drawn with scripted
/// data.
@MainActor
enum DocsCapture {

    /// Rendered at 2× so the images are crisp on the Retina displays most
    /// people will read the README on.
    private static let scale: CGFloat = 2

    static func run(outputDirectory: String) async -> Never {
        let directory = URL(fileURLWithPath: outputDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let model = AppModel(services: PreviewServices.container())
        await model.start()

        // A notch profile matching a 14" MacBook Pro at default scaling, so the
        // documentation images are representative rather than tied to whichever
        // machine generated them.
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
        model.updateGeometry(NotchGeometryResolver.resolve(screen))

        // Let every module's first refresh land.
        for module in ModuleKind.allCases {
            model.refreshNow(module)
        }
        try? await Task.sleep(for: .seconds(2))
        // Populate the sparklines with enough points to look like a real session.
        for _ in 0..<40 {
            model.refreshNow(.telemetry)
            try? await Task.sleep(for: .milliseconds(12))
        }
        try? await Task.sleep(for: .milliseconds(400))

        model.collapse()
        try? await Task.sleep(for: .milliseconds(200))
        // Sized to the real collapsed window, not to an arbitrary canvas: the
        // surface fills whatever it is given, so a larger frame would render a
        // black slab rather than what the app actually shows.
        let collapsedContent = model.collapsedContent
        capture(
            model: model,
            name: "collapsed",
            size: CGSize(
                width: (model.notchProfile?.rect.width ?? 210) + collapsedContent.wingWidth * 2,
                height: (model.notchProfile?.rect.height ?? 38)
                    + (collapsedContent.isEmpty ? 0 : Theme.Metrics.wingDrop)
            ),
            to: directory,
            drawsNotch: false
        )

        model.expand()
        for (module, name) in [
            (ModuleKind.repository, "repository"),
            (.servers, "servers"),
            (.github, "github"),
            (.telemetry, "telemetry"),
            (.containers, "containers"),
            (.commands, "commands"),
            (.focus, "focus"),
        ] {
            model.select(module: module)
            try? await Task.sleep(for: .milliseconds(450))
            capture(
                model: model,
                name: name,
                size: CGSize(
                    width: Theme.Metrics.panelWidth,
                    height: ExpandedMetrics.height(for: module) + 38 + Theme.Metrics.panelDrop
                ),
                to: directory
            )
        }

        // Light mode, to show the panel adapts.
        model.select(module: .repository)
        try? await Task.sleep(for: .milliseconds(400))
        capture(
            model: model,
            name: "repository-light",
            size: CGSize(
                width: Theme.Metrics.panelWidth,
                height: ExpandedMetrics.height(for: .repository) + 38 + Theme.Metrics.panelDrop
            ),
            to: directory,
            colorScheme: .light
        )

        print("Wrote documentation images to \(directory.path)")
        exit(0)
    }

    private static func capture(
        model: AppModel,
        name: String,
        size: CGSize,
        to directory: URL,
        colorScheme: ColorScheme = .dark,
        drawsNotch: Bool = true
    ) {
        // A backdrop that includes a menu-bar strip and the notch cut-out, so
        // the images show what the surface is actually attached to. Without it
        // the panel reads as a floating window, which is the opposite of the
        // point.
        let backdrop = colorScheme == .dark
            ? Color(red: 0.13, green: 0.13, blue: 0.15)
            : Color(red: 0.86, green: 0.86, blue: 0.88)
        let notchWidth = model.notchProfile?.rect.width ?? 210
        let notchHeight = model.notchProfile?.rect.height ?? 38
        let notchRadius = model.notchProfile?.cornerRadius ?? 10

        let content = ZStack(alignment: .top) {
            backdrop

            // The physical notch. Skipped for the collapsed shot, where the
            // surface is itself covering the notch.
            if drawsNotch {
                NotchShape(bottomRadius: notchRadius, flareRadius: 0)
                    .fill(Color.black)
                    .frame(width: notchWidth, height: notchHeight)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            RootView(model: model)
                .frame(width: size.width, height: size.height)
        }
        .frame(width: size.width + 64, height: size.height + (drawsNotch ? 24 : 40))
        .environment(\.colorScheme, colorScheme)

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

        let url = directory.appendingPathComponent("\(name).png")
        try? png.write(to: url)
        print("  \(name).png  \(Int(size.width))×\(Int(size.height))")
    }
}
