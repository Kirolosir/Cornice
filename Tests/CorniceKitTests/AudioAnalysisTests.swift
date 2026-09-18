import XCTest
@testable import CorniceKit

/// The visualiser is driven by real signal processing, so it is tested with
/// real signals. Feeding it a 60 Hz sine and asserting the energy lands in the
/// lowest band is a far better check than watching bars move while music plays,
/// which can look plausible while being completely wrong.
final class AudioAnalysisTests: XCTestCase {

    private let sampleRate = 48_000.0
    private let fftSize = 1024

    private func sine(_ frequency: Double, amplitude: Float = 0.8, count: Int? = nil) -> [Float] {
        let length = count ?? fftSize
        return (0..<length).map { index in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
    }

    // MARK: - FFT

    func testPureToneLandsInTheExpectedBin() {
        let magnitudes = FFT.magnitudes(of: sine(1000), size: fftSize)

        XCTAssertEqual(magnitudes.count, fftSize / 2)
        let peak = magnitudes.enumerated().max { $0.element < $1.element }?.offset ?? -1
        let expected = Int(1000 / (sampleRate / Double(fftSize)))
        XCTAssertLessThanOrEqual(abs(peak - expected), 2, "peak at bin \(peak), expected ~\(expected)")
    }

    func testHigherToneMovesThePeakUp() {
        let low = FFT.magnitudes(of: sine(1000), size: fftSize)
        let high = FFT.magnitudes(of: sine(6000), size: fftSize)

        let lowPeak = low.enumerated().max { $0.element < $1.element }?.offset ?? 0
        let highPeak = high.enumerated().max { $0.element < $1.element }?.offset ?? 0
        XCTAssertGreaterThan(highPeak, lowPeak)
    }

    func testSilenceProducesNoMagnitude() {
        let magnitudes = FFT.magnitudes(of: [Float](repeating: 0, count: fftSize), size: fftSize)

        XCTAssertLessThan(magnitudes.max() ?? 1, 1e-6)
    }

    /// The audio callback must never trap on an unexpected buffer.
    func testAwkwardInputIsTolerated() {
        XCTAssertEqual(FFT.magnitudes(of: [], size: fftSize).count, fftSize / 2)
        XCTAssertEqual(FFT.magnitudes(of: sine(440, count: 100), size: 256).count, 128)
        XCTAssertEqual(FFT.nextPowerOfTwo(1000), 1024)
        XCTAssertEqual(FFT.nextPowerOfTwo(1024), 1024)
    }

    // MARK: - Banding

    /// Log-spaced bands, because musical pitch is logarithmic. Linear bands
    /// would put six of eight bars above 10 kHz where there is no energy.
    func testBassEnergyLandsInLowBands() {
        let analyzer = SpectrumAnalyzer(bandCount: 8, fftSize: fftSize, sampleRate: sampleRate)
        var state = SpectrumAnalyzer.State(bandCount: 8)

        var levels = AudioLevels.silent(bandCount: 8)
        for _ in 0..<12 { levels = analyzer.analyze(sine(60), state: &state) }

        let low = levels.bands.prefix(3).reduce(0, +)
        let high = levels.bands.suffix(3).reduce(0, +)
        XCTAssertGreaterThan(low, high, "60 Hz should dominate the low bands")
    }

    func testTrebleEnergyLandsInHighBands() {
        let analyzer = SpectrumAnalyzer(bandCount: 8, fftSize: fftSize, sampleRate: sampleRate)
        var state = SpectrumAnalyzer.State(bandCount: 8)

        var levels = AudioLevels.silent(bandCount: 8)
        for _ in 0..<12 { levels = analyzer.analyze(sine(9000), state: &state) }

        let low = levels.bands.prefix(3).reduce(0, +)
        let high = levels.bands.suffix(3).reduce(0, +)
        XCTAssertGreaterThan(high, low, "9 kHz should dominate the high bands")
    }

    func testLouderInputReadsHigher() {
        let analyzer = SpectrumAnalyzer(bandCount: 8, fftSize: fftSize, sampleRate: sampleRate)
        var quietState = SpectrumAnalyzer.State(bandCount: 8)
        var loudState = SpectrumAnalyzer.State(bandCount: 8)

        var quiet = AudioLevels.silent(bandCount: 8)
        var loud = AudioLevels.silent(bandCount: 8)
        for _ in 0..<8 {
            quiet = analyzer.analyze(sine(440, amplitude: 0.05), state: &quietState)
            loud = analyzer.analyze(sine(440, amplitude: 0.9), state: &loudState)
        }

        XCTAssertGreaterThan(loud.level, quiet.level)
        XCTAssertLessThanOrEqual(loud.level, 1.0)
        XCTAssertGreaterThanOrEqual(quiet.level, 0)
    }

    func testSilenceSettlesToRest() {
        let analyzer = SpectrumAnalyzer(bandCount: 8, fftSize: fftSize, sampleRate: sampleRate)
        var state = SpectrumAnalyzer.State(bandCount: 8)

        var levels = AudioLevels.silent(bandCount: 8)
        for _ in 0..<40 { levels = analyzer.analyze([Float](repeating: 0, count: fftSize), state: &state) }

        XCTAssertLessThan(levels.level, 0.02)
        XCTAssertFalse(levels.isBeat)
    }

    func testEmptyBlockDoesNotCrash() {
        let analyzer = SpectrumAnalyzer(bandCount: 8, fftSize: fftSize, sampleRate: sampleRate)
        var state = SpectrumAnalyzer.State(bandCount: 8)

        let levels = analyzer.analyze([], state: &state)

        XCTAssertEqual(levels.bands.count, 8)
    }

    func testCompressionIsConcave() {
        XCTAssertEqual(SpectrumAnalyzer.compress(0), 0)
        XCTAssertGreaterThan(SpectrumAnalyzer.compress(1), 0.9)
        // Quiet passages must still move the bars, or the visualiser looks dead
        // on anything but a loud chorus.
        XCTAssertGreaterThan(SpectrumAnalyzer.compress(0.5), 0.5)
    }

    func testRootMeanSquare() {
        XCTAssertEqual(SpectrumAnalyzer.rms([1, -1, 1, -1]), 1.0, accuracy: 0.001)
        XCTAssertEqual(SpectrumAnalyzer.rms([]), 0)
    }

    func testFoldingFillsEveryBand() {
        let folded = SpectrumAnalyzer.fold(
            [Float](repeating: 0.5, count: 512), into: 8, sampleRate: sampleRate, fftSize: fftSize
        )

        XCTAssertEqual(folded.count, 8)
        XCTAssertTrue(folded.allSatisfy { $0 > 0 })
    }

    // MARK: - Beat detection

    func testPeriodicKicksAreDetected() {
        let analyzer = SpectrumAnalyzer(bandCount: 8, fftSize: fftSize, sampleRate: sampleRate)
        var state = SpectrumAnalyzer.State(bandCount: 8)

        // Establish a quiet baseline first; onset detection is relative.
        for _ in 0..<20 { _ = analyzer.analyze(sine(60, amplitude: 0.02), state: &state) }

        var beats = 0
        for index in 0..<40 {
            let amplitude: Float = index % 8 == 0 ? 0.95 : 0.02
            if analyzer.analyze(sine(60, amplitude: amplitude), state: &state).isBeat { beats += 1 }
        }

        XCTAssertGreaterThanOrEqual(beats, 2, "kicks should register")
        XCTAssertLessThanOrEqual(beats, 10, "the refractory period should stop one kick firing repeatedly")
    }

    /// A sustained tone is loud but has no onsets. Firing on it would make the
    /// artwork pulse continuously through an organ chord.
    func testSteadyToneIsNotRepeatedlyABeat() {
        let analyzer = SpectrumAnalyzer(bandCount: 8, fftSize: fftSize, sampleRate: sampleRate)
        var state = SpectrumAnalyzer.State(bandCount: 8)

        var beats = 0
        for _ in 0..<60 {
            if analyzer.analyze(sine(60, amplitude: 0.8), state: &state).isBeat { beats += 1 }
        }

        XCTAssertLessThanOrEqual(beats, 2)
    }

    func testSilentLevelsHelper() {
        let silent = AudioLevels.silent(bandCount: 5)

        XCTAssertEqual(silent.bands.count, 5)
        XCTAssertTrue(silent.isSilent)
    }
}

/// The mapping from analysed audio onto the compact playing indicator.
final class IndicatorBarTests: XCTestCase {

