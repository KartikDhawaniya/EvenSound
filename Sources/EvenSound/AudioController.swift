import AppKit
import CoreAudio
import EvenSoundDSP
import Foundation
import ServiceManagement

@MainActor
final class AudioController: ObservableObject {
    enum Status: Equatable {
        case off
        case needsPermission
        case starting
        case active(device: String)
        case problem(String)
    }

    @Published var settings: SoundSettings {
        didSet { settingsChanged(from: oldValue) }
    }
    @Published private(set) var status: Status = .off
    @Published private(set) var devices: [OutputDevice] = []
    @Published private(set) var currentDeviceID: AudioDeviceID = kAudioObjectUnknown
    @Published private(set) var meters = ProcessorMeters()
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var launchAtLoginMessage: String?

    private let engine = TapEngine()
    private var restartWork: DispatchWorkItem?
    private var stopWork: DispatchWorkItem?
    private var meterTimer: Timer?
    private var watchedDevice: AudioDeviceID = kAudioObjectUnknown
    private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private static let settingsKey = "EvenSound.settings.v4"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode(SoundSettings.self, from: data) {
            settings = saved
        } else {
            settings = SoundSettings()
        }
        refreshDevices()
        addSystemListeners()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if settings.isEnabled { startProcessing() }
    }

    var isActive: Bool {
        if case .active = status { return true }
        return false
    }

    var statusTitle: String {
        switch status {
        case .off: "Off — sound plays normally"
        case .needsPermission: "Needs permission to balance sound"
        case .starting: "Starting…"
        case .active(let device): "On — balancing sound on \(device)"
        case .problem: "Not working right now"
        }
    }

    var statusDetail: String? {
        switch status {
        case .needsPermission:
            "Allow EvenSound under System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only."
        case .problem(let message): message
        case .active:
            meters.soundPresent ? "Sound is playing and being balanced." : "Waiting for sound to play."
        default: nil
        }
    }

    // MARK: Actions

    func selectDevice(_ id: AudioDeviceID) {
        do {
            try AudioDevices.setDefaultOutput(id)
        } catch {
            status = .problem(error.localizedDescription)
        }
    }

    func openPermissionSettings() {
        NSWorkspace.shared.open(AudioCapturePermission.settingsURL)
    }

    func retry() {
        if settings.isEnabled { startProcessing() }
    }

    func resetToDefaults() {
        var defaults = SoundSettings()
        defaults.isEnabled = settings.isEnabled
        settings = defaults
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginMessage = nil
        } catch {
            launchAtLoginMessage = "Couldn't change this: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval {
            launchAtLoginMessage = "Approve EvenSound in System Settings → General → Login Items."
        }
    }

    func shutdown() {
        engine.stop()
    }

    // MARK: Processing lifecycle

    private func settingsChanged(from old: SoundSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
        if settings.isEnabled != old.isEnabled {
            if settings.isEnabled {
                stopWork?.cancel()
                if engine.isRunning {
                    engine.processor?.setParameters(ProcessingParameters(settings))
                    updateActiveStatus()
                } else {
                    startProcessing()
                }
            } else {
                fadeOutAndStop()
            }
            return
        }
        if settings.lowLatency != old.lowLatency, settings.isEnabled {
            startProcessing()
            return
        }
        engine.processor?.setParameters(ProcessingParameters(settings))
    }

    private func startProcessing() {
        stopWork?.cancel()
        switch AudioCapturePermission.status {
        case .denied:
            engine.stop()
            status = .needsPermission
            return
        case .unknown:
            status = .starting
            AudioCapturePermission.request { [weak self] granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.settings.isEnabled else { return }
                        if granted { self.startEngine() } else { self.status = .needsPermission }
                    }
                }
            }
            return
        case .authorized:
            startEngine()
        }
    }

    private func startEngine() {
        status = .starting
        do {
            let device = try AudioDevices.defaultOutput()
            try engine.start(device: device, parameters: ProcessingParameters(settings), lowLatency: settings.lowLatency)
            watchDevice(device)
            updateActiveStatus()
        } catch {
            engine.stop()
            status = .problem(error.localizedDescription)
        }
    }

    private func fadeOutAndStop() {
        guard engine.isRunning else {
            status = .off
            return
        }
        engine.processor?.setParameters(ProcessingParameters(settings))
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.settings.isEnabled else { return }
                self.engine.stop()
                self.status = .off
            }
        }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        status = .off
    }

    private func updateActiveStatus() {
        guard engine.isRunning else { return }
        status = .active(device: AudioDevices.name(engine.deviceID))
    }

    private func scheduleRestart() {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshDevices()
                if self.settings.isEnabled { self.startProcessing() }
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func tick() {
        if let processor = engine.processor {
            meters = processor.meters
        } else if meters != ProcessorMeters() {
            meters = ProcessorMeters()
        }
        if case .active = status, let idle = engine.secondsSinceLastCallback, idle > 2 {
            scheduleRestart()
        }
        if case .needsPermission = status, AudioCapturePermission.status == .authorized, settings.isEnabled {
            startProcessing()
        }
    }

    // MARK: Device monitoring

    private func refreshDevices() {
        devices = AudioDevices.outputDevices()
        currentDeviceID = (try? AudioDevices.defaultOutput()) ?? kAudioObjectUnknown
    }

    private func addSystemListeners() {
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyServiceRestarted] {
            addListener(AudioObject.system, selector) { [weak self] in self?.scheduleRestart() }
        }
        addListener(AudioObject.system, kAudioHardwarePropertyDevices) { [weak self] in self?.refreshDevices() }
    }

    private func watchDevice(_ device: AudioDeviceID) {
        guard device != watchedDevice else { return }
        deviceListeners.removeAll { entry in
            guard entry.0 == watchedDevice else { return false }
            var address = entry.1
            AudioObjectRemovePropertyListenerBlock(entry.0, &address, DispatchQueue.main, entry.2)
            return true
        }
        watchedDevice = device
        for selector in [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyStreamConfiguration] {
            addListener(device, selector) { [weak self] in self?.scheduleRestart() }
        }
    }

    private func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ action: @escaping @MainActor () -> Void) {
        var address = AudioObject.address(
            selector, selector == kAudioDevicePropertyStreamConfiguration ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeGlobal)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { action() }
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr {
            deviceListeners.append((object, address, block))
        }
    }
}
