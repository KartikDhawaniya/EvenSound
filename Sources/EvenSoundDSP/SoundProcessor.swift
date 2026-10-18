import Foundation
import os

/// Live values for the UI. Levels are in dB / LUFS.
public struct ProcessorMeters: Equatable, Sendable {
    public var inputLUFS = -120.0
    /// Loudness right now (about 150 ms average), before and after processing.
    public var currentInputLUFS = -120.0
    public var currentOutputLUFS = -120.0
    public var levelerGainDB = 0.0
    public var compressorGainDB = 0.0
    public var limiterGainDB = 0.0
    public var outputPeakDB = -120.0
    public var soundPresent = false

    public init() {}
}

/// Real-time loudness balancer: leveler -> compressor -> look-ahead true-peak limiter, with a
/// latency-aligned bypass crossfade. `process` is allocation-free and never blocks.
public final class SoundProcessor: @unchecked Sendable {
    public let sampleRate: Double
    public let channels: Int
    public let lookaheadFrames: Int
    /// Delay added to the audio path, in frames.
    public let latencyFrames: Int

    private struct ParameterState {
        var parameters: ProcessingParameters
        var version: Int
    }

    private let parameterLock: OSAllocatedUnfairLock<ParameterState>
    private let meterLock = OSAllocatedUnfairLock(initialState: ProcessorMeters())
    private var appliedVersion = -1
    private var params: ProcessingParameters

    // Sidechain.
    private let filters: UnsafeMutablePointer<Biquad>
    private var meanSquareSlow = 0.0
    private var meanSquareSustained = 0.0
    private var meanSquareFast = 0.0
    private let slowCoef: Double
    private let sustainedCoef: Double
    private let fastCoef: Double

    // Leveler (control rate). Only raises quiet sound.
    private let controlInterval = 32
    private var controlCounter = 0
    private var levelerGain = 0.0
    private var levelerEnd = 0.0
    private var levelerStep = 0.0
    private var silentTime = 0.0
    /// After a settings change the leveler moves quickly so the change is heard at once.
    private var settleRemaining = 0.0
    private var hasAppliedParameters = false

    // Sustained-loudness compressor.
    private var sustainedGain = 0.0
    private var sustainedAttackCoef = 0.0
    private var sustainedReleaseCoef = 0.0

    // Fast compressor.
    private var compressorGain = 0.0
    private var compressorAttackCoef = 0.0
    private var compressorReleaseCoef = 0.0

    // Limiter.
    private var ceiling = 1.0
    private var limiterReleaseBeta = 0.0
    private var limiterEnvelope = 1.0
    private let history: UnsafeMutablePointer<Double>
    private let phaseCoefficients: UnsafeMutablePointer<Double>
    private let holdLength: Int
    private let minValues: UnsafeMutablePointer<Double>
    private let minIndices: UnsafeMutablePointer<Int>
    private var minHead = 0
    private var minCount = 0
    private var sampleIndex = 0
    private let boxLength: Int
    private let boxRing: UnsafeMutablePointer<Double>
    private var boxPosition = 0
    private var boxSum: Double
    private var lastLimiterGain = 1.0

    // Delay lines.
    private let delayLength: Int
    private let wetDelay: UnsafeMutablePointer<Double>
    private let dryDelay: UnsafeMutablePointer<Double>
    private var writeIndex = 0
    private let frameScratch: UnsafeMutablePointer<Double>

    // Bypass crossfade.
    private var mix = 1.0
    private var mixTarget = 1.0
    private let mixStep: Double

