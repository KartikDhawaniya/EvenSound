import EvenSoundDSP
import SwiftUI

struct MainView: View {
    private enum Tab: Hashable { case overview, graph, advanced, settings }
    @State private var tab = Tab.overview
    @AppStorage("showAdvancedControls") private var showAdvanced = false

    var body: some View {
        TabView(selection: $tab) {
            OverviewView()
                .tabItem { Label("Overview", systemImage: "waveform") }
                .tag(Tab.overview)
            if showAdvanced {
                SoundGraphView()
                    .tabItem { Label("Sound graph", systemImage: "chart.xyaxis.line") }
                    .tag(Tab.graph)
                AdvancedView()
                    .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
                    .tag(Tab.advanced)
            }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .padding(20)
        .frame(width: 540)
        .onChange(of: showAdvanced) { _, shown in
            if !shown, tab == .graph || tab == .advanced { tab = .settings }
        }
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

struct ThresholdControls: View {
    @EnvironmentObject private var controller: AudioController

    var body: some View {
        ThresholdSlider(
            title: "Quiet threshold",
            caption: "Anything quieter than this is lifted toward it; anything louder isn't lifted at all. \"Hear quiet sounds better\" on the Overview sets how far it is lifted: 50% closes half the gap, 100% brings it right up to this level.",
            value: Binding(
                get: { controller.settings.quietThresholdDB },
                set: { controller.settings.quietThresholdDB = min($0, controller.settings.peakThresholdDB) }),
            range: SoundSettings.quietThresholdRange)
        ThresholdSlider(
            title: "Peak threshold",
            caption: "Anything louder than this is turned down toward it; anything quieter isn't touched. \"Reduce loud sounds\" on the Overview sets how much: 50% removes half the extra loudness, 100% holds sound at this level.",
            value: Binding(
                get: { controller.settings.peakThresholdDB },
                set: {
                    controller.settings.peakThresholdDB = $0
                    if controller.settings.quietThresholdDB > $0 { controller.settings.quietThresholdDB = $0 }
                }),
            range: SoundSettings.peakThresholdRange)
    }
}

struct CurveControls: View {
    @EnvironmentObject private var controller: AudioController

    var body: some View {
        ThresholdSlider(
            title: "Maximum level",
            caption: "The loudest that sound should get. Loud sound is eased down toward this level, more firmly the louder it is. Move left if loud scenes still feel too loud.",
            value: Binding(
                get: { controller.settings.curveMaxDB },
                set: {
                    controller.settings.curveMaxDB = $0
                    let highestMin = $0 - SoundSettings.curveMinimumGap
                    if controller.settings.curveMinDB > highestMin { controller.settings.curveMinDB = highestMin }
                }),
            range: SoundSettings.curveMaxRange)
        ThresholdSlider(
            title: "Minimum level",
            caption: "The quietest that sound should get. Quiet sound is eased up toward this level. Move right if quiet voices are still hard to hear.",
            value: Binding(
                get: { controller.settings.curveMinDB },
                set: {
                    controller.settings.curveMinDB = min($0, controller.settings.curveMaxDB - SoundSettings.curveMinimumGap)
                }),
            range: SoundSettings.curveMinRange)
        LabeledSlider(
            title: "Flatten",
            caption: "How strongly sound between the two levels is evened out. Low leaves normal-volume sound almost untouched; high makes everything nearly the same loudness, which can sound flat.",
            value: $controller.settings.curveFlatten)
        CurvePreview(
            minimum: min(controller.settings.curveMinDB, controller.settings.curveMaxDB - SoundSettings.curveMinimumGap),
            maximum: controller.settings.curveMaxDB,
            slope: LevelCurve.slope(flatten: controller.settings.curveFlatten),
            currentInput: controller.isActive ? controller.meters.currentInputLUFS : nil)
    }
}

/// Plots output level against input level for the smooth curve.
struct CurvePreview: View {
    let minimum: Double
    let maximum: Double
    let slope: Double
    let currentInput: Double?
    private let range = -60.0 ... 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Canvas { context, size in
                let span = range.upperBound - range.lowerBound
                func point(_ input: Double, _ output: Double) -> CGPoint {
                    CGPoint(
                        x: (input - range.lowerBound) / span * size.width,
                        y: size.height - (min(max(output, range.lowerBound), range.upperBound) - range.lowerBound) / span * size.height)
                }
                var unchanged = Path()
                unchanged.move(to: point(range.lowerBound, range.lowerBound))
                unchanged.addLine(to: point(range.upperBound, range.upperBound))
                context.stroke(unchanged, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                for (level, color) in [(maximum, Color.red), (minimum, Color.blue)] {
                    var line = Path()
                    line.move(to: point(range.lowerBound, level))
                    line.addLine(to: point(range.upperBound, level))
                    context.stroke(line, with: .color(color.opacity(0.6)), lineWidth: 1)
                }

                var curve = Path()
                for step in 0...120 {
                    let input = range.lowerBound + span * Double(step) / 120
                    let p = point(input, LevelCurve.output(input, minimum: minimum, maximum: maximum, slope: slope))
                    step == 0 ? curve.move(to: p) : curve.addLine(to: p)
                }
                context.stroke(curve, with: .color(.accentColor), lineWidth: 2)

                if let currentInput, currentInput > range.lowerBound {
                    let output = LevelCurve.output(currentInput, minimum: minimum, maximum: maximum, slope: slope)
                    let p = point(currentInput, output)
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.orange))
                }
            }
            .frame(height: 120)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            Text("Sound going in (left to right) and coming out (bottom to top). Dashed line = unchanged; orange dot = now.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Curve from minimum \(Int(minimum)) to maximum \(Int(maximum)) dB")
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

/// Plain-language description of what EvenSound is doing right now.
struct NowSummary: View {
    @EnvironmentObject private var controller: AudioController

    private var state: (icon: String, text: String, color: Color) {
        let m = controller.meters
        guard controller.isActive else { return ("pause.circle", "Not balancing right now", .secondary) }
        guard m.soundPresent else { return ("ear", "Listening — nothing is playing", .secondary) }
        let change = m.currentOutputLUFS - m.currentInputLUFS
        if change > 1 { return ("arrow.up.circle.fill", "Lifting quiet sound so it's easier to hear", .green) }
        if change < -1 { return ("arrow.down.circle.fill", "Softening loud sound", .orange) }
        return ("checkmark.circle.fill", "Sound is at a comfortable level", .green)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.icon).font(.title2).foregroundStyle(state.color)
            Text(state.text).font(.body)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .animation(.easeInOut(duration: 0.2), value: state.text)
        .accessibilityElement(children: .combine)
    }
}

struct InfoBox: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "info.circle").font(.callout.weight(.semibold))
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Simple bars showing how much EvenSound is lifting or softening right now.
struct CorrectionMeter: View {
    @EnvironmentObject private var controller: AudioController

