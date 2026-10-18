import Foundation

/// Transposed direct form II biquad (a0 normalised to 1).
struct Biquad {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    var z1 = 0.0, z2 = 0.0

    @inline(__always)
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

/// ITU-R BS.1770 K-weighting, derived for any sample rate (same analog prototype as libebur128).
public enum KWeighting {
    static func filters(sampleRate fs: Double) -> (shelf: Biquad, highPass: Biquad) {
        var f0 = 1681.974450955533
        let gain = 3.999843853973347
        var q = 0.7071752369554196
        var k = tan(.pi * f0 / fs)
        let vh = pow(10, gain / 20)
        let vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = Biquad(
            b0: (vh + vb * k / q + k * k) / a0,
            b1: 2 * (k * k - vh) / a0,
            b2: (vh - vb * k / q + k * k) / a0,
            a1: 2 * (k * k - 1) / a0,
            a2: (1 - k / q + k * k) / a0
        )

        f0 = 38.13547087602444
        q = 0.5003270373238773
        k = tan(.pi * f0 / fs)
        a0 = 1 + k / q + k * k
        let highPass = Biquad(
            b0: 1, b1: -2, b2: 1,
            a1: 2 * (k * k - 1) / a0,
            a2: (1 - k / q + k * k) / a0
        )
        return (shelf, highPass)
    }

    /// Coefficients as (b0, b1, b2, a1, a2) for testing.
    public static func coefficients(sampleRate: Double) -> [[Double]] {
        let f = filters(sampleRate: sampleRate)
        return [f.shelf, f.highPass].map { [$0.b0, $0.b1, $0.b2, $0.a1, $0.a2] }
    }
}

@inline(__always)
func lufs(fromMeanSquare ms: Double) -> Double {
    -0.691 + 10 * log10(max(ms, 1e-15))
}

/// 4x oversampling interpolator used to estimate inter-sample ("true") peaks.
enum TruePeak {
    static let taps = 12
    static let centre = 5

    /// Three fractional phases (0.25, 0.5, 0.75) between history[centre] and history[centre + 1].
    static let phases: [[Double]] = [0.25, 0.5, 0.75].map { frac in
        var h = (0..<taps).map { k -> Double in
            let t = Double(k - centre) - frac
            let sinc = t == 0 ? 1 : sin(.pi * t) / (.pi * t)
            let window = 0.5 * (1 + cos(.pi * t / 6.5))
            return sinc * window
        }
        let sum = h.reduce(0, +)
        h = h.map { $0 / sum }
        return h
    }
}
