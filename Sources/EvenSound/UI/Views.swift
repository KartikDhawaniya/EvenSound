import EvenSoundDSP
import SwiftUI

struct MainView: View {
    private enum Tab: Hashable { case overview, settings }
    @State private var tab = Tab.overview

    var body: some View {
        TabView(selection: $tab) {
            OverviewView()
                .tabItem { Label("Overview", systemImage: "waveform") }
                .tag(Tab.overview)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .padding(20)
        .frame(width: 480)
    }
}

struct StatusBadge: View {
    @EnvironmentObject private var controller: AudioController

    private var color: Color {
        switch controller.status {
        case .active: .green
        case .starting: .yellow
        case .off: .secondary
        case .needsPermission, .problem: .orange
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(color).frame(width: 10, height: 10).padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(controller.statusTitle).font(.headline)
                if let detail = controller.statusDetail {
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                switch controller.status {
                case .needsPermission:
                    Button("Open Privacy Settings") { controller.openPermissionSettings() }
                case .problem:
                    Button("Try Again") { controller.retry() }
                default:
                    EmptyView()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

struct LabeledSlider: View {
    let title: String
    let caption: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.body.weight(.medium))
                Spacer()
                Text("\(Int((value * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: 0...1) {
                Text(title)
            } minimumValueLabel: {
                Text("Less").font(.caption)
            } maximumValueLabel: {
                Text("More").font(.caption)
            }
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ActivityBar: View {
    let title: String
    let amount: Double

    var body: some View {
        HStack {
            Text(title).font(.caption).frame(width: 150, alignment: .leading)
            ProgressView(value: min(max(amount, 0), 1)).animation(.easeOut(duration: 0.15), value: amount)
        }
    }
}

struct ThresholdSlider: View {
    let title: String
    let caption: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.body.weight(.medium))
                Spacer()
                Text("\(Int(value.rounded())) dB").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: 1) {
                Text(title)
            } minimumValueLabel: {
                Text("Quieter").font(.caption)
            } maximumValueLabel: {
                Text("Louder").font(.caption)
            }
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct LevelMeter: View {
    let input: Double
    let output: Double
    let threshold: Double
    let quietThreshold: Double
    let active: Bool
    static let range = -60.0 ... 0.0

    private func fraction(_ value: Double) -> CGFloat {
        CGFloat((min(max(value, Self.range.lowerBound), Self.range.upperBound) - Self.range.lowerBound)
            / (Self.range.upperBound - Self.range.lowerBound))
    }

    private func label(_ value: Double) -> String {
        value <= Self.range.lowerBound ? "—" : "\(Int(value.rounded())) dB"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Current volume").font(.body.weight(.medium))
                Spacer()
                Text("Before \(label(input))  ·  After \(label(output))")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.35))
                        .frame(width: width * fraction(input), height: 8)
                        .frame(maxHeight: .infinity, alignment: .top)
                    RoundedRectangle(cornerRadius: 4).fill(output > threshold + 0.5 ? Color.orange : Color.green)
                        .frame(width: width * fraction(active ? output : input), height: 10)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    Rectangle().fill(.blue)
                        .frame(width: 2)
                        .offset(x: width * fraction(quietThreshold) - 1)
                    Rectangle().fill(.red)
                        .frame(width: 2)
                        .offset(x: width * fraction(threshold) - 1)
                }
                .animation(.linear(duration: 0.1), value: input)
                .animation(.linear(duration: 0.1), value: output)
            }
            .frame(height: 20)
            HStack {
                Label("Before", systemImage: "square.fill").foregroundStyle(.secondary)
                Label("After", systemImage: "square.fill").foregroundStyle(.green)
                Label("Quiet threshold", systemImage: "line.diagonal").foregroundStyle(.blue)
                Label("Peak threshold", systemImage: "line.diagonal").foregroundStyle(.red)
            }
            .font(.caption2)
            .labelStyle(.titleAndIcon)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Current volume \(label(output)), peak threshold \(Int(threshold)) dB")
    }
}

struct OverviewView: View {
    @EnvironmentObject private var controller: AudioController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Make your sound more comfortable").font(.title2.bold())
                Text("Hear dialogue clearly without sudden loud surprises.").foregroundStyle(.secondary)
            }

