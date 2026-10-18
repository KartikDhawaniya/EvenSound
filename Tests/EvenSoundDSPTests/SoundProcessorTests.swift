import Foundation
import Testing
@testable import EvenSoundDSP

private let sampleRate = 48_000.0

private func sine(frequency: Double, amplitude: Double, seconds: Double, channels: Int = 2, phase: Double = 0) -> [Float] {
    let frames = Int(seconds * sampleRate)
    var out = [Float](repeating: 0, count: frames * channels)
    for n in 0..<frames {
        let v = Float(amplitude * sin(2 * .pi * frequency * Double(n) / sampleRate + phase))
        for c in 0..<channels { out[n * channels + c] = v }
    }
    return out
}

private func run(_ processor: SoundProcessor, _ input: [Float], blockSize: Int = 512) -> [Float] {
    var output = [Float](repeating: 0, count: input.count)
    let ch = processor.channels
    let frames = input.count / ch
    input.withUnsafeBufferPointer { inp in
        output.withUnsafeMutableBufferPointer { out in
            var start = 0
            while start < frames {
                let n = min(blockSize, frames - start)
                processor.process(input: inp.baseAddress! + start * ch, output: out.baseAddress! + start * ch, frameCount: n)
                start += n
            }
        }
    }
    return output
}

private func rmsDB(_ samples: ArraySlice<Float>) -> Double {
    let ms = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
    return 10 * log10(max(ms, 1e-20))
}

private func settings(quiet: Double, loud: Double, enabled: Bool = true) -> ProcessingParameters {
    var s = SoundSettings()
    s.quietBoost = quiet
    s.loudReduction = loud
    s.isEnabled = enabled
    return ProcessingParameters(s)
}