    private func levels(bands: [Float], level: Float, beat: Float = 0) -> AudioLevels {
        AudioLevels(bands: bands, level: level, isBeat: beat > 0, beatIntensity: beat)
    }

    /// The whole point of the change: the same spectrum played louder has to
    /// move further. Driving the bars from the bands alone gave every passage
    /// the same amplitude, because each band is already compressed.
    func testLouderAudioSwingsFurtherForTheSameSpectrum() {
        let spectrum: [Float] = [0.8, 0.8, 0.7, 0.7, 0.6, 0.6, 0.5, 0.5]
        let quiet = levels(bands: spectrum, level: 0.2).barHeights(count: 3)
        let loud = levels(bands: spectrum, level: 0.9).barHeights(count: 3)

        for index in 0..<3 {
            XCTAssertGreaterThan(loud[index], quiet[index], "bar \(index)")
        }
        XCTAssertGreaterThan(loud[0] - quiet[0], 0.15, "the difference should be plainly visible")
    }

    /// Silence rests rather than collapsing, so the row reads as a control
    /// rather than as a component that failed to load.
    func testSilenceRests() {
        let heights = levels(bands: [0, 0, 0, 0, 0, 0, 0, 0], level: 0).barHeights(count: 3)
        XCTAssertEqual(heights, [0.3, 0.3, 0.3])
    }