    public init(
        sampleRate: Double,
        channels: Int,
        lookahead: Double = 0.003,
        parameters: ProcessingParameters = ProcessingParameters()
    ) {
        precondition(sampleRate > 0 && channels > 0)
        self.sampleRate = sampleRate
        self.channels = channels
        lookaheadFrames = max(8, Int((lookahead * sampleRate).rounded()))
        let interpolatorDelay = TruePeak.taps - 1 - TruePeak.centre
        latencyFrames = lookaheadFrames + interpolatorDelay
        holdLength = lookaheadFrames + interpolatorDelay + 1
        boxLength = lookaheadFrames + 1
        delayLength = latencyFrames + 1
        params = parameters
        parameterLock = OSAllocatedUnfairLock(initialState: ParameterState(parameters: parameters, version: 0))

        slowCoef = 1 - exp(-1 / (0.4 * sampleRate))
        sustainedCoef = 1 - exp(-1 / (0.15 * sampleRate))
        fastCoef = 1 - exp(-1 / (0.020 * sampleRate))

        let k = KWeighting.filters(sampleRate: sampleRate)
        filters = .allocate(capacity: channels * 2)
        for c in 0..<channels {
            (filters + 2 * c).initialize(to: k.shelf)
            (filters + 2 * c + 1).initialize(to: k.highPass)
        }

        history = .allocate(capacity: channels * TruePeak.taps)
        history.initialize(repeating: 0, count: channels * TruePeak.taps)
        phaseCoefficients = .allocate(capacity: 3 * TruePeak.taps)
        for (p, phase) in TruePeak.phases.enumerated() {
            for (t, v) in phase.enumerated() { phaseCoefficients[p * TruePeak.taps + t] = v }
        }
        minValues = .allocate(capacity: holdLength + 1)
        minValues.initialize(repeating: 1, count: holdLength + 1)
        minIndices = .allocate(capacity: holdLength + 1)
        minIndices.initialize(repeating: 0, count: holdLength + 1)
        boxRing = .allocate(capacity: boxLength)
        boxRing.initialize(repeating: 1, count: boxLength)
        boxSum = Double(boxLength)

        wetDelay = .allocate(capacity: delayLength * channels)
        wetDelay.initialize(repeating: 0, count: delayLength * channels)
        dryDelay = .allocate(capacity: delayLength * channels)
        dryDelay.initialize(repeating: 0, count: delayLength * channels)
        frameScratch = .allocate(capacity: channels)
        frameScratch.initialize(repeating: 0, count: channels)

        mixStep = 1 / (0.050 * sampleRate)
        applyParameters(parameters)
        mix = mixTarget
    }

    deinit {
        filters.deallocate()
        history.deallocate()
        phaseCoefficients.deallocate()
        minValues.deallocate()
        minIndices.deallocate()
        boxRing.deallocate()
        wetDelay.deallocate()
        dryDelay.deallocate()
        frameScratch.deallocate()
    }

    /// Thread-safe; picked up at the start of the next processed block.
    public func setParameters(_ parameters: ProcessingParameters) {
        parameterLock.withLock {
            $0.parameters = parameters
            $0.version += 1
        }
    }

    public var meters: ProcessorMeters {
        meterLock.withLock { $0 }
    }

