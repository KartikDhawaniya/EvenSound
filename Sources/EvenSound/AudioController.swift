import AppKit
import CoreAudio
import EvenSoundDSP
import Foundation
import ServiceManagement

struct LevelSample {
    /// nil while EvenSound isn't processing.
    let input: Double?
    let output: Double?
}

@MainActor
final class AudioController: ObservableObject {
    /// 5 minutes of history at 10 samples per second.
    static let historyCapacity = 3000
    @Published private(set) var history: [LevelSample] = []

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
    /// Keep sound in the user's range whatever the Mac's volume is.
    @Published var keepRangeAtAnyVolume = UserDefaults.standard.object(forKey: AudioController.keepRangeKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(keepRangeAtAnyVolume, forKey: Self.keepRangeKey)
            volumeChanged()
        }
    }
    /// How much louder (dB) the Mac's volume is now than when this device's levels were set; 0 when not following.
    @Published private(set) var volumeOffsetDB = 0.0
    @Published private(set) var volumeSuggestion: VolumeSuggestion?
    @Published private(set) var volumeSuggestionMessage: String?

    struct VolumeSuggestion: Equatable {
        /// System volume slider positions, 0...100.
        let currentPercent: Int
        let suggestedPercent: Int
        let suggestedDB: Double
        /// True when the current volume is already close to the best one.
        let isAboutRight: Bool
    }

    /// Recent loudness before the Mac's volume, while sound was playing.
    private var signalLevels: [Double] = []
    private var ticksSinceAdvice = 0
    private var referenceVolumeDB: Double?

    private let engine = TapEngine()
    private var restartWork: DispatchWorkItem?
    private var stopWork: DispatchWorkItem?
    private var meterTimer: Timer?
    private var watchedDevice: AudioDeviceID = kAudioObjectUnknown
    private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private static let settingsKey = "EvenSound.settings.v5"
    private static let keepRangeKey = "EvenSound.keepRangeAtAnyVolume"
    private static let referenceVolumesKey = "EvenSound.referenceVolumeDB"
    /// Beyond this much turning down, quiet sound can't be lifted all the way back into range.
    static let maxVolumeCompensationDB = 20.0

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
        case .active where volumeOffsetDB < -Self.maxVolumeCompensationDB:
            "Your Mac's volume is turned down a lot, so quiet sound may stay below your range."
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
                    engine.processor?.setParameters(parameters())
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
        engine.processor?.setParameters(parameters())
    }

    private func parameters() -> ProcessingParameters {
        var p = ProcessingParameters(settings)
        p.volumeOffsetDB = volumeOffsetDB
        return p
    }

    func applySuggestedVolume() {
        guard let suggestion = volumeSuggestion else { return }
        do {
            try AudioDevices.setOutputVolumeDB(watchedDevice, suggestion.suggestedDB)
        } catch {
            volumeSuggestionMessage = error.localizedDescription
        }
    }

    /// Learns from what is playing and works out which Mac volume needs the least correcting.
    private func recordSignalLevel() {
        guard isActive, meters.soundPresent, settings.isEnabled else { return }
        signalLevels.append(meters.inputLUFS - volumeOffsetDB)
        if signalLevels.count > Self.historyCapacity {
            signalLevels.removeFirst(signalLevels.count - Self.historyCapacity)
        }
        ticksSinceAdvice += 1
        if ticksSinceAdvice >= 20 {
            ticksSinceAdvice = 0
            updateVolumeSuggestion()
        }
    }

    private func updateVolumeSuggestion() {
        guard keepRangeAtAnyVolume, let reference = referenceVolumeDB, watchedDevice != kAudioObjectUnknown,
              let volume = AudioDevices.outputVolumeDB(watchedDevice),
              let deviceRange = AudioDevices.outputVolumeRangeDB(watchedDevice),
              let advice = VolumeAdvisor.advise(
                signalLevels: signalLevels,
                currentOffset: volumeOffsetDB,
                quietest: settings.quietestLevelDB,
                loudest: settings.loudestLevelDB,
                possibleOffsets: (deviceRange.lowerBound - reference)...(deviceRange.upperBound - reference)),
              let current = AudioDevices.volumeSliderPosition(watchedDevice, decibels: volume),
              let suggested = AudioDevices.volumeSliderPosition(watchedDevice, decibels: reference + advice.offsetDB)
        else {
            if volumeSuggestion != nil { volumeSuggestion = nil }
            return
        }
        let currentPercent = Int((current * 100).rounded())
        let suggestedPercent = Int((suggested * 100).rounded())
        let aboutRight = abs(suggestedPercent - currentPercent) < 5
            || advice.currentCorrectionDB - advice.suggestedCorrectionDB < 1
        let next = VolumeSuggestion(
            currentPercent: currentPercent, suggestedPercent: suggestedPercent,
            suggestedDB: reference + advice.offsetDB, isAboutRight: aboutRight)
        if next != volumeSuggestion { volumeSuggestion = next }
    }

    /// Makes the current volume on this device the one the levels are measured at.
    func useCurrentVolumeAsReference() {
        guard watchedDevice != kAudioObjectUnknown, let uid = try? AudioDevices.uid(watchedDevice) else { return }
        var references = UserDefaults.standard.dictionary(forKey: Self.referenceVolumesKey) as? [String: Double] ?? [:]
        references[uid] = nil
        UserDefaults.standard.set(references, forKey: Self.referenceVolumesKey)
        volumeChanged()
    }

    /// Re-reads the Mac's volume and keeps the processor's view of what the user hears up to date.
    private func volumeChanged() {
        var offset = 0.0
        let device = watchedDevice
        if keepRangeAtAnyVolume, device != kAudioObjectUnknown,
           let volume = AudioDevices.outputVolumeDB(device), let uid = try? AudioDevices.uid(device) {
            var references = UserDefaults.standard.dictionary(forKey: Self.referenceVolumesKey) as? [String: Double] ?? [:]
            // The first time a device is seen, its levels mean what is heard at its current volume.
            if references[uid] == nil {
                references[uid] = volume
                UserDefaults.standard.set(references, forKey: Self.referenceVolumesKey)
            }
            offset = volume - (references[uid] ?? volume)
            referenceVolumeDB = references[uid]
        } else {
            referenceVolumeDB = nil
        }
        defer { updateVolumeSuggestion() }
        guard offset != volumeOffsetDB else { return }
        volumeOffsetDB = offset
        engine.processor?.setParameters(parameters())
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
            watchDevice(device)
            try engine.start(device: device, parameters: parameters(), lowLatency: settings.lowLatency)
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
        engine.processor?.setParameters(parameters())
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
        recordHistory()
        recordSignalLevel()
        if case .active = status, let idle = engine.secondsSinceLastCallback, idle > 2 {
            scheduleRestart()
        }
        if case .needsPermission = status, AudioCapturePermission.status == .authorized, settings.isEnabled {
            startProcessing()
        }
    }

    private func recordHistory() {
        let sample: LevelSample
        if isActive {
            let floor = -90.0
            sample = LevelSample(
                input: max(meters.currentInputLUFS, floor),
                output: max(meters.currentOutputLUFS, floor))
        } else {
            sample = LevelSample(input: nil, output: nil)
        }
        history.append(sample)
        if history.count > Self.historyCapacity {
            history.removeFirst(history.count - Self.historyCapacity)
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
        for element in AudioDevices.volumeElements {
            addListener(device, kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: element) { [weak self] in
                self?.volumeChanged()
            }
        }
        volumeChanged()
    }

    private func addListener(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope? = nil,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        _ action: @escaping @MainActor () -> Void
    ) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope ?? (selector == kAudioDevicePropertyStreamConfiguration ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeGlobal),
            mElement: element)
        guard AudioObjectHasProperty(object, &address) else { return }
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { action() }
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr {
            deviceListeners.append((object, address, block))
        }
    }
}
