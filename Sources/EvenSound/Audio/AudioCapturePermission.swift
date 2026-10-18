import Foundation

/// "System Audio Recording" permission. macOS has no public API to read this permission, so this
/// uses the private TCC functions (fine for direct distribution, not allowed on the Mac App Store).
/// Without them the status is `.unknown` and the first tap creation shows the system prompt.
enum AudioCapturePermission {
    enum Status { case authorized, denied, unknown }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static let preflightFunction: Preflight? = {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: Preflight.self)
    }()

    private static let requestFunction: Request? = {
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(symbol, to: Request.self)
    }()

    static var status: Status {
        guard let preflightFunction else { return .unknown }
        switch preflightFunction(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    static func request(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard let requestFunction else {
            completion(true)
            return
        }
        requestFunction(service, nil) { granted in completion(granted) }
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
}
