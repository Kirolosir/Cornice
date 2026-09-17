import Foundation

/// One frame of analysed audio, ready to drive the visualiser.
public struct AudioLevels: Sendable, Equatable {
    /// Per-band magnitudes, 0...1, low frequency first.
    public var bands: [Float]
    /// Broadband loudness, 0...1. Drives the overall "breathing" of the UI.
    public var level: Float
    /// True on the frame a beat was detected.
    public var isBeat: Bool
    /// Decays from 1 after each beat, so the UI can pulse smoothly rather than
    /// flashing for exactly one frame.
    public var beatIntensity: Float

    public init(bands: [Float], level: Float, isBeat: Bool, beatIntensity: Float) {
        self.bands = bands
        self.level = level
        self.isBeat = isBeat
        self.beatIntensity = beatIntensity
    }

    public static func silent(bandCount: Int) -> AudioLevels {
        AudioLevels(
            bands: Array(repeating: 0, count: bandCount),
            level: 0,
            isBeat: false,
            beatIntensity: 0
        )
    }

    public var isSilent: Bool { level < 0.001 }
}

/// Turns a block of PCM samples into `AudioLevels`.
///
/// Kept free of Core Audio so the whole signal chain — windowing, banding,
/// smoothing, onset detection — can be driven from synthetic waveforms in
/// tests. Feeding it a 60 Hz sine and asserting the energy lands in the lowest
/// band is a far better check than squinting at bars while music plays.
public struct SpectrumAnalyzer: Sendable {

    /// Number of output bands. Eight reads clearly at notch size; more would be
    /// sub-pixel on a 200-point-wide surface.
    public let bandCount: Int
    /// FFT window length. 1024 at 48 kHz is ~21 ms — fast enough to track a
    /// beat, long enough to resolve bass.
    public let fftSize: Int

    private let sampleRate: Double

    /// Attack and release coefficients.
    ///
    /// Asymmetric on purpose: bars jump to a transient almost immediately and
    /// fall away slowly. Symmetric smoothing either looks sluggish on the
    /// attack or jitters on the decay, and the asymmetry is what makes a
    /// visualiser look "locked" to the music.
    private let attack: Float = 0.55
    private let release: Float = 0.12

    public init(bandCount: Int = 8, fftSize: Int = 1024, sampleRate: Double = 48_000) {
        self.bandCount = max(1, bandCount)
        self.fftSize = max(64, fftSize)
        self.sampleRate = sampleRate
    }

    /// Mutable analysis state, carried between frames.
    public struct State: Sendable {
        var smoothedBands: [Float]
        /// Rolling mean of low-band energy, for onset detection.
        var energyHistory: [Float]
        var beatIntensity: Float
        var framesSinceBeat: Int

        public init(bandCount: Int) {
            smoothedBands = Array(repeating: 0, count: bandCount)
            energyHistory = []
            beatIntensity = 0
            framesSinceBeat = .max
        }
    }

    /// Analyses one block of mono samples.
    ///
    /// - Parameters:
    ///   - samples: interleaved-to-mono PCM, nominally -1...1.
    ///   - state: carried between calls; updated in place.
    public func analyze(_ samples: [Float], state: inout State) -> AudioLevels {
        guard !samples.isEmpty else {
            decay(&state)
            return AudioLevels(
                bands: state.smoothedBands, level: 0,
                isBeat: false, beatIntensity: state.beatIntensity
            )
        }

        let magnitudes = FFT.magnitudes(of: samples, size: fftSize)
        var raw = Self.fold(magnitudes, into: bandCount, sampleRate: sampleRate, fftSize: fftSize)

        // Perceptual scaling. Linear magnitudes make everything above the bass
        // look flat, because hearing is roughly logarithmic in amplitude.
        for index in raw.indices {
            raw[index] = Self.compress(raw[index])
        }

        for index in state.smoothedBands.indices where index < raw.count {
            let target = raw[index]
            let coefficient = target > state.smoothedBands[index] ? attack : release
            state.smoothedBands[index] += (target - state.smoothedBands[index]) * coefficient
        }

        let rms = Self.rms(samples)
        let level = Self.compress(rms * 4)

        let isBeat = detectBeat(bands: raw, state: &state)
        if isBeat {
            state.beatIntensity = 1
            state.framesSinceBeat = 0
        } else {
            decay(&state)
        }

        return AudioLevels(
            bands: state.smoothedBands,
            level: level,
            isBeat: isBeat,
            beatIntensity: state.beatIntensity
        )
    }