    /// A narrow tone should move its bar fully instead of being averaged into
    /// nothing by the quiet bins beside it.
    func testABarTakesThePeakOfItsSliceNotTheMean() {
        let spike: [Float] = [1, 0, 0, 0, 0, 0, 0, 0]
        let heights = levels(bands: spike, level: 1).barHeights(count: 3)
        XCTAssertGreaterThan(heights[0], 0.9)
        XCTAssertEqual(heights[1], 0.3, accuracy: 0.001)
    }

    /// Every band belongs to some bar: eight bands across three bars must not
    /// leave the top of the spectrum unrepresented.
    func testTheLastBarTakesTheRemainingBands() {
        var bands = [Float](repeating: 0, count: 8)
        bands[7] = 1
        let heights = levels(bands: bands, level: 1).barHeights(count: 3)
        XCTAssertGreaterThan(heights[2], 0.9)
    }

    /// An onset punches the low bar without letting it exceed full height.
    func testBeatPunchesTheLowBarAndStaysInRange() {
        let spectrum = [Float](repeating: 1, count: 8)
        let heights = levels(bands: spectrum, level: 1, beat: 1).barHeights(count: 3)
        XCTAssertLessThanOrEqual(heights[0], 1)
        for height in heights { XCTAssertGreaterThanOrEqual(height, 0.3) }
    }

    func testNoBandsYieldsRestingBars() {
        XCTAssertEqual(levels(bands: [], level: 0.5).barHeights(count: 3), [0.3, 0.3, 0.3])
    }
}

/// Calibration of band magnitudes against material the app actually meets.
///
/// These exist because the chain was correct for a sine wave and useless for a
/// song. A pure tone puts all of its energy in one FFT bin; music spreads itself
/// across hundreds, so a scale calibrated on a tone reads real audio as almost
/// nothing and the bars move by a fraction of a point.
final class BandCalibrationTests: XCTestCase {

    private let rate = 48_000.0
    private let size = 1024

