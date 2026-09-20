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
    /// - Parameter outputVolume: how loud the Mac is playing, 0...1. The tap
    ///   captures the stream *before* the volume fader, so without this the bars
    ///   cannot tell music blasting from the same track at a whisper.
    public func barHeights(count: Int, resting: Float = 0.3, outputVolume: Float = 1) -> [Float] {
        guard count > 0 else { return [] }
        guard !bands.isEmpty else { return Array(repeating: resting, count: count) }

        // What is actually reaching the room: the stream's own level, scaled by
        // how far the fader is up *relative to a normal listening volume*.
        //
        // Scaling straight off the fader was wrong in both directions. It shrank
        // everything at ordinary volumes, so the indicator got quieter than it
        // had been before the fader was considered at all; and the spread
        // between one volume and another was too narrow to notice, so it did not
        // buy the responsiveness it cost. Measured against a reference of 0.7,
        // a normal volume now reads at full strength, a loud one is allowed to
        // push past it, and a quiet one plainly falls away.
        let reference: Float = 0.7
        let fader = min(1, max(0, outputVolume))
        let volumeFactor = min(1.3, fader / reference)
        let audible = min(1, min(1, max(0, level)) * volumeFactor)

        // A floor under the swing, so quiet-but-audible music still moves rather
        // than sitting at rest and reading as broken, while loud music still
        // plainly moves more.
        //
        // Both numbers were wrong before and in the same direction: a floor of
        // 0.25 under a 0.45 exponent is heavily compressive, and left barely a
        // fifth of the bars' travel covering a tenfold change in volume. That is
        // technically a response and perceptually a flat line. A lower floor and
        // a gentler curve spread the same range over something a person can
        // actually see.
        //
        // The gate is what stops that floor outliving the audio. Applied
        // unconditionally it left a quarter of the travel in place at zero
        // volume, so muting the Mac still produced bars that moved: the floor
        // was doing its job and doing it when there was nothing to report. It
        // closes smoothly rather than snapping, so the bars settle out as the
        // volume comes down instead of vanishing at a threshold.
        // Low enough that it only bites on genuine silence and a muted fader,
        // rather than on quiet music.
        let gate = min(1, audible / 0.006)
        let headroom = gate * (0.10 + 0.90 * pow(audible, 0.8))

        return (0..<count).map { index in
            // Expanded a little before it drives the bar. Band values sit in the
            // middle of the range by design (pinning them would throw away the
            // shape of the music), but mapped straight onto height that leaves
            // the row looking timid, so the curve is bent upwards here where it
            // costs nothing.
            let energy = pow(min(1, max(0, peak(of: index, of: count))), 0.75)
            // A little extra punch on the lowest bar when an onset lands, so the
            // row reads as locked to the beat rather than merely busy. Gated
            // like the rest: added outside the gate it kept punching the first
            // bar on every beat while the Mac was muted, which is how a row that
            // was otherwise perfectly still still looked alive.
            let kick = index == 0 ? beatIntensity * 0.14 * gate : 0
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
        // Spread evenly rather than fixed-width-with-a-remainder: at five bars
        // across eight bands the old split gave four bars one band each and the
        // last one four, so the right-hand bar answered to half the spectrum.
        let start = index * bands.count / count
        let end = max(start + 1, (index + 1) * bands.count / count)
        return bands[start..<min(end, bands.count)].max() ?? 0
    }
}

/// Turns a block of PCM samples into `AudioLevels`.
///
/// Kept free of Core Audio so the whole signal chain (windowing, banding,
/// smoothing, onset detection) can be driven from synthetic waveforms in
/// tests. Feeding it a 60 Hz sine and asserting the energy lands in the lowest
/// band is a far better check than squinting at bars while music plays.
public struct SpectrumAnalyzer: Sendable {

    /// Number of output bands. Eight reads clearly at notch size; more would be
    /// sub-pixel on a 200-point-wide surface.
    public let bandCount: Int
    /// FFT window length. 1024 at 48 kHz is ~21 ms. Fast enough to track a
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
        self.fftSize = max(64, FFT.nextPowerOfTwo(fftSize))
        self.sampleRate = sampleRate
    }

    /// Mutable analysis state, carried between frames.
    public struct State: Sendable {
        var smoothedBands: [Float]
        /// Rolling mean of low-band energy, for onset detection.
        var energyHistory: [Float]
        var beatIntensity: Float
        var framesSinceBeat: Float
        var smoothedLevel: Float

        public init(bandCount: Int) {
            smoothedBands = Array(repeating: 0, count: bandCount)
            energyHistory = []
            beatIntensity = 0
            framesSinceBeat = .greatestFiniteMagnitude
            smoothedLevel = 0
        }
    }

    /// Analyses one block of mono samples.
    ///
    /// - Parameters:
    ///   - samples: interleaved-to-mono PCM, nominally -1...1.
    ///   - state: carried between calls; updated in place.
    public func analyze(_ samples: [Float], state: inout State) -> AudioLevels {
        analyze(channels: [samples], state: &state)
    }

    /// Combine channel power after the FFT so stereo phase cannot cancel it.
    public func analyze(channels: [[Float]], state: inout State, frameDuration: Double = 1.0 / 90) -> AudioLevels {
        let step = Float(frameDuration * 90)
        let channels = channels.filter { !$0.isEmpty }
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        var power: Float = 0
        for samples in channels {
            let spectrum = FFT.magnitudes(of: samples, size: fftSize)
            for index in magnitudes.indices { magnitudes[index] += spectrum[index] * spectrum[index] }
            let rms = Self.rms(samples)
            power += rms * rms
        }
        let divisor = Float(max(1, channels.count))
        for index in magnitudes.indices { magnitudes[index] = sqrt(magnitudes[index] / divisor) }
        var raw = Self.fold(magnitudes, into: bandCount, sampleRate: sampleRate, fftSize: fftSize)

        // Gain, then perceptual scaling.
        //
        // The gain is the part that took a measurement to get right. A single
        // FFT bin holds all of a pure tone's energy but only a fraction of
        // broadband material's, because music spreads itself across hundreds of
        // bins, so a chain calibrated on a sine wave reads real music as almost
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
            let base = target > state.smoothedBands[index] ? attack : release
            let coefficient = 1 - pow(1 - base, step)
            state.smoothedBands[index] += (target - state.smoothedBands[index]) * coefficient
        }

        let targetLevel = Self.compress(sqrt(power / divisor) * 4)
        let levelCoefficient = 1 - pow(1 - (targetLevel > state.smoothedLevel ? attack : release), step)
        state.smoothedLevel += (targetLevel - state.smoothedLevel) * levelCoefficient
        let level = state.smoothedLevel

        let isBeat = detectBeat(bands: raw, state: &state)
        if isBeat {
            state.beatIntensity = 1
            state.framesSinceBeat = 0
        } else {
            decay(&state, step: step)
        }

        return AudioLevels(
            bands: state.smoothedBands,
            level: level,
            isBeat: isBeat,
            beatIntensity: state.beatIntensity
        )
    }

    private func decay(_ state: inout State, step: Float) {
        state.beatIntensity = max(0, state.beatIntensity - 0.08 * step)
        state.framesSinceBeat += step
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

            let lowBin = max(1, Int(ceil(lowFrequency / binWidth)))
            let highBin = min(magnitudes.count - 1, Int(ceil(highFrequency / binWidth)) - 1)
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
    /// the top as nearly silent. That's accurate and useless. Measured against
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
