import XCTest
@testable import CorniceKit

/// The display configurations here are the ones that actually break notch
/// placement. They cannot be reproduced by running on a developer's machine
/// (you would need four different MacBooks, an external monitor, and a
/// mirrored display), which is exactly why the resolver takes a value type.
final class NotchGeometryTests: XCTestCase {

    /// Captured from a MacBook Air (Mac15,12) running a scaled 1710×1112 point
    /// mode. These are real numbers read from `NSScreen`, not invented ones.
    private func macBookAirScaled() -> ScreenMetrics {
        ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1710, height: 1112),
            visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1072),
            backingScaleFactor: 2,
            safeAreaTop: 38,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 1074, width: 751, height: 38),
            auxiliaryTopRightArea: CGRect(x: 960, y: 1074, width: 750, height: 38),
            isBuiltIn: true,
            localizedName: "Built-in Retina Display"
        )
    }

    func testMeasuresNotchFromAuxiliaryAreas() {
        let profile = NotchGeometryResolver.resolve(macBookAirScaled())

        XCTAssertEqual(profile.source, .measured)
        XCTAssertTrue(profile.hasPhysicalNotch)
        // The gap between the two auxiliary strips: 960 - 751.
        XCTAssertEqual(profile.rect.width, 209)
        XCTAssertEqual(profile.rect.height, 38)
        XCTAssertEqual(profile.rect.minX, 751)
        // Flush with the top edge: maxY of the rect equals maxY of the screen.
        XCTAssertEqual(profile.rect.maxY, 1112)
    }

    /// The central claim of the design: the same hardware reports a different
    /// notch size in points under a different scaled resolution, so any
    /// hardcoded per-model point size is wrong for most users. Here the same
    /// machine is described at its default 1470-point mode.
    func testSameHardwareAtDifferentScalingYieldsDifferentPointSize() {
        let scaled = NotchGeometryResolver.resolve(macBookAirScaled())

        let defaultMode = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
            visibleFrame: CGRect(x: 0, y: 0, width: 1470, height: 918),
            backingScaleFactor: 2,
            safeAreaTop: 33,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 923, width: 645, height: 33),
            auxiliaryTopRightArea: CGRect(x: 825, y: 923, width: 645, height: 33),
            isBuiltIn: true,
            localizedName: "Built-in Retina Display"
        )
        let unscaled = NotchGeometryResolver.resolve(defaultMode)

        XCTAssertNotEqual(scaled.rect.width, unscaled.rect.width)
        XCTAssertEqual(unscaled.rect.width, 180)
        // Width as a fraction of the display is near-invariant, which is why it
        // is the only figure compared across machines.
        XCTAssertEqual(scaled.widthFraction, unscaled.widthFraction, accuracy: 0.01)
    }

    /// An external monitor reports no safe-area inset and no auxiliary areas.
    func testExternalDisplayFallsBackToCentredRegion() {
        let external = ScreenMetrics(
            frame: CGRect(x: 1710, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 1710, y: 0, width: 2560, height: 1415),
            backingScaleFactor: 1,
            safeAreaTop: 0,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil,
            isBuiltIn: false,
            localizedName: "LG UltraFine"
        )

        let profile = NotchGeometryResolver.resolve(external)

        XCTAssertEqual(profile.source, .syntheticCenter)
        XCTAssertFalse(profile.hasPhysicalNotch)
        XCTAssertEqual(profile.rect.midX, external.frame.midX, "must be centred in the menu bar")
        XCTAssertEqual(profile.rect.maxY, external.frame.maxY)
    }

    /// The synthetic region must never be taller than the menu bar, or the
    /// collapsed surface overhangs it and covers the window underneath.
    func testSyntheticRegionIsClampedToMenuBarHeight() {
        let shortMenuBar = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1056),
            backingScaleFactor: 1,
            safeAreaTop: 0,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil,
            isBuiltIn: false,
            localizedName: "Dell"
        )

        let profile = NotchGeometryResolver.resolve(shortMenuBar)

        XCTAssertLessThanOrEqual(profile.rect.height, shortMenuBar.menuBarHeight)
    }

    /// Mirroring a notched panel reports the inset but not the auxiliary areas.
    func testInsetWithoutAuxiliaryAreasUsesAspectRatioFallback() {
        let mirrored = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            backingScaleFactor: 2,
            safeAreaTop: 38,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil,
            isBuiltIn: true,
            localizedName: "Built-in Retina Display"
        )

        let profile = NotchGeometryResolver.resolve(mirrored)

        XCTAssertEqual(profile.source, .catalogFallback)
        XCTAssertTrue(profile.hasPhysicalNotch)
        XCTAssertEqual(profile.rect.height, 38, "the reported inset is exact even here")
        XCTAssertEqual(profile.rect.width, 209, "38 × 5.5, the measured aspect ratio")
        XCTAssertEqual(profile.rect.midX, mirrored.frame.midX)
    }

    /// A display that reports auxiliary areas meeting in the middle has no
    /// notch; trusting a zero-width gap would place a zero-width window.
    func testDegenerateGapIsRejected() {
        let noGap = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1710, height: 1112),
            visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1072),
            backingScaleFactor: 2,
            safeAreaTop: 0,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 1074, width: 855, height: 38),
            auxiliaryTopRightArea: CGRect(x: 855, y: 1074, width: 855, height: 38),
            isBuiltIn: true,
            localizedName: "Built-in"
        )

        XCTAssertEqual(NotchGeometryResolver.resolve(noGap).source, .syntheticCenter)
    }

    /// An implausibly wide gap would stretch the collapsed surface across most
    /// of the menu bar, hiding the user's status items.
    func testImplausiblyWideGapIsRejected() {
        let wideGap = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1710, height: 1112),
            visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1072),
            backingScaleFactor: 2,
            safeAreaTop: 38,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 1074, width: 200, height: 38),
            auxiliaryTopRightArea: CGRect(x: 1500, y: 1074, width: 210, height: 38),
            isBuiltIn: true,
            localizedName: "Built-in"
        )

        // Falls through to the height-based fallback rather than trusting 1300pt.
        XCTAssertEqual(NotchGeometryResolver.resolve(wideGap).source, .catalogFallback)
    }

    /// The rect is in the screen's coordinate space, so a display positioned to
    /// the right of the main one must produce a rect offset by its origin.
    func testProfileIsOffsetIntoScreenCoordinateSpace() {
        let secondary = ScreenMetrics(
            frame: CGRect(x: 1710, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 1710, y: 0, width: 1512, height: 944),
            backingScaleFactor: 2,
            safeAreaTop: 38,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 944, width: 651, height: 38),
            auxiliaryTopRightArea: CGRect(x: 861, y: 944, width: 651, height: 38),
            isBuiltIn: true,
            localizedName: "Built-in"
        )

        let profile = NotchGeometryResolver.resolve(secondary)

        XCTAssertEqual(profile.rect.minX, 1710 + 651)
        XCTAssertEqual(profile.rect.maxY, 982)
    }

    // MARK: - Display selection

    func testPrefersBuiltInNotchedDisplay() {
        let external = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1415),
            backingScaleFactor: 1, safeAreaTop: 0,
            auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil,
            isBuiltIn: false, localizedName: "External"
        )

        let chosen = NotchGeometryResolver.preferredScreen(from: [external, macBookAirScaled()])

        XCTAssertEqual(chosen?.localizedName, "Built-in Retina Display")
    }

    /// Clamshell mode: the lid is shut, so the only display is external.
    func testFallsBackToExternalWhenNoBuiltInDisplay() {
        let external = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1415),
            backingScaleFactor: 1, safeAreaTop: 0,
            auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil,
            isBuiltIn: false, localizedName: "External"
        )

        XCTAssertEqual(NotchGeometryResolver.preferredScreen(from: [external])?.localizedName, "External")
    }

    /// Happens momentarily during display reconfiguration.
    func testNoScreensReturnsNil() {
        XCTAssertNil(NotchGeometryResolver.preferredScreen(from: []))
    }

    // MARK: - Model catalog

    func testCatalogIdentifiesKnownModels() {
        XCTAssertEqual(MacModelCatalog.family(forModelIdentifier: "Mac15,12"), .macBookAir13)
        XCTAssertEqual(MacModelCatalog.family(forModelIdentifier: "MacBookPro18,1"), .macBookPro16)
        XCTAssertTrue(MacModelCatalog.expectsNotch(modelIdentifier: "Mac16,7"))
    }

    /// Desktops, Intel laptops, and any Mac newer than this build.
    func testUnknownModelsDegradeGracefully() {
        XCTAssertNil(MacModelCatalog.family(forModelIdentifier: "Mac99,1"))
        XCTAssertNil(MacModelCatalog.displayName(forModelIdentifier: "MacBookPro15,1"))
        XCTAssertFalse(MacModelCatalog.expectsNotch(modelIdentifier: "Macmini9,1"))
    }

    func testSysctlReportsAModelIdentifier() {
        let model = HardwareIdentityProvider.modelIdentifier()

        XCTAssertFalse(model.isEmpty)
        XCTAssertNotEqual(model, "unknown", "sysctl hw.model is available on every Mac")
        XCTAssertFalse(model.contains("\0"), "the NUL terminator must be stripped")
    }

    func testParsesSystemProfilerOutput() {
        let json = Data("""
        {"SPHardwareDataType":[{"machine_name":"MacBook Air","chip_type":"Apple M3","machine_model":"Mac15,12"}]}
        """.utf8)

        let parsed = HardwareIdentityProvider.parseHardwareProfile(json)

        XCTAssertEqual(parsed.name, "MacBook Air")
        XCTAssertEqual(parsed.chip, "Apple M3")
    }

    func testMalformedSystemProfilerOutputYieldsNils() {
        let parsed = HardwareIdentityProvider.parseHardwareProfile(Data("not json".utf8))

        XCTAssertNil(parsed.name)
        XCTAssertNil(parsed.chip)
    }
}