    private func tone(_ hz: Double, amplitude: Float) -> [Float] {
        (0..<size).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / rate)) }
    }

    /// Twelve tones spread across the spectrum: deterministic, and broadband in
    /// the way music is.
    private func broadband(amplitude: Float) -> [Float] {
        let frequencies = (0..<12).map { 60.0 * pow(2, Double($0) / 2) }
        var samples = [Float](repeating: 0, count: size)
        for frequency in frequencies {
            let partial = tone(frequency, amplitude: amplitude)
            for index in 0..<size { samples[index] += partial[index] }
        }
        return samples
    }

    private func bands(_ samples: [Float]) -> [Float] {
        let analyzer = SpectrumAnalyzer(bandCount: 8, fftSize: size, sampleRate: rate)
        var state = SpectrumAnalyzer.State(bandCount: 8)
        // Several passes, because the analyser smooths towards its target.
        var levels = analyzer.analyze(samples, state: &state)
        for _ in 0..<40 { levels = analyzer.analyze(samples, state: &state) }
        return levels.bands
    }

    func testBroadbandMaterialReachesTheUsableRange() {
        let peak = bands(broadband(amplitude: 0.06)).max() ?? 0
        XCTAssertGreaterThan(peak, 0.4, "broadband audio must move a bar, not sit at the floor")
    }

    /// The other end: a full-scale tone should saturate rather than being the
    /// only thing that ever fills the meter.
    func testFullScaleToneSaturates() {
        let peak = bands(tone(1000, amplitude: 1.0)).max() ?? 0
        XCTAssertGreaterThan(peak, 0.95)
    }

    /// The whole chain, end to end: ordinary material has to produce bars that
    /// are visibly off their resting height.
    func testBarsMoveVisiblyForOrdinaryMaterial() {
        let analyzer = SpectrumAnalyzer(bandCount: 8, fftSize: size, sampleRate: rate)
        var state = SpectrumAnalyzer.State(bandCount: 8)
        let samples = broadband(amplitude: 0.06)
        var levels = analyzer.analyze(samples, state: &state)
        for _ in 0..<40 { levels = analyzer.analyze(samples, state: &state) }

        let heights = levels.barHeights(count: 3)
        let tallest = heights.max() ?? 0
        XCTAssertGreaterThan(
            tallest, 0.5,
            "a 13pt bar resting at 0.3 has to reach past half height to read as moving"
        )
    }

    func testSilenceStillRests() {
        let heights = bands([Float](repeating: 0, count: size))
        for band in heights { XCTAssertLessThan(band, 0.05) }
    }
}

/// Compensation for music's natural downward spectral slope.
final class SpectralTiltTests: XCTestCase {

    func testTiltRisesWithFrequency() {
        let tilts = (0..<8).map { SpectrumAnalyzer.spectralTilt($0, of: 8) }
        for index in 1..<tilts.count {
            XCTAssertGreaterThan(tilts[index], tilts[index - 1], "band \(index)")
        }
    }

    /// The bottom is trimmed so it is not permanently saturated, and the top is
    /// lifted by roughly the amount real material falls off by.
    func testTiltTrimsTheBottomAndLiftsTheTop() {
        XCTAssertLessThan(SpectrumAnalyzer.spectralTilt(0, of: 8), 1)
        XCTAssertGreaterThan(SpectrumAnalyzer.spectralTilt(7, of: 8), 4)
    }

    func testSingleBandIsUntouched() {
        XCTAssertEqual(SpectrumAnalyzer.spectralTilt(0, of: 1), 1)
    }

    /// End to end: a high tone must move its bar about as much as a low one of
    /// the same amplitude. Without compensation the top of the spectrum sat near
    /// the resting height while the bottom pinned, which reads as a broken row
    /// rather than as a quiet treble.
    func testHighFrequenciesReachTheSameRangeAsLow() {
        let rate = 48_000.0
        let size = 1024

        func peakBand(of hz: Double) -> Float {
            let samples = (0..<size).map { 0.25 * Float(sin(2 * .pi * hz * Double($0) / rate)) }
            let analyzer = SpectrumAnalyzer(bandCount: 8, fftSize: size, sampleRate: rate)
            var state = SpectrumAnalyzer.State(bandCount: 8)
            var levels = analyzer.analyze(samples, state: &state)
            for _ in 0..<40 { levels = analyzer.analyze(samples, state: &state) }
            return levels.bands.max() ?? 0
        }

        let low = peakBand(of: 100)
        let high = peakBand(of: 8000)
        XCTAssertGreaterThan(high, low * 0.8, "the top of the spectrum must not be a dead bar")
    }
}

/// Which repeat modes each player can actually be put into.
final class RepeatModeTests: XCTestCase {

    /// Music's `song repeat` is a real three-way.
    func testMusicCyclesThroughAllThreeModes() {
        XCTAssertEqual(RepeatMode.off.next(on: .appleMusic), .all)
        XCTAssertEqual(RepeatMode.all.next(on: .appleMusic), .one)
        XCTAssertEqual(RepeatMode.one.next(on: .appleMusic), .off)
    }

    /// Spotify's scripting interface exposes `repeating` as a boolean and
    /// nothing else, so offering a third state would display a mode the player
    /// is not in and make the second press look like it did nothing.
    func testSpotifyOnlyToggles() {
        XCTAssertEqual(RepeatMode.off.next(on: .spotify), .all)
        XCTAssertEqual(RepeatMode.all.next(on: .spotify), .off)
        XCTAssertEqual(RepeatMode.one.next(on: .spotify), .off)
    }

