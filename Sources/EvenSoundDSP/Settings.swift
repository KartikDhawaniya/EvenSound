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

    public init() {}

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
        gateLUFS = settings.noiseProtection.gateLUFS
        ceilingDB = settings.ceiling.decibels
        bypass = !settings.isEnabled
    }
}
