import Foundation

/// Runs the tap, analyses its output, and publishes the latest levels.
///
/// The threading model is the interesting part. Audio arrives on Core Audio's
/// own IO queue, hundreds of times a second; SwiftUI wants to read a value once
/// per frame. Pushing an observable update from the audio callback would
/// schedule main-actor work faster than it drains and stutter the whole UI.
///
/// So the callback analyses in place and writes the result into a
/// lock-protected box, and the UI *pulls* the latest value on its own display
/// timer. Audio never touches the main actor, and the UI never blocks on audio.
public final class AudioVisualizerEngine: @unchecked Sendable {

    public enum Status: Equatable, Sendable {
        case stopped
        case running
        case failed(AudioTapUnavailable)
    }

    private let lock = NSLock()
    private var levels: AudioLevels
    private var analyzerState: SpectrumAnalyzer.State
    private var analyzer: SpectrumAnalyzer
    private var status: Status = .stopped
    /// Set when audio stops arriving, so the bars fall to rest instead of
    /// freezing mid-spectrum when playback pauses.
    private var lastSampleAt: Date = .distantPast

    private let tap = SystemAudioTap()
    public let bandCount: Int

    public init(bandCount: Int = 8) {
        self.bandCount = bandCount
        self.analyzer = SpectrumAnalyzer(bandCount: bandCount)
        self.analyzerState = SpectrumAnalyzer.State(bandCount: bandCount)
        self.levels = .silent(bandCount: bandCount)
    }

    public var currentStatus: Status {
        lock.lock(); defer { lock.unlock() }
        return status
    }

    public var isRunning: Bool {
        if case .running = currentStatus { return true }
        return false
    }

    /// The most recent analysed frame.
    ///
    /// Decays to silence when audio has stopped arriving — a paused track
    /// should let the bars settle, not leave them frozen at whatever the last
    /// block happened to contain.
    public func latestLevels() -> AudioLevels {
        lock.lock()
        defer { lock.unlock() }

        if Date().timeIntervalSince(lastSampleAt) > 0.25, !levels.isSilent {
            for index in levels.bands.indices {
                levels.bands[index] *= 0.82
            }
            levels.level *= 0.82
            levels.beatIntensity = max(0, levels.beatIntensity - 0.1)
            levels.isBeat = false
        }
        return levels
    }

    /// Starts capture. Returns the resulting status rather than throwing,
    /// because every caller wants to display the failure rather than propagate it.
    @discardableResult
    public func start() -> Status {
        lock.lock()
        if case .running = status {
            lock.unlock()
            return .running
        }
        lock.unlock()

        do {
            try tap.start { [weak self] samples, sampleRate in
                self?.consume(samples, sampleRate: sampleRate)
            }
            lock.lock()
            status = .running
            lock.unlock()
            return .running
        } catch let error as AudioTapUnavailable {
            lock.lock()
            status = .failed(error)
            levels = .silent(bandCount: bandCount)
            lock.unlock()
            Log.audio.error("visualiser unavailable: \(error.message, privacy: .public)")
            return .failed(error)
        } catch {
            let failure = AudioTapUnavailable.coreAudioError(-1, stage: "start")
            lock.lock()
            status = .failed(failure)
            lock.unlock()
            return .failed(failure)
        }
    }

    public func stop() {
        tap.stop()
        lock.lock()
        status = .stopped
        levels = .silent(bandCount: bandCount)
        analyzerState = SpectrumAnalyzer.State(bandCount: bandCount)
        lock.unlock()
    }

    /// Analyses one block. Runs on Core Audio's IO queue.
    private func consume(_ samples: [Float], sampleRate: Double) {
        lock.lock()
        // The tap reports its real sample rate, which can change if the user
        // switches output device mid-session; rebuild the analyser when it does
        // so the frequency bands stay where they should be.
        if analyzer.bandCount != bandCount || abs(sampleRateOfAnalyzer - sampleRate) > 1 {
            analyzer = SpectrumAnalyzer(bandCount: bandCount, sampleRate: sampleRate)
            sampleRateOfAnalyzer = sampleRate
        }
        let analyzed = analyzer.analyze(samples, state: &analyzerState)
        levels = analyzed
        lastSampleAt = Date()
        lock.unlock()
    }

    private var sampleRateOfAnalyzer: Double = 0
}
