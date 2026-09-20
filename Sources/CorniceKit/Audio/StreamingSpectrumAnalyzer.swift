import Foundation

/// Accumulates complete, overlapping windows regardless of the device's buffer size.
public struct StreamingSpectrumAnalyzer: Sendable {
    private let bandCount: Int
    private var sampleRate: Double = 0
    private var analyzer: SpectrumAnalyzer
    private var state: SpectrumAnalyzer.State
    private var pending: [[Float]] = []

    public init(bandCount: Int = 8) {
        self.bandCount = max(1, bandCount)
        analyzer = SpectrumAnalyzer(bandCount: self.bandCount)
        state = SpectrumAnalyzer.State(bandCount: self.bandCount)
    }

    public mutating func consume(_ channels: [[Float]], sampleRate rate: Double) -> AudioLevels? {
        guard rate.isFinite, rate >= 8_000, rate <= 384_000,
              !channels.isEmpty, let count = channels.map(\.count).min(), count > 0 else { return nil }
        if rate != sampleRate || pending.count != channels.count {
            sampleRate = rate
            let size = FFT.nextPowerOfTwo(Int(rate * 1024 / 48_000))
            analyzer = SpectrumAnalyzer(bandCount: bandCount, fftSize: size, sampleRate: rate)
            state = SpectrumAnalyzer.State(bandCount: bandCount)
            pending = Array(repeating: [], count: channels.count)
        }
        for index in channels.indices {
            pending[index].append(contentsOf: channels[index].prefix(count).map { $0.isFinite ? $0 : 0 })
        }
        let size = analyzer.fftSize
        let hop = size / 2
        var offset = 0
        var latest: AudioLevels?
        while pending[0].count - offset >= size {
            let window = pending.map { Array($0[offset..<(offset + size)]) }
            latest = analyzer.analyze(channels: window, state: &state, frameDuration: Double(hop) / rate)
            offset += hop
        }
        if offset > 0 {
            for index in pending.indices { pending[index].removeFirst(offset) }
        }
        return latest
    }
}