    var body: some View {
        let change = controller.isActive ? controller.meters.currentOutputLUFS - controller.meters.currentInputLUFS : 0
        VStack(alignment: .leading, spacing: 6) {
            bar("Lifting quiet sound", amount: max(change, 0) / 12, color: .green)
            bar("Softening loud sound", amount: max(-change, 0) / 15, color: .orange)
        }
        .accessibilityElement(children: .combine)
    }

    private func bar(_ title: String, amount: Double, color: Color) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 140, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color).frame(width: geo.size.width * min(max(amount, 0), 1))
                }
            }
            .frame(height: 8)
            .animation(.easeOut(duration: 0.15), value: amount)
        }
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
                    caption: "Lifts quiet voices and soft scenes.",
                    value: $controller.settings.quietBoost)
                LabeledSlider(
                    title: "Reduce loud sounds",
                    caption: "Softens explosions, loud adverts and sudden bangs.",
                    value: $controller.settings.loudReduction)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Intensity").font(.body.weight(.medium))
                    Picker("Intensity", selection: $controller.settings.intensity) {
                        ForEach(Intensity.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("Gentle sounds most natural. Strong reacts fastest.")
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

            if controller.settings.isEnabled {
                NowSummary()
                CorrectionMeter()
            }
        }
    }
}

