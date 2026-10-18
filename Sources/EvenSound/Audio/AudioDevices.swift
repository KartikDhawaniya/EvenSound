import CoreAudio
import Foundation

struct CoreAudioError: LocalizedError {
    let message: String
    let status: OSStatus

    init(_ message: String, _ status: OSStatus = 0) {
        self.message = message
        self.status = status
    }

    var errorDescription: String? { status == 0 ? message : "\(message) (code \(status))" }
}

func check(_ status: OSStatus, _ what: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(what(), status) }
}

enum AudioObject {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        default defaultValue: T
    ) throws -> T {
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        var result = defaultValue
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        try check(status, "Couldn't read audio property")
        return result
    }

    static func array<T>(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        of _: T.Type
    ) throws -> [T] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size), "Couldn't read audio property size")
        guard size > 0 else { return [] }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }
        try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buffer), "Couldn't read audio property")
        let count = Int(size) / MemoryLayout<T>.stride
        let typed = buffer.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: count))
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value), "Couldn't read audio name")
        return (value?.takeRetainedValue() as String?) ?? ""
    }
}

struct OutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioDevices {
    static let aggregateUIDPrefix = "com.evensound.aggregate"

    static func defaultOutput() throws -> AudioDeviceID {
        let id: AudioDeviceID = try AudioObject.value(
            AudioObject.system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioDeviceID(kAudioObjectUnknown))
        guard id != kAudioObjectUnknown else { throw CoreAudioError("No output device is selected") }
        return id
    }

    static func setDefaultOutput(_ id: AudioDeviceID) throws {
        var addr = AudioObject.address(kAudioHardwarePropertyDefaultOutputDevice)
        var value = id
        try check(
            AudioObjectSetPropertyData(AudioObject.system, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value),
            "Couldn't change the output device")
    }

    static func uid(_ id: AudioDeviceID) throws -> String {
        try AudioObject.string(id, kAudioDevicePropertyDeviceUID)
    }

    static func name(_ id: AudioDeviceID) -> String {
        (try? AudioObject.string(id, kAudioObjectPropertyName)) ?? "Unknown device"
    }

    static func nominalSampleRate(_ id: AudioDeviceID) throws -> Double {
        try AudioObject.value(id, kAudioDevicePropertyNominalSampleRate, default: Float64(0))
    }

    static func hasOutput(_ id: AudioDeviceID) -> Bool {
        let streams = (try? AudioObject.array(
            id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput, of: AudioStreamID.self)) ?? []
        return !streams.isEmpty
    }

    static func outputDevices() -> [OutputDevice] {
        let ids = (try? AudioObject.array(AudioObject.system, kAudioHardwarePropertyDevices, of: AudioDeviceID.self)) ?? []
        return ids.compactMap { id in
            guard hasOutput(id), let uid = try? uid(id), !uid.hasPrefix(aggregateUIDPrefix) else { return nil }
            return OutputDevice(id: id, uid: uid, name: name(id))
        }
    }

    static func currentProcessObject() -> AudioObjectID {
        var addr = AudioObject.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObject.system, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr ? object : AudioObjectID(kAudioObjectUnknown)
    }
}
