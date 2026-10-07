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

    /// Map the spectrum to bar heights from 0 to 1. Loudness and output volume control how
    /// far the bars move.
    ///
    /// - Parameters:
    ///   - count: Number of bars.
    ///   - resting: Height when silent.
    ///   - outputVolume: System volume from 0 to 1. Capture happens before this fader.
    public func barHeights(count: Int, resting: Float = 0.3, outputVolume: Float = 1) -> [Float] {
        guard count > 0 else { return [] }
        guard !bands.isEmpty else { return Array(repeating: resting, count: count) }

        // Use 70% output volume as the reference. Lower volume reduces the motion, with a
        // little extra range for louder output.
        let reference: Float = 0.7
        let fader = min(1, max(0, outputVolume))
        let volumeFactor = min(1.3, fader / reference)
        let audible = min(1, min(1, max(0, level)) * volumeFactor)

        // Keep some motion for quiet music, but close the gate at silence or mute. The
        // floor mustn't keep the bars moving with no audible output.
        let gate = min(1, audible / 0.006)
        let headroom = gate * (0.10 + 0.90 * pow(audible, 0.8))

        return (0..<count).map { index in
            // Lift midrange band values a little so their motion is visible without pinning
            // the bars at full height.
            let energy = pow(min(1, max(0, peak(of: index, of: count))), 0.75)
            // Give the bass bar a small beat kick. Apply the same gate so it stays still
            // when muted.
            let kick = index == 0 ? beatIntensity * 0.14 * gate : 0
            let swing = (1 - resting) * energy * headroom + kick
            return min(1, max(resting, resting + swing))
        }
    }

    /// Take the loudest band in this bar's range. An average would hide narrow tones among
    /// quiet bands.
    private func peak(of index: Int, of count: Int) -> Float {
        // Spread the bands evenly across the requested bars so the last bar does not get
        // most of the spectrum.
        let start = index * bands.count / count
        let end = max(start + 1, (index + 1) * bands.count / count)
        return bands[start..<min(end, bands.count)].max() ?? 0
    }
}

/// Turn PCM samples into levels. Keeping Core Audio out of this type lets tests feed it
/// generated signals.
public struct SpectrumAnalyzer: Sendable {

    /// Number of frequency bands produced by the analyzer.
    public let bandCount: Int
    /// FFT window length. 1024 at 48 kHz is ~21 ms. Fast enough to track a
    /// beat, long enough to resolve bass.
    public let fftSize: Int

    private let sampleRate: Double

    /// Rise quickly on a transient and settle more slowly. Using the same smoothing in both
    /// directions felt sluggish or jittery.
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

    /// Analyze one block of mono audio.
    ///
    /// - Parameters:
    ///   - samples: Mono PCM samples, normally -1...1.
    ///   - state: Previous analysis state, updated in place.
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

        // Apply gain before compression. Music spreads energy over many FFT bins, so gain
        // tuned only for a sine wave makes songs barely move the bars.
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

    /// Detect a beat when bass energy rises above its recent average. The cooldown stops
    /// one kick from triggering on several frames.
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

    /// Group FFT bins on a logarithmic frequency scale so the bass range gets enough room.
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

    /// Scale broadband music into a useful range without keeping most bands at full height.
    static let bandGain: Float = 13

    /// The bottom of the analysed range. Below this is rumble, not music.
    static let minimumBandFrequency: Double = 40
    /// How many times that the top of the range is: 40 Hz to 16 kHz.
    static let bandFrequencySpan: Double = 400

    /// Compensate for the drop in energy toward higher frequencies. Use the square root of
    /// each band's center frequency, relative to the middle band; pink noise should then
    /// look roughly level.
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
