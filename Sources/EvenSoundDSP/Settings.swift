import Foundation

public enum Intensity: String, CaseIterable, Codable, Sendable, Identifiable {
    case gentle, balanced, strong

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .gentle: "Gentle"
        case .balanced: "Balanced"
        case .strong: "Strong"
        }
    }
}

/// Highest level any sound may reach after processing.
public enum LoudnessCeiling: String, CaseIterable, Codable, Sendable, Identifiable {
    case standard, lower, lowest

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: "Standard"
        case .lower: "Lower"
        case .lowest: "Lowest"
        }
    }

    var decibels: Double {
        switch self {
        case .standard: -1
        case .lower: -3
        case .lowest: -6
        }
    }
}

/// How quiet a sound must be before it is treated as background noise and not raised.
public enum NoiseProtection: String, CaseIterable, Codable, Sendable, Identifiable {
    case low, medium, high

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    var gateLUFS: Double {
        switch self {
        case .low: -60
        case .medium: -50
        case .high: -42
        }
    }
}

public enum BalanceProfile: String, CaseIterable, Codable, Sendable, Identifiable {
    case thresholds, curve

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .thresholds: "Fixed limits"
        case .curve: "Smooth (recommended)"
        }
    }
}

/// Arctan level curve: output approaches `maximum` for loud input and `minimum` for quiet input,
/// passes through the midpoint unchanged and has slope `slope` there.
public enum LevelCurve {
    public static func output(_ level: Double, minimum: Double, maximum: Double, slope: Double) -> Double {
        let centre = (minimum + maximum) / 2
        let half = max((maximum - minimum) / 2, 0.5)
        return centre + half * (2 / .pi) * atan(slope * (level - centre) * .pi / (2 * half))
    }

    /// Maps the "Flatten" control (0...1) to the slope at the midpoint.
    public static func slope(flatten: Double) -> Double {
        1.5 - 1.3 * min(max(flatten, 0), 1)
    }
}

/// User-facing settings. Slider values are positions in 0...1, not calibrated audio values.
public struct SoundSettings: Equatable, Codable, Sendable {
    public var isEnabled = true
    public var quietBoost = 0.65
    public var loudReduction = 0.80
    public var intensity = Intensity.balanced
    public var ceiling = LoudnessCeiling.standard
    public var noiseProtection = NoiseProtection.medium
    public var lowLatency = false
    /// Loudness (LUFS) above which sound is turned down.
    public var peakThresholdDB = -20.0
    /// Loudness (LUFS) below which sound is raised (toward this level).
    public var quietThresholdDB = -22.0

    public static let peakThresholdRange = -40.0 ... -6.0
    public static let quietThresholdRange = -50.0 ... -10.0

    public var profile = BalanceProfile.curve
    /// Smooth-curve profile: quiet sound approaches `curveMinDB`, loud sound approaches `curveMaxDB`.
    public var curveMinDB = -30.0
    public var curveMaxDB = -16.0
    public var curveFlatten = 0.4

    public static let curveMinRange = -50.0 ... -10.0
    public static let curveMaxRange = -40.0 ... -6.0
    public static let curveMinimumGap = 2.0

    public init() {}
}

public struct ProcessingParameters: Equatable, Sendable {
    /// Quiet threshold: quiet sound is lifted toward this level.
    public var targetLUFS = -22.0
    /// Share (0...1) of the gap below `targetLUFS` that is filled.
    public var quietAmount = 0.0
    /// Safety cap on the lift so near-silence and hiss are never blasted.
    public var maxBoostDB = 20.0
    /// Peak threshold and the share (0...1) of any excess above it that is removed.
    public var sustainedThresholdLUFS = -20.0
    public var sustainedAmount = 0.0
    public var sustainedAttack = 0.050
    public var sustainedRelease = 0.300
    /// Fast stage for sudden sounds that jump above the steady level.
    public var compressorThresholdLUFS = -14.0
    public var compressorAmount = 0.0
    public var kneeDB = 4.0
    public var compressorAttack = 0.010
    public var compressorRelease = 0.250
    public var levelerTimeConstant = 3.0
    public var levelerRiseRate = 1.5
    public var levelerFallRate = 3.0
    public var gateLUFS = -50.0
    public var silenceHold = 5.0
    public var silenceRelaxRate = 1.0
    public var ceilingDB = -1.0
    public var limiterRelease = 0.100
    public var bypass = false
    /// Smooth-curve profile.
    public var useCurve = false
    public var curveMinLUFS = -30.0
    public var curveMaxLUFS = -16.0
    public var curveSlope = 1.0

    public init() {}

    public func curveOutput(_ level: Double) -> Double {
        LevelCurve.output(level, minimum: curveMinLUFS, maximum: curveMaxLUFS, slope: curveSlope)
    }

    public init(_ settings: SoundSettings) {
        quietAmount = min(max(settings.quietBoost, 0), 1)
        let loud = min(max(settings.loudReduction, 0), 1)

        // Intensity only changes how quickly EvenSound reacts.
        switch settings.intensity {
        case .gentle:
            (levelerTimeConstant, levelerRiseRate, levelerFallRate) = (4, 0.75, 1.5)
            (sustainedAttack, sustainedRelease) = (0.080, 0.500)
            (compressorAttack, compressorRelease, limiterRelease) = (0.015, 0.400, 0.150)
        case .balanced:
            (levelerTimeConstant, levelerRiseRate, levelerFallRate) = (3, 1.5, 3)
            (sustainedAttack, sustainedRelease) = (0.050, 0.300)
            (compressorAttack, compressorRelease, limiterRelease) = (0.010, 0.250, 0.100)
        case .strong:
            (levelerTimeConstant, levelerRiseRate, levelerFallRate) = (2, 3, 5)
            (sustainedAttack, sustainedRelease) = (0.030, 0.200)
            (compressorAttack, compressorRelease, limiterRelease) = (0.005, 0.150, 0.060)
        }

        sustainedThresholdLUFS = min(max(settings.peakThresholdDB, SoundSettings.peakThresholdRange.lowerBound),
                                     SoundSettings.peakThresholdRange.upperBound)
        let quiet = min(max(settings.quietThresholdDB, SoundSettings.quietThresholdRange.lowerBound),
                        SoundSettings.quietThresholdRange.upperBound)
        targetLUFS = min(quiet, sustainedThresholdLUFS)
        sustainedAmount = loud
        compressorThresholdLUFS = sustainedThresholdLUFS + 6
        compressorAmount = loud
        if settings.profile == .curve {
            useCurve = true
            curveMaxLUFS = min(max(settings.curveMaxDB, SoundSettings.curveMaxRange.lowerBound), SoundSettings.curveMaxRange.upperBound)
            curveMinLUFS = min(max(settings.curveMinDB, SoundSettings.curveMinRange.lowerBound),
                               curveMaxLUFS - SoundSettings.curveMinimumGap)
            curveSlope = LevelCurve.slope(flatten: settings.curveFlatten)
            // Sudden bangs above the ceiling are still caught by the fast stage.
            compressorThresholdLUFS = curveMaxLUFS + 3
            compressorAmount = 0.9 * loud
        }
        gateLUFS = settings.noiseProtection.gateLUFS
        ceilingDB = settings.ceiling.decibels
        bypass = !settings.isEnabled
    }
}