    func testOnlyMusicClaimsRepeatOne() {
        XCTAssertTrue(MediaSource.appleMusic.supportsRepeatOne)
        XCTAssertFalse(MediaSource.spotify.supportsRepeatOne)
    }

    /// Cycling a player can never land on a mode it does not support.
    func testCyclingNeverReachesAnUnsupportedMode() {
        var mode = RepeatMode.off
        for _ in 0..<12 {
            mode = mode.next(on: .spotify)
            XCTAssertNotEqual(mode, .one)
        }
    }
}

/// Balance across the spectrum, checked against pink noise.
///
/// Pink noise is the standard stand-in for music's long-term average spectrum:
/// equal energy per octave. A visualiser that is correctly compensated draws it
/// as a roughly level row. Drawn as a staircase — pinned on the left, motionless
/// on the right — the compensation is wrong, which is exactly what it was.
final class SpectrumBalanceTests: XCTestCase {

    private let rate = 48_000.0
    private let size = 1024

    /// Voss-McCartney pink noise, seeded so the test is deterministic.
    private func pinkNoise(count: Int, amplitude: Float) -> [Float] {
        var state: UInt64 = 12345
        func random() -> Float {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Float(state % 20001) / 10000 - 1
        }
        var rows = [Float](repeating: 0, count: 16)
        var out = [Float](repeating: 0, count: count)
        for index in 0..<count {
            var counter = index + 1
            var row = 0
            while counter & 1 == 0 && row < rows.count - 1 { counter >>= 1; row += 1 }
            rows[row] = random()
            out[index] = rows.reduce(0, +) / Float(rows.count)
        }
        let peak = out.map { abs($0) }.max() ?? 1
        return out.map { $0 / max(peak, 0.0001) * amplitude }
    }

    private func profile(amplitude: Float) -> (bands: [Float], level: Float) {
        let noise = pinkNoise(count: size * 8, amplitude: amplitude)
        let analyzer = SpectrumAnalyzer(bandCount: 8, fftSize: size, sampleRate: rate)
        var state = SpectrumAnalyzer.State(bandCount: 8)
        var peaks = [Float](repeating: 0, count: 8)
        var level: Float = 0
        for start in stride(from: 0, to: noise.count - size, by: size / 2) {
            let levels = analyzer.analyze(Array(noise[start..<(start + size)]), state: &state)
            for (index, value) in levels.bands.enumerated() { peaks[index] = max(peaks[index], value) }
            level = max(level, levels.level)
        }
        return (peaks, level)
    }

    func testPinkNoiseDrawsALevelRow() {
        let bands = profile(amplitude: 0.35).bands
        let highest = bands.max() ?? 0
        let lowest = bands.min() ?? 0
        XCTAssertGreaterThan(lowest, 0.4, "no band may sit at the floor")
        XCTAssertLessThan(highest, 0.95, "no band may pin")
        XCTAssertLessThan(highest - lowest, 0.25, "the row should read level, not as a staircase")
    }

    /// The three bars the interface actually draws, rather than the eight bands
    /// behind them: none may be dead and none may be permanently full.
    func testAllThreeBarsAreAliveAtEveryLevel() {
        for amplitude in [Float(0.35), 0.15, 0.05] {
            let measured = profile(amplitude: amplitude)
            let levels = AudioLevels(
                bands: measured.bands, level: measured.level, isBeat: false, beatIntensity: 0
            )
            let bars = levels.barHeights(count: 3)
            let spread = (bars.max() ?? 0) - (bars.min() ?? 0)
            XCTAssertLessThan(spread, 0.2, "bars unbalanced at amplitude \(amplitude): \(bars)")
            XCTAssertGreaterThan(bars.min() ?? 0, 0.33, "a dead bar at amplitude \(amplitude)")
        }
    }

    /// Balance must not come at the cost of the loudness response.
    func testQuieterMaterialStillDrawsShorterBars() {
        func tallest(_ amplitude: Float) -> Float {
            let measured = profile(amplitude: amplitude)
            let levels = AudioLevels(
                bands: measured.bands, level: measured.level, isBeat: false, beatIntensity: 0
            )
            return levels.barHeights(count: 3).max() ?? 0
        }
        XCTAssertGreaterThan(tallest(0.35), tallest(0.15) + 0.1)
        XCTAssertGreaterThan(tallest(0.15), tallest(0.05) + 0.1)
    }
}
