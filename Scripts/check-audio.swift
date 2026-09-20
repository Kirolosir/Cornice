import Foundation
import CorniceKit

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    print("PASS: \(message)")
}

func tone(_ frequency: Double, rate: Double = 48_000, count: Int = 24_576) -> [Float] {
    (0..<count).map { Float(sin(2 * .pi * frequency * Double($0) / rate)) * 0.12 }
}

func analyze(_ channels: [[Float]], chunks: [Int], rate: Double = 48_000) -> AudioLevels {
    var analyzer = StreamingSpectrumAnalyzer()
    var latest = AudioLevels.silent(bandCount: 8)
    var offset = 0
    var chunk = 0
    while offset < channels[0].count {
        let end = min(channels[0].count, offset + chunks[chunk % chunks.count])
        if let frame = analyzer.consume(channels.map { Array($0[offset..<end]) }, sampleRate: rate) {
            latest = frame
        }
        offset = end
        chunk += 1
    }
    return latest
}

let samples = tone(750)
let reference = analyze([samples], chunks: [1024])
for chunks in [[128], [256], [512], [4096], [71, 333, 2048, 19]] {
    let result = analyze([samples], chunks: chunks)
    check(zip(result.bands, reference.bands).allSatisfy { abs($0 - $1) < 0.00001 },
          "spectrum is independent of callback sizes \(chunks)")
    check(abs(result.level - reference.level) < 0.00001, "loudness is independent of callback sizes")
}
let stereo = analyze([samples, samples], chunks: [256])
let inverted = analyze([samples, samples.map { -$0 }], chunks: [256])
check(zip(stereo.bands, inverted.bands).allSatisfy { abs($0 - $1) < 0.00001 },
      "opposite-phase stereo retains its spectrum")
check(abs(stereo.level - inverted.level) < 0.00001, "opposite-phase stereo retains its loudness")
let panned = analyze([samples, Array(repeating: 0, count: samples.count)], chunks: [256])
check(panned.level > 0.1, "audio in either channel remains visible")
for rate in [44_100.0, 48_000, 96_000] {
    let result = analyze([tone(1500, rate: rate)], chunks: [256], rate: rate)
    let peak = result.bands.enumerated().max { $0.element < $1.element }!.offset
    check(peak == 4, "1.5 kHz stays in its band at \(Int(rate)) Hz")
}
let quiet = analyze([samples.map { $0 * 0.1 }], chunks: [256])
check(quiet.level < reference.level, "quiet passages read lower")
let silence = analyze([samples + Array(repeating: 0, count: 48_000)], chunks: [256])
check(silence.level < 0.001 && silence.bands.allSatisfy { $0 < 0.001 }, "silence settles without stale bars")
var analyzer = StreamingSpectrumAnalyzer()
check(analyzer.consume([[Float](repeating: 1, count: 128)], sampleRate: 48_000) == nil,
      "partial windows wait for enough audio")
_ = analyzer.consume([samples], sampleRate: 48_000)
check(analyzer.consume([[Float](repeating: 0, count: 128)], sampleRate: 96_000) == nil,
      "sample-rate changes discard old partial windows")
let invalid = analyze([[Float](repeating: .nan, count: 2048)], chunks: [256])
check(invalid.bands.allSatisfy { $0.isFinite } && invalid.level == 0, "invalid samples do not poison the analyzer")
print("Audio checks passed")