    /// Processes interleaved float frames. `input` and `output` may alias.
    public func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int) {
        if let state = parameterLock.withLockIfAvailable({ $0 }), state.version != appliedVersion {
            appliedVersion = state.version
            applyParameters(state.parameters)
        }

        let channelCount = channels
        let taps = TruePeak.taps
        var outputPeak = 0.0

        for frame in 0..<frameCount {
            let base = frame * channelCount

            var sumSquares = 0.0
            for c in 0..<channelCount {
                var x = Double(input[base + c])
                if !x.isFinite { x = 0 }
                frameScratch[c] = x
                let y = filters[2 * c + 1].process(filters[2 * c].process(x))
                sumSquares += y * y
            }
            if !sumSquares.isFinite { resetSidechain(); sumSquares = 0 }
            meanSquareSlow += slowCoef * (sumSquares - meanSquareSlow)
            meanSquareSustained += sustainedCoef * (sumSquares - meanSquareSustained)
            meanSquareFast += fastCoef * (sumSquares - meanSquareFast)
            let fastLUFS = lufs(fromMeanSquare: meanSquareFast)

            if controlCounter == 0 {
                updateLeveler(fastLUFS: fastLUFS)
                controlCounter = controlInterval
            }
            controlCounter -= 1
            levelerGain += levelerStep

            let sustainedLevel = lufs(fromMeanSquare: meanSquareSustained) + levelerGain
            let sustainedWanted = params.useCurve
                ? min(0, params.curveOutput(sustainedLevel - levelerGain) - sustainedLevel)
                : compressorCurve(sustainedLevel, params.sustainedThresholdLUFS, params.sustainedAmount)
            let sustainedCoef = sustainedWanted < sustainedGain ? sustainedAttackCoef : sustainedReleaseCoef
            sustainedGain = sustainedWanted + sustainedCoef * (sustainedGain - sustainedWanted)

            let wanted = compressorCurve(fastLUFS + levelerGain + sustainedGain, params.compressorThresholdLUFS, params.compressorAmount)
            let coef = wanted < compressorGain ? compressorAttackCoef : compressorReleaseCoef
            compressorGain = wanted + coef * (compressorGain - wanted)

            let gain = pow(10, (levelerGain + sustainedGain + compressorGain) / 20)

            var peak = 0.0
            for c in 0..<channelCount {
                let u = frameScratch[c] * gain
                let h = history + c * taps
                h.update(from: h + 1, count: taps - 1)
                h[taps - 1] = u
                peak = max(peak, abs(u))
                for p in 0..<3 {
                    let coefficients = phaseCoefficients + p * taps
                    var v = 0.0
                    for t in 0..<taps { v += h[t] * coefficients[t] }
                    peak = max(peak, abs(v))
                }
                wetDelay[writeIndex * channelCount + c] = u
                dryDelay[writeIndex * channelCount + c] = frameScratch[c]
            }

            let required = peak > ceiling ? ceiling / peak : 1
            limiterEnvelope = min(required, limiterEnvelope + (1 - limiterEnvelope) * limiterReleaseBeta)
            let held = pushMinimum(limiterEnvelope)
            boxSum += held - boxRing[boxPosition]
            boxRing[boxPosition] = held
            boxPosition += 1
            if boxPosition == boxLength { boxPosition = 0 }
            let limiterGain = min(1, boxSum / Double(boxLength))
            lastLimiterGain = limiterGain

            if mix != mixTarget {
                mix = mix < mixTarget ? min(mixTarget, mix + mixStep) : max(mixTarget, mix - mixStep)
            }

            var readIndex = writeIndex + 1
            if readIndex == delayLength { readIndex = 0 }
            for c in 0..<channelCount {
                let wet = min(ceiling, max(-ceiling, wetDelay[readIndex * channelCount + c] * limiterGain))
                let dry = dryDelay[readIndex * channelCount + c]
                let out = dry + mix * (wet - dry)
                outputPeak = max(outputPeak, abs(out))
                output[base + c] = Float(out)
            }
            writeIndex = readIndex
            sampleIndex &+= 1
        }

        var snapshot = ProcessorMeters()
        snapshot.inputLUFS = lufs(fromMeanSquare: meanSquareSlow)
        let nowIn = lufs(fromMeanSquare: meanSquareSustained)
        let processedGain = levelerGain + sustainedGain + compressorGain + 20 * log10(max(lastLimiterGain, 1e-6))
        snapshot.currentInputLUFS = nowIn
        snapshot.currentOutputLUFS = nowIn + mix * processedGain
        snapshot.levelerGainDB = levelerGain
        snapshot.compressorGainDB = sustainedGain + compressorGain
        snapshot.limiterGainDB = 20 * log10(max(lastLimiterGain, 1e-6))
        snapshot.outputPeakDB = 20 * log10(max(outputPeak, 1e-6))
        snapshot.soundPresent = lufs(fromMeanSquare: meanSquareFast) >= params.gateLUFS
        let published = snapshot
        meterLock.withLockIfAvailable { $0 = published }
    }

    private func applyParameters(_ p: ProcessingParameters) {
        if hasAppliedParameters, p.quietAmount != params.quietAmount || p.targetLUFS != params.targetLUFS
            || p.useCurve != params.useCurve || p.curveMinLUFS != params.curveMinLUFS
            || p.curveMaxLUFS != params.curveMaxLUFS || p.curveSlope != params.curveSlope {
            settleRemaining = 0.6
        }
        hasAppliedParameters = true
        params = p
        sustainedAttackCoef = exp(-1 / (p.sustainedAttack * sampleRate))
        sustainedReleaseCoef = exp(-1 / (p.sustainedRelease * sampleRate))
        compressorAttackCoef = exp(-1 / (p.compressorAttack * sampleRate))
        compressorReleaseCoef = exp(-1 / (p.compressorRelease * sampleRate))
        ceiling = pow(10, p.ceilingDB / 20)
        limiterReleaseBeta = 1 - exp(-1 / (p.limiterRelease * sampleRate))
        mixTarget = p.bypass ? 0 : 1
    }

    private func updateLeveler(fastLUFS: Double) {
        let dt = Double(controlInterval) / sampleRate
        let settling = settleRemaining > 0
        if settling { settleRemaining -= dt }
        let timeConstant = settling ? 0.05 : params.levelerTimeConstant
        let riseRate = settling ? 40 : params.levelerRiseRate
        let fallRate = settling ? 40 : params.levelerFallRate

        var next = levelerEnd
        if fastLUFS >= params.gateLUFS {
            silentTime = 0
            let slowLUFS = lufs(fromMeanSquare: meanSquareSlow)
            let lift = params.useCurve
                ? params.curveOutput(slowLUFS) - slowLUFS
                : params.quietAmount * (params.targetLUFS - slowLUFS)
            let wanted = min(params.maxBoostDB, max(0, lift))
            let rate = min(riseRate, max(-fallRate, (wanted - next) / timeConstant))
            next += rate * dt
        } else {
            silentTime += dt
            if silentTime > params.silenceHold {
                next = max(0, next - params.silenceRelaxRate * dt)
            }
        }
        if next > params.maxBoostDB { next = max(params.maxBoostDB, next - fallRate * dt) }
        if !next.isFinite { next = 0; levelerGain = 0 }
        levelerStep = (next - levelerGain) / Double(controlInterval)
        levelerEnd = next
    }

    @inline(__always)
    /// Gain change that removes `amount` (0...1) of the excess above `threshold`, with a soft knee.
    private func compressorCurve(_ level: Double, _ threshold: Double, _ amount: Double) -> Double {
        guard amount > 0 else { return 0 }
        let over = level - threshold
        let knee = params.kneeDB
        let slope = -amount
        if over <= -knee / 2 { return 0 }
        if over >= knee / 2 { return slope * over }
        let x = over + knee / 2
        return slope * x * x / (2 * knee)
    }

    /// Sliding minimum over the last `holdLength` samples (monotonic queue).
    @inline(__always)
    private func pushMinimum(_ value: Double) -> Double {
        let capacity = holdLength + 1
        while minCount > 0 {
            let back = (minHead + minCount - 1) % capacity
            if minValues[back] >= value { minCount -= 1 } else { break }
        }
        let slot = (minHead + minCount) % capacity
        minValues[slot] = value
        minIndices[slot] = sampleIndex
        minCount += 1
        while minIndices[minHead] <= sampleIndex &- holdLength {
            minHead = (minHead + 1) % capacity
            minCount -= 1
        }
        return minValues[minHead]
    }

    private func resetSidechain() {
        let k = KWeighting.filters(sampleRate: sampleRate)
        for c in 0..<channels {
            filters[2 * c] = k.shelf
            filters[2 * c + 1] = k.highPass
        }
        meanSquareSlow = 0
        meanSquareSustained = 0
        meanSquareFast = 0
    }
}
