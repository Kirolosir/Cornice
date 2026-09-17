import Foundation
import Accelerate

/// Real forward FFT via vDSP.
///
/// Accelerate rather than a hand-rolled transform: this runs on every audio
/// block, and vDSP uses the vector units. A naive Swift DFT at this rate would
/// be a measurable share of a core, which for a decorative visualiser is
/// indefensible.
public enum FFT {

    /// Setup objects are expensive to create and safe to share for reads, so
    /// one is kept per transform length.
    private final class SetupCache: @unchecked Sendable {
        private let lock = NSLock()
        private var setups: [Int: FFTSetup] = [:]

        func setup(for log2n: Int) -> FFTSetup? {
            lock.lock()
            defer { lock.unlock() }
            if let existing = setups[log2n] { return existing }
            guard let created = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else {
                return nil
            }
            setups[log2n] = created
            return created
        }
    }

    private static let cache = SetupCache()

    /// Magnitude spectrum of `samples`, Hann-windowed and zero-padded or
    /// truncated to `size`.
    ///
    /// - Returns: `size / 2` magnitudes, bin 0 being DC.
    public static func magnitudes(of samples: [Float], size: Int) -> [Float] {
        let fftSize = max(64, nextPowerOfTwo(size))
        let halfSize = fftSize / 2
        let log2n = Int(log2(Double(fftSize)))

        guard let setup = cache.setup(for: log2n) else {
            return Array(repeating: 0, count: halfSize)
        }

        // Window then pad. A rectangular window would smear every tone across
        // neighbouring bins (spectral leakage), which shows up as bars that all
        // move together instead of independently.
        var windowed = [Float](repeating: 0, count: fftSize)
        let count = min(samples.count, fftSize)
        var window = [Float](repeating: 0, count: count)
        vDSP_hann_window(&window, vDSP_Length(count), Int32(vDSP_HANN_NORM))
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(count))

        var real = [Float](repeating: 0, count: halfSize)
        var imaginary = [Float](repeating: 0, count: halfSize)
        var magnitudes = [Float](repeating: 0, count: halfSize)

        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(
                    realp: realPointer.baseAddress!,
                    imagp: imaginaryPointer.baseAddress!
                )

                // Pack the real signal into the split-complex form vDSP wants.
                windowed.withUnsafeBufferPointer { pointer in
                    pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(halfSize))
                    }
                }

                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(halfSize))
            }
        }

        // vDSP's real FFT returns values scaled by 2N; normalise so magnitudes
        // are comparable to the input amplitude regardless of window length.
        var scale = Float(1.0 / Float(fftSize))
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(halfSize))

        return magnitudes
    }

    static func nextPowerOfTwo(_ value: Int) -> Int {
        guard value > 1 else { return 1 }
        return 1 << Int(ceil(log2(Double(value))))
    }
}
