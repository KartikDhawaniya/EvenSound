import Foundation

/// Finds the system volume at which recent sound naturally sits in the user's range, so it needs the least correcting.
public enum VolumeAdvisor {
    /// About 30 seconds of sound at 10 readings per second.
    public static let minimumReadings = 300

    public struct Advice: Equatable, Sendable {
        /// Volume offset (dB from the reference volume) that needs the least correction.
        public var offsetDB: Double
        /// Average dB by which heard sound falls outside the range, at the current and suggested volume.
        public var currentCorrectionDB: Double
        public var suggestedCorrectionDB: Double
    }

    /// Average distance (dB) outside `quietest...loudest` once `offset` is added to each signal level.
    public static func averageCorrection(_ levels: [Double], offset: Double, quietest: Double, loudest: Double) -> Double {
        guard !levels.isEmpty else { return 0 }
        var total = 0.0
        for level in levels {
            let heard = level + offset
            if heard > loudest { total += heard - loudest } else if heard < quietest { total += quietest - heard }
        }
        return total / Double(levels.count)
    }

    /// `signalLevels` are loudness readings before the Mac's volume, taken while sound was playing.
    public static func advise(
        signalLevels: [Double],
        currentOffset: Double,
        quietest: Double,
        loudest: Double,
        possibleOffsets: ClosedRange<Double>
    ) -> Advice? {
        guard signalLevels.count >= minimumReadings, possibleOffsets.upperBound > possibleOffsets.lowerBound else { return nil }
        let median = signalLevels.sorted()[signalLevels.count / 2]
        let centre = (quietest + loudest) / 2
        var best = possibleOffsets.lowerBound
        var bestCost = Double.infinity
        var offset = possibleOffsets.lowerBound
        while offset <= possibleOffsets.upperBound {
            // Among equally good volumes, prefer the one that puts typical sound mid-range.
            let cost = averageCorrection(signalLevels, offset: offset, quietest: quietest, loudest: loudest)
                + 0.01 * abs(median + offset - centre)
            if cost < bestCost { (best, bestCost) = (offset, cost) }
            offset += 0.5
        }
        return Advice(
            offsetDB: best,
            currentCorrectionDB: averageCorrection(signalLevels, offset: currentOffset, quietest: quietest, loudest: loudest),
            suggestedCorrectionDB: averageCorrection(signalLevels, offset: best, quietest: quietest, loudest: loudest))
    }
}
