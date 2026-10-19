import Testing
@testable import EvenSoundDSP

private func readings(around level: Double, spread: Double, count: Int = 600) -> [Double] {
    (0..<count).map { level - spread / 2 + spread * Double($0) / Double(count - 1) }
}

@Test func suggestsVolumeThatCentresSoundInRange() throws {
    // Sound spans -20...-10 before the volume; the range is -30...-16 (centre -23).
    let advice = try #require(VolumeAdvisor.advise(
        signalLevels: readings(around: -15, spread: 10), currentOffset: 0, quietest: -30, loudest: -16, possibleOffsets: -40...10))
    #expect(abs(advice.offsetDB - -8) <= 1)
    #expect(advice.suggestedCorrectionDB < 0.01)
    #expect(advice.currentCorrectionDB > 1)
}

@Test func widerSoundThanRangeIsSplitEvenly() throws {
    // 30 dB of variation can't fit a 14 dB range; the best volume centres it.
    let advice = try #require(VolumeAdvisor.advise(
        signalLevels: readings(around: -30, spread: 30), currentOffset: 0, quietest: -30, loudest: -16, possibleOffsets: -40...20))
    #expect(abs(advice.offsetDB - 7) <= 1)
}

@Test func suggestionStaysWithinWhatTheDeviceCanDo() throws {
    // Very quiet sound would need +30 dB, but the volume can only go 6 dB higher.
    let advice = try #require(VolumeAdvisor.advise(
        signalLevels: readings(around: -50, spread: 4), currentOffset: 0, quietest: -30, loudest: -16, possibleOffsets: -40...6))
    #expect(advice.offsetDB == 6)
}

@Test func noAdviceUntilEnoughSoundHasBeenHeard() {
    #expect(VolumeAdvisor.advise(
        signalLevels: readings(around: -20, spread: 4, count: 100), currentOffset: 0, quietest: -30, loudest: -16, possibleOffsets: -40...0) == nil)
}
