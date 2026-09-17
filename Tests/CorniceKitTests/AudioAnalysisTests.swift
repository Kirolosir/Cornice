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