            Toggle(isOn: $controller.settings.isEnabled) {
                Text("Sound balance").font(.title3.weight(.semibold))
            }
            .toggleStyle(.switch)
            .controlSize(.large)

            StatusBadge()

            Group {
                LabeledSlider(
                    title: "Hear quiet sounds better",
                    caption: "How much of the gap up to the quiet threshold is filled. 100% lifts quiet sound right up to it.",
                    value: $controller.settings.quietBoost)
                ThresholdSlider(
                    title: "Quiet threshold",
                    caption: "Sound quieter than this gets raised. Move it right to lift more sound.",
                    value: Binding(
                        get: { controller.settings.quietThresholdDB },
                        set: { controller.settings.quietThresholdDB = min($0, controller.settings.peakThresholdDB) }),
                    range: SoundSettings.quietThresholdRange)
                LabeledSlider(
                    title: "Reduce loud sounds",
                    caption: "How much of the excess above the peak threshold is removed. 100% holds loud sound at it.",
                    value: $controller.settings.loudReduction)
                ThresholdSlider(
                    title: "Peak threshold",
                    caption: "Sound louder than this gets turned down. Move it left to keep more sound quieter.",
                    value: Binding(
                        get: { controller.settings.peakThresholdDB },
                        set: {
                            controller.settings.peakThresholdDB = $0
                            if controller.settings.quietThresholdDB > $0 { controller.settings.quietThresholdDB = $0 }
                        }),
                    range: SoundSettings.peakThresholdRange)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Intensity").font(.body.weight(.medium))
                    Picker("Intensity", selection: $controller.settings.intensity) {
                        ForEach(Intensity.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("How quickly EvenSound reacts. Gentle sounds most natural; Strong reacts fastest.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!controller.settings.isEnabled)

            Picker("Play sound on", selection: Binding(
                get: { controller.currentDeviceID },
                set: { controller.selectDevice($0) }
            )) {
                ForEach(controller.devices) { Text($0.name).tag($0.id) }
            }

            if controller.isActive {
                LevelMeter(
                    input: controller.meters.currentInputLUFS,
                    output: controller.meters.currentOutputLUFS,
                    threshold: controller.settings.peakThresholdDB,
                    quietThreshold: min(controller.settings.quietThresholdDB, controller.settings.peakThresholdDB),
                    active: controller.settings.isEnabled)
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var controller: AudioController
    @State private var showAdvanced = false

    var body: some View {
        Form {
            Section {
                Toggle("Open EvenSound when you log in", isOn: Binding(
                    get: { controller.launchAtLogin },
                    set: { controller.setLaunchAtLogin($0) }))
                if let message = controller.launchAtLoginMessage {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
                Text("EvenSound keeps working in the menu bar after you close this window.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    Picker("Loudest allowed sound", selection: $controller.settings.ceiling) {
                        ForEach(LoudnessCeiling.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Background noise protection", selection: $controller.settings.noiseProtection) {
                        ForEach(NoiseProtection.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Low delay mode (for games and instruments)", isOn: $controller.settings.lowLatency)
                    Button("Restore default settings") { controller.resetToDefaults() }
                }
            }

            Section {
                Text("EvenSound limits how loud the digital audio signal can get, but it can't control how loud your speakers or headphones are. Keep your Mac's volume at a comfortable level to protect your hearing.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(Self.versionText).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private static var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String ?? "0"
        let commit = info["EvenSoundCommit"] as? String ?? "unknown"
        return "EvenSound \(version) (build \(build), \(commit))"
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var controller: AudioController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Sound balance", isOn: $controller.settings.isEnabled).toggleStyle(.switch)
            Text(controller.statusTitle).font(.callout).foregroundStyle(.secondary)
            Picker("Intensity", selection: $controller.settings.intensity) {
                ForEach(Intensity.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!controller.settings.isEnabled)
            Divider()
            HStack {
                Button("Open EvenSound") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}