struct AdvancedView: View {
    @EnvironmentObject private var controller: AudioController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                InfoBox(title: "About these controls", text: """
                    These controls decide which volume levels count as "too quiet" and "too loud". \
                    The two sliders on the Overview still decide how strongly EvenSound corrects them, \
                    and Intensity still decides how quickly.

                    Levels are in decibels (dB). 0 dB is the loudest sound your Mac can play; \
                    lower numbers are quieter. Most videos and music sit between -30 and -10 dB. \
                    Your Mac's volume keys are applied afterwards, so these levels don't change when you turn the volume up or down.
                    """)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Balancing style").font(.body.weight(.medium))
                    Picker("Balancing style", selection: $controller.settings.profile) {
                        ForEach(BalanceProfile.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(controller.settings.profile == .curve
                        ? "Smooth: every level is adjusted a little, more the further it is from the middle. Nothing jumps at a hard edge, so it sounds the most natural. Best for most people."
                        : "Fixed limits: sound between the two levels is left completely alone; only sound outside them is corrected. More predictable, but changes can be more noticeable at the edges.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if controller.settings.profile == .curve {
                    CurveControls()
                } else {
                    ThresholdControls()
                }

                if controller.isActive {
                    Text("Live level: the grey bar is how loud the sound is coming in, the coloured bar is how loud it leaves EvenSound. The red and blue lines are your loudest and quietest levels. The bar turns orange while sound is above the red line.")
                        .font(.caption).foregroundStyle(.secondary)
                    LevelMeter(
                        input: controller.meters.currentInputLUFS,
                        output: controller.meters.currentOutputLUFS,
                        threshold: controller.settings.profile == .curve
                            ? controller.settings.curveMaxDB : controller.settings.peakThresholdDB,
                        quietThreshold: controller.settings.profile == .curve
                            ? min(controller.settings.curveMinDB, controller.settings.curveMaxDB - SoundSettings.curveMinimumGap)
                            : min(controller.settings.quietThresholdDB, controller.settings.peakThresholdDB),
                        active: controller.settings.isEnabled)
                }
            }
            .padding(.trailing, 8)
        }
        .frame(height: 560)
        .disabled(!controller.settings.isEnabled)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var controller: AudioController
    @State private var showMoreOptions = false
    @AppStorage("showAdvancedControls") private var showAdvanced = false

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
                DisclosureGroup("More options", isExpanded: $showMoreOptions) {
                    Picker("Loudest allowed sound", selection: $controller.settings.ceiling) {
                        ForEach(LoudnessCeiling.allCases) { Text($0.title).tag($0) }
                    }
                    Text("A hard safety cap: no sound can ever go above it, however loud the original. Lower and Lowest leave more room below your speakers' maximum.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Background noise protection", selection: $controller.settings.noiseProtection) {
                        ForEach(NoiseProtection.allCases) { Text($0.title).tag($0) }
                    }
                    Text("Very quiet sound such as hiss, hum or room noise is never lifted. Choose High if you hear background noise being made louder; Low if very soft voices aren't being lifted.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Low delay mode (for games and instruments)", isOn: $controller.settings.lowLatency)
                    Text("Reduces the tiny delay EvenSound adds. Only needed if you play an instrument or rhythm game through your Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Restore default settings") { controller.resetToDefaults() }
                }
            }

            Section {
                Toggle("Show advanced controls", isOn: $showAdvanced)
                Text("Adds the Sound graph and Advanced tabs, with detailed level controls for people who like to fine-tune.")
                    .font(.caption).foregroundStyle(.secondary)
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