@Test func kWeightingMatchesBS1770At48k() {
    let c = KWeighting.coefficients(sampleRate: 48_000)
    let expected: [[Double]] = [
        [1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585],
        [1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621],
    ]
    for (row, exp) in zip(c, expected) {
        for (a, b) in zip(row, exp) { #expect(abs(a - b) < 1e-6) }
    }
}

@Test func defaultsMapToDocumentedValues() {
    let p = ProcessingParameters(SoundSettings())
    #expect(abs(p.maxBoostDB - 7.8) < 1e-9)
    #expect(abs(p.sustainedThresholdLUFS - -20) < 1e-9)
    #expect(abs(p.sustainedRatio - 5) < 1e-9)
    #expect(abs(p.compressorThresholdLUFS - -14) < 1e-9)
    #expect(abs(p.compressorRatio - 4.2) < 1e-9)
    #expect(p.ceilingDB == -1)
}

private func steadyGain(_ processor: SoundProcessor, amplitude: Double, seconds: Double, lastSeconds: Double = 0.1) -> Double {
    let input = sine(frequency: 1000, amplitude: amplitude, seconds: seconds)
    let output = run(processor, input)
    let tail = input.count - Int(lastSeconds * sampleRate) * 2
    return rmsDB(output[tail...]) - rmsDB(input[tail...])
}

@Test func loudSliderControlsHowMuchSteadyLoudSoundIsReduced() {
    func gain(_ loud: Double) -> Double {
        steadyGain(SoundProcessor(sampleRate: sampleRate, channels: 2, parameters: settings(quiet: 0.65, loud: loud)), amplitude: 0.5, seconds: 3)
    }
    #expect(abs(gain(0)) < 0.5)
    #expect(abs(gain(0.4) - -9.6) < 1)
    #expect(abs(gain(1) - -11.7) < 1)
}

@Test func peakThresholdSetsWhereLoudSoundSettles() {
    var s = SoundSettings()
    s.peakThresholdDB = -30
    let gain = steadyGain(SoundProcessor(sampleRate: sampleRate, channels: 2, parameters: ProcessingParameters(s)), amplitude: 0.5, seconds: 3)
    #expect(abs(gain - -19.6) < 1)
}

@Test func currentLevelMetersTrackInputAndOutput() {
    let p = SoundProcessor(sampleRate: sampleRate, channels: 2, parameters: settings(quiet: 0.65, loud: 0.8))
    _ = steadyGain(p, amplitude: 0.5, seconds: 3)
    #expect(abs(p.meters.currentInputLUFS - -6) < 0.5)
    #expect(abs(p.meters.currentOutputLUFS - -17.2) < 1)
}

@Test func loudSliderTakesEffectWithinAFractionOfASecond() {
    let p = SoundProcessor(sampleRate: sampleRate, channels: 2, parameters: settings(quiet: 0.65, loud: 0.2))
    let before = steadyGain(p, amplitude: 0.5, seconds: 5)
    p.setParameters(settings(quiet: 0.65, loud: 1))
    let after = steadyGain(p, amplitude: 0.5, seconds: 0.3)
    #expect(abs(before - -7.7) < 1)
    #expect(after < -10.5)
}

@Test func quietSliderTakesEffectWithinAFractionOfASecond() {
    let p = SoundProcessor(sampleRate: sampleRate, channels: 2, parameters: settings(quiet: 0.2, loud: 0.8))
    let before = steadyGain(p, amplitude: 0.0293, seconds: 10)
    p.setParameters(settings(quiet: 1, loud: 0.8))
    let after = steadyGain(p, amplitude: 0.0293, seconds: 0.6)
    #expect(abs(before - 2.4) < 0.5)
    #expect(after > before + 5)
}

@Test func quietThresholdSetsWhereQuietSoundIsRaisedTo() {
    var s = SoundSettings()
    s.quietBoost = 1
    s.quietThresholdDB = -26
    let p = SoundProcessor(sampleRate: sampleRate, channels: 2, parameters: ProcessingParameters(s))
    // About -30.7 LUFS in, raised to the -26 threshold rather than the full 12 dB.
    let gain = steadyGain(p, amplitude: 0.0293, seconds: 20, lastSeconds: 2)
    #expect(abs(gain - 4.7) < 0.7)
    #expect(ProcessingParameters(SoundSettings()).targetLUFS == -22)
}

@Test func fullScaleStereoSineMeasuresZeroLUFS() {
    let p = SoundProcessor(sampleRate: sampleRate, channels: 2, parameters: settings(quiet: 0, loud: 0))
    _ = run(p, sine(frequency: 997, amplitude: 1, seconds: 4))
    #expect(abs(p.meters.inputLUFS - 0) < 0.15)
}

@Test func controlsAtZeroAreTransparentBelowCeiling() {
    let p = SoundProcessor(sampleRate: sampleRate, channels: 2, parameters: settings(quiet: 0, loud: 0))
    let input = sine(frequency: 440, amplitude: 0.3, seconds: 1)
    let output = run(p, input)
    let lag = p.latencyFrames * 2
    var maxError: Float = 0
    for i in lag..<input.count { maxError = max(maxError, abs(output[i] - input[i - lag])) }
    #expect(maxError < 1e-5)
}

@Test func limiterNeverExceedsCeilingOnSpikyMaterial() {
    var generator = SystemRandomNumberGenerator()
    let p = SoundProcessor(sampleRate: sampleRate, channels: 2, parameters: settings(quiet: 1, loud: 1))
    var input = sine(frequency: 220, amplitude: 0.4, seconds: 3)
    for _ in 0..<80 {
        let start = Int.random(in: 0..<(input.count - 2000), using: &generator)
        let gain = Float.random(in: 2...12, using: &generator)
        for i in start..<(start + Int.random(in: 2...2000, using: &generator)) { input[i] *= gain }
    }
    let output = run(p, input, blockSize: 333)
    let peak = output.map { abs($0) }.max()!
    #expect(Double(peak) <= pow(10, -1.0 / 20) + 1e-6)
}

@Test func interSamplePeaksAreCaught() {
    // A 12 kHz sine at 45 degrees has sample peaks of 0.707 but a true peak of 1.0.
    var params = settings(quiet: 0, loud: 0)
    params.ceilingDB = -6
    let p = SoundProcessor(sampleRate: sampleRate, channels: 1, parameters: params)
    let input = sine(frequency: 12_000, amplitude: 0.95, seconds: 0.5, channels: 1, phase: .pi / 4)
    let output = run(p, input)
    let samplePeak = output[12_000...].map { abs($0) }.max()!
    // Sample peaks are ~0.67 * gain; true-peak limiting must pull them well below the -6 dB ceiling (0.5).
    #expect(Double(samplePeak) < 0.5 * 0.75)
}

@Test func levelerRaisesQuietDialogueByMaxBoost() {
    let p = SoundProcessor(sampleRate: sampleRate, channels: 2, parameters: settings(quiet: 0.65, loud: 0.8))
    // ~ -30 LUFS speech-band tone.
    let input = sine(frequency: 1000, amplitude: 0.0316 / 1.08, seconds: 20)
    let output = run(p, input)
    let tail = input.count - 96_000
    let gain = rmsDB(output[tail...]) - rmsDB(input[tail...])
    #expect(abs(gain - 7.8) < 0.5)
}

@Test func levelerDoesNotRaiseBackgroundNoise() {
    let p = SoundProcessor(sampleRate: sampleRate, channels: 2, parameters: settings(quiet: 1, loud: 0.8))
    let input = sine(frequency: 1000, amplitude: 0.0005, seconds: 10) // ~ -66 LUFS, below the gate
    let output = run(p, input)
    let tail = input.count - 96_000
    #expect(abs(rmsDB(output[tail...]) - rmsDB(input[tail...])) < 0.2)
}

@Test func compressorQuicklyReducesSuddenLoudSound() {
    let p = SoundProcessor(sampleRate: sampleRate, channels: 2, parameters: settings(quiet: 0.65, loud: 0.8))
    var input = sine(frequency: 1000, amplitude: 0.03, seconds: 10)
    let loud = sine(frequency: 1000, amplitude: 0.6, seconds: 1)
    input.append(contentsOf: loud)
    let output = run(p, input)
    // 100-300 ms into the loud sound (before the slow leveler can do much).
    let start = (10 * 48_000 + 4_800) * 2
    let window = start..<(start + 9_600 * 2)
    let reduction = rmsDB(input[window]) - rmsDB(output[window])
    #expect(reduction > 5)
}

@Test func constantLoudSoundIsBroughtDownToComfortableLevel() {
    let p = SoundProcessor(sampleRate: sampleRate, channels: 2, parameters: settings(quiet: 0.65, loud: 0.8))
    // A 1 kHz stereo sine of amplitude 0.5 measures about -6 LUFS; the reference level is -18 LUFS.
    let input = sine(frequency: 1000, amplitude: 0.5, seconds: 20)
    let output = run(p, input)
    let tail = input.count - 96_000
    let gain = rmsDB(output[tail...]) - rmsDB(input[tail...])
    #expect(abs(gain - -11.2) < 1)
}

@Test func bypassOutputsDelayedOriginal() {
    let p = SoundProcessor(sampleRate: sampleRate, channels: 2, parameters: settings(quiet: 1, loud: 1, enabled: false))
    let input = sine(frequency: 300, amplitude: 0.9, seconds: 0.5)
    let output = run(p, input)
    let lag = p.latencyFrames * 2
    for i in lag..<input.count { #expect(output[i] == input[i - lag]) }
}

@Test func invalidSamplesProduceFiniteSilence() {
    let p = SoundProcessor(sampleRate: sampleRate, channels: 2)
    var input = sine(frequency: 500, amplitude: 0.5, seconds: 0.2)
    for i in stride(from: 0, to: input.count, by: 97) { input[i] = .nan }
    input[100] = .infinity
    let output = run(p, input)
    #expect(output.allSatisfy { $0.isFinite })
}

@Test func blockSizeDoesNotChangeOutput() {
    let input = sine(frequency: 700, amplitude: 0.7, seconds: 2) + sine(frequency: 90, amplitude: 0.05, seconds: 2)
    let a = run(SoundProcessor(sampleRate: sampleRate, channels: 2), input, blockSize: 4096)
    let b = run(SoundProcessor(sampleRate: sampleRate, channels: 2), input, blockSize: 61)
    #expect(a == b)
}

@Test func processesWithinRealTimeBudget() {
    let p = SoundProcessor(sampleRate: sampleRate, channels: 2)
    let input = sine(frequency: 440, amplitude: 0.5, seconds: 10)
    let start = Date()
    _ = run(p, input)
    let elapsed = Date().timeIntervalSince(start)
    // Must be faster than real time even in unoptimised builds running alongside other tests.
    #expect(elapsed < 10)
}
