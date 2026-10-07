import Foundation

/// Analyze audio on the IO queue and store the latest levels under a lock. The UI reads
/// once per frame instead of queuing a main-actor update for every audio block.
public final class AudioVisualizerEngine: @unchecked Sendable {

    public enum Status: Equatable, Sendable {
        case stopped
        case running
        case failed(AudioTapUnavailable)
    }

    private let lock = NSLock()
    private var levels: AudioLevels
    private var analyzer: StreamingSpectrumAnalyzer
    private var status: Status = .stopped
    /// Set when audio stops arriving, so the bars fall to rest instead of
    /// freezing mid-spectrum when playback pauses.
    private var lastSampleAt: TimeInterval = -.infinity

    private let tap = SystemAudioTap()
    public let bandCount: Int

    public init(bandCount: Int = 8) {
        self.bandCount = max(1, bandCount)
        self.analyzer = StreamingSpectrumAnalyzer(bandCount: self.bandCount)
        self.levels = .silent(bandCount: self.bandCount)
    }

    public var currentStatus: Status {
        lock.lock(); defer { lock.unlock() }
        return status
    }

    public var isRunning: Bool {
        if case .running = currentStatus { return true }
        return false
    }

    /// Return the latest levels, fading to silence if no new audio arrives. Pausing
    /// shouldn't leave the bars stuck at their last height.
    public func latestLevels() -> AudioLevels {
        lock.lock()
        defer { lock.unlock() }

        let age = ProcessInfo.processInfo.systemUptime - lastSampleAt
        guard age > 0.1 else { return levels }
        if age > 1.5 { return .silent(bandCount: bandCount) }
        let fade = Float(exp(-(age - 0.1) / 0.12))
        return AudioLevels(bands: levels.bands.map { $0 * fade },
                           level: levels.level * fade, isBeat: false,
                           beatIntensity: levels.beatIntensity * fade)
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
        analyzer = StreamingSpectrumAnalyzer(bandCount: bandCount)
        lastSampleAt = -.infinity
        lock.unlock()
    }

    /// Analyses one block. Runs on Core Audio's IO queue.
    private func consume(_ channels: [[Float]], sampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSampleAt > 0.25 {
            analyzer = StreamingSpectrumAnalyzer(bandCount: bandCount)
            levels = .silent(bandCount: bandCount)
            lastSampleAt = now
        }
        if let analyzed = analyzer.consume(channels, sampleRate: sampleRate) {
            levels = analyzed
            lastSampleAt = now
        }
    }
}
