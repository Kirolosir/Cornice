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

    /// Bar heights for a compact playing indicator, each 0...1 of full height.
    ///
    /// The spectrum decides the *shape* and the overall level decides how much
    /// room that shape has to move in. That second half is what makes a quiet
    /// passage barely stir and a loud one swing the full height: driving the
    /// bars from the bands alone gives every passage the same amplitude, because
    /// each band is already perceptually compressed, so the music changes shape
    /// but never size.
    ///
    /// - Parameters:
    ///   - count: how many bars to fill.
    ///   - resting: the height a bar holds in silence, so the row reads as a
    ///     control rather than as a glitch.
    public func barHeights(count: Int, resting: Float = 0.3) -> [Float] {
        guard count > 0 else { return [] }
        guard !bands.isEmpty else { return Array(repeating: resting, count: count) }

        // Slightly concave, so ordinary listening levels already move properly
        // rather than only the loudest choruses.
        let headroom = pow(min(1, max(0, level)), 0.4)

        return (0..<count).map { index in
            // Expanded a little before it drives the bar. Band values sit in the
            // middle of the range by design — pinning them would throw away the
            // shape of the music — but mapped straight onto height that leaves
            // the row looking timid, so the curve is bent upwards here where it
            // costs nothing.
            let energy = pow(min(1, max(0, peak(of: index, of: count))), 0.75)
            // A little extra punch on the lowest bar when an onset lands, so the
            // row reads as locked to the beat rather than merely busy.
            let kick = index == 0 ? beatIntensity * 0.14 : 0
            let swing = (1 - resting) * energy * headroom + kick
            return min(1, max(resting, resting + swing))
        }
    }

    /// The loudest band in one bar's slice of the spectrum.
    ///
    /// Peak rather than mean, for the same reason the analyser folds bins that
    /// way: a narrow tone should move its bar fully instead of being averaged
    /// into nothing by the quiet bins beside it.
    private func peak(of index: Int, of count: Int) -> Float {
        let perBar = max(1, bands.count / count)
        let start = min(index * perBar, bands.count - 1)
        // The last bar takes whatever is left, so no band goes unrepresented.
        let end = index == count - 1 ? bands.count : min(start + perBar, bands.count)
        return bands[start..<end].max() ?? 0
    }
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

        // Gain, then perceptual scaling.
        //
        // The gain is the part that took a measurement to get right. A single
        // FFT bin holds all of a pure tone's energy but only a fraction of
        // broadband material's, because music spreads itself across hundreds of
        // bins — so a chain calibrated on a sine wave reads real music as almost
        // nothing. Measured here: a full-scale 1 kHz tone put its band at 0.89,
        // while noise at a normal listening level put its band at 0.09, and the
        // bars moved by a fraction of a point.
        //
        // This lifts broadband material into the usable range. A pure tone now
        // saturates instead, which is the right way round: a sine wave pegging
        // the meter is correct, a song failing to move it is not.
        for index in raw.indices {
            raw[index] = Self.compress(raw[index] * Self.bandGain * Self.spectralTilt(index, of: raw.count))
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

        let minimumFrequency = minimumBandFrequency
        let maximumFrequency = min(minimumBandFrequency * bandFrequencySpan, sampleRate / 2)
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

    /// Overall band gain, set so that loud material sits high in the range
    /// without pinning. Measured against pink noise at a normal listening level,
    /// this puts every band around three-quarters height with room to move.
    static let bandGain: Float = 13

    /// The bottom of the analysed range. Below this is rumble, not music.
    static let minimumBandFrequency: Double = 40
    /// How many times that the top of the range is: 40 Hz to 16 kHz.
    static let bandFrequencySpan: Double = 400

    /// Per-band compensation for music's natural downward spectral slope.
    ///
    /// Recorded music approximates pink noise: equal energy per octave, which
    /// means the amplitude in any one FFT bin falls as `1/√f`. Reading the peak
    /// bin of each band therefore reports the bottom of the spectrum as loud and
    /// the top as nearly silent — faithfully, and uselessly. Measured against
    /// synthetic pink noise, the lowest band came back 15.0× the highest; `√f`
    /// predicts 15.5.
    ///
    /// So the compensation is `√(centre frequency)`, normalised at the middle
    /// band. That is a property of the signal rather than a curve fitted to one
    /// song, and it generalises to any band count.
    static func spectralTilt(_ index: Int, of count: Int) -> Float {
        guard count > 1 else { return 1 }
        func centre(_ i: Int) -> Float {
            let position = (Float(i) + 0.5) / Float(count)
            return Float(minimumBandFrequency) * pow(Float(bandFrequencySpan), position)
        }
        return (centre(index) / centre((count - 1) / 2)).squareRoot()
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