    private func decay(_ state: inout State) {
        state.beatIntensity = max(0, state.beatIntensity - 0.08)
        if state.framesSinceBeat < .max { state.framesSinceBeat += 1 }
    }

    /// Energy-based onset detection on the low bands.
    ///
    /// Compares the current low-frequency energy against a rolling mean and
    /// fires when it exceeds it by a margin. This is the classic approach and
    /// it is chosen over anything cleverer for a specific reason: it costs
    /// almost nothing, and a visualiser that is occasionally a beat off is
    /// vastly preferable to one that burns CPU on a laptop doing spectral flux
    /// analysis for a decorative animation.
    ///
    /// A refractory period prevents one loud kick from firing on several
    /// consecutive frames.
    private func detectBeat(bands: [Float], state: inout State) -> Bool {
        let lowBandCount = max(1, bandCount / 4)
        let energy = bands.prefix(lowBandCount).reduce(0, +) / Float(lowBandCount)

        state.energyHistory.append(energy)
        if state.energyHistory.count > 43 { state.energyHistory.removeFirst() }

        // Need enough history for the mean to mean anything.
        guard state.energyHistory.count >= 12 else { return false }
        // ~120 ms at a 90 Hz frame rate: fast enough for 240 BPM, slow enough
        // to reject a single kick's decay.
        guard state.framesSinceBeat >= 10 else { return false }

        let mean = state.energyHistory.reduce(0, +) / Float(state.energyHistory.count)
        guard mean > 0.01 else { return false }
        return energy > mean * 1.35 && energy > 0.08
    }

    /// Folds linear FFT bins into log-spaced bands.
    ///
    /// Log spacing because musical pitch is logarithmic: linear bands would put
    /// six of eight bars above 10 kHz, where there is almost no energy, and
    /// cram the entire bass range into one.
    static func fold(_ magnitudes: [Float], into bandCount: Int, sampleRate: Double, fftSize: Int) -> [Float] {
        guard !magnitudes.isEmpty, bandCount > 0 else {
            return Array(repeating: 0, count: bandCount)
        }

        let minimumFrequency: Double = 40
        let maximumFrequency = min(16_000, sampleRate / 2)
        let binWidth = sampleRate / Double(fftSize)

        var bands = [Float](repeating: 0, count: bandCount)
        for band in 0..<bandCount {
            let lowRatio = Double(band) / Double(bandCount)
            let highRatio = Double(band + 1) / Double(bandCount)
            let lowFrequency = minimumFrequency * pow(maximumFrequency / minimumFrequency, lowRatio)
            let highFrequency = minimumFrequency * pow(maximumFrequency / minimumFrequency, highRatio)

            let lowBin = max(1, Int(lowFrequency / binWidth))
            let highBin = min(magnitudes.count - 1, max(lowBin, Int(highFrequency / binWidth)))
            guard lowBin <= highBin else { continue }

            // Peak rather than mean within the band: a narrow tone should move
            // its bar fully, not be averaged into insignificance by the silent
            // bins beside it.
            var peak: Float = 0
            for bin in lowBin...highBin { peak = max(peak, magnitudes[bin]) }
            bands[band] = peak
        }
        return bands
    }

    /// Maps a magnitude to 0...1 with a perceptual curve.
    static func compress(_ value: Float) -> Float {
        guard value > 0 else { return 0 }
        // A soft knee rather than raw dB: dB needs a floor choice that is wrong
        // at some volume, whereas this saturates gracefully at both ends.
        let scaled = log10(1 + value * 9) // 0...1 for value 0...1
        return min(1, max(0, scaled))
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}
