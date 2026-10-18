import AudioToolbox
import CoreAudio
import EvenSoundDSP
import Foundation
import os

/// Everything the real-time I/O callback touches. Allocated before audio starts.
private final class RenderContext: @unchecked Sendable {
    let processor: SoundProcessor
    let channels: Int
    let maxFrames = 1024
    let scratchIn: UnsafeMutablePointer<Float>
    let scratchOut: UnsafeMutablePointer<Float>
    let lastCallback = OSAllocatedUnfairLock(initialState: UInt64(0))

    init(processor: SoundProcessor) {
        self.processor = processor
        channels = processor.channels
        scratchIn = .allocate(capacity: maxFrames * channels)
        scratchOut = .allocate(capacity: maxFrames * channels)
        scratchIn.initialize(repeating: 0, count: maxFrames * channels)
        scratchOut.initialize(repeating: 0, count: maxFrames * channels)
    }

    deinit {
        scratchIn.deallocate()
        scratchOut.deallocate()
    }

    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        lastCallback.withLockIfAvailable { $0 = mach_absolute_time() }
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)

        // The tap's channels are the last input channels of the aggregate device.
        var tapBuffers = 0
        var tapChannelTotal = 0
        for index in stride(from: inputs.count - 1, through: 0, by: -1) where tapChannelTotal < channels {
            tapChannelTotal += Int(inputs[index].mNumberChannels)
            tapBuffers += 1
        }
        let firstTapBuffer = inputs.count - tapBuffers

        var inputFrames = Int.max
        for index in firstTapBuffer..<inputs.count {
            let ch = max(1, Int(inputs[index].mNumberChannels))
            inputFrames = min(inputFrames, Int(inputs[index].mDataByteSize) / (4 * ch))
        }
        var outputFrames = Int.max
        for buffer in outputs {
            let ch = max(1, Int(buffer.mNumberChannels))
            outputFrames = min(outputFrames, Int(buffer.mDataByteSize) / (4 * ch))
        }
        if tapBuffers == 0 || tapChannelTotal != channels || inputFrames == .max { inputFrames = 0 }
        if outputFrames == .max { outputFrames = 0 }
        let frames = min(inputFrames, outputFrames)

        var done = 0
        while done < frames {
            let n = min(maxFrames, frames - done)
            var channel = 0
            for index in firstTapBuffer..<inputs.count {
                let ch = Int(inputs[index].mNumberChannels)
                guard let data = inputs[index].mData?.assumingMemoryBound(to: Float.self) else {
                    for c in 0..<ch { for f in 0..<n { scratchIn[f * channels + channel + c] = 0 } }
                    channel += ch
                    continue
                }
                for c in 0..<ch {
                    for f in 0..<n { scratchIn[f * channels + channel + c] = data[(done + f) * ch + c] }
                }
                channel += ch
            }

            processor.process(input: scratchIn, output: scratchOut, frameCount: n)

            var outChannel = 0
            for buffer in outputs {
                let ch = Int(buffer.mNumberChannels)
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                    outChannel += ch
                    continue
                }
                for c in 0..<ch {
                    let global = outChannel + c
                    let source = global < channels ? global : (channels == 1 ? 0 : -1)
                    for f in 0..<n {
                        data[(done + f) * ch + c] = source >= 0 ? scratchOut[f * channels + source] : 0
                    }
                }
                outChannel += ch
            }
            done += n
        }

        // Silence anything we didn't fill.
        for buffer in outputs {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let ch = max(1, Int(buffer.mNumberChannels))
            let total = Int(buffer.mDataByteSize) / 4
            if frames * ch < total { (data + frames * ch).update(repeating: 0, count: total - frames * ch) }
        }
    }
}

/// Captures audio headed for one output device (excluding our own process), mutes the original
/// while we read it, and plays the processed result on that same device.
final class TapEngine {
    private(set) var deviceID: AudioDeviceID = kAudioObjectUnknown
    private(set) var processor: SoundProcessor?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var context: RenderContext?

    var isRunning: Bool { procID != nil }

    /// Seconds since the audio callback last ran, or nil if not running.
    var secondsSinceLastCallback: Double? {
        guard let context, isRunning else { return nil }
        let last = context.lastCallback.withLock { $0 }
        guard last > 0 else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let elapsed = mach_absolute_time() - last
        return Double(elapsed) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    func start(device: AudioDeviceID, parameters: ProcessingParameters, lowLatency: Bool) throws {
        stop()
        do {
            try startUnchecked(device: device, parameters: parameters, lowLatency: lowLatency)
        } catch {
            stop()
            throw error
        }
    }

    private func startUnchecked(device: AudioDeviceID, parameters: ProcessingParameters, lowLatency: Bool) throws {
        let outputUID = try AudioDevices.uid(device)
        let ownProcess = AudioDevices.currentProcessObject()
        let excluded = ownProcess == kAudioObjectUnknown ? [] : [ownProcess]

        let description = CATapDescription(excludingProcesses: excluded, deviceUID: outputUID, stream: 0)
        description.name = "EvenSound"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var newTap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &newTap), "Couldn't start listening to system audio")
        tapID = newTap

        let tapFormat: AudioStreamBasicDescription = try AudioObject.value(
            tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        let channels = Int(tapFormat.mChannelsPerFrame)
        guard channels > 0, tapFormat.mFormatID == kAudioFormatLinearPCM,
              tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0, tapFormat.mBitsPerChannel == 32 else {
            throw CoreAudioError("This output device uses an audio format EvenSound can't process yet")
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "EvenSound",
            kAudioAggregateDeviceUIDKey: "\(AudioDevices.aggregateUIDPrefix).\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        try check(
            AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregate),
            "Couldn't connect to the output device")
        aggregateID = newAggregate

        var bufferFrames = UInt32(lowLatency ? 128 : 256)
        var bufferAddress = AudioObject.address(kAudioDevicePropertyBufferFrameSize)
        _ = AudioObjectSetPropertyData(aggregateID, &bufferAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &bufferFrames)

        let sampleRate = (try? AudioDevices.nominalSampleRate(aggregateID)).flatMap { $0 > 0 ? $0 : nil }
            ?? tapFormat.mSampleRate
        let processor = SoundProcessor(
            sampleRate: sampleRate,
            channels: channels,
            lookahead: lowLatency ? 0.001 : 0.003,
            parameters: parameters)
        let context = RenderContext(processor: processor)

        var newProc: AudioDeviceIOProcID?
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, nil) { _, input, _, output, _ in
                context.render(input: input, output: output)
            },
            "Couldn't start audio processing")
        procID = newProc
        self.processor = processor
        self.context = context
        deviceID = device

        try check(AudioDeviceStart(aggregateID, procID), "Couldn't start the output device")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        context = nil
        processor = nil
        deviceID = kAudioObjectUnknown
    }

    deinit { stop() }
}
