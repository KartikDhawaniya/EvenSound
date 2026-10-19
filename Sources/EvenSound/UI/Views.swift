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

struct CurveControls: View {
    @EnvironmentObject private var controller: AudioController

    var body: some View {
        LabeledSlider(
            title: "Flatten",
            caption: "How strongly sound between your quietest and loudest levels is evened out. Low leaves normal-volume sound almost untouched; high makes everything nearly the same loudness, which can sound flat.",
            value: $controller.settings.curveFlatten)
        CurvePreview(
            minimum: controller.settings.quietestLevelDB,
            maximum: controller.settings.loudestLevelDB,
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

/// Describes a loudness level in everyday words.
func loudnessWord(_ level: Double) -> String {
    switch level {
    case ..<(-34): "Very soft"
    case ..<(-26): "Soft"
    case ..<(-18): "Medium"
    case ..<(-12): "Loud"
    default: "Very loud"
    }
}

/// A level slider without numbers: shows an everyday word instead of decibels.
struct LevelSlider: View {
    let title: String
    let caption: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.body.weight(.medium))
                Spacer()
                Text(loudnessWord(value)).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: 1) {
                Text(title)
            } minimumValueLabel: {
                Text("Softer").font(.caption)
            } maximumValueLabel: {
                Text("Louder").font(.caption)
            }
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityValue(loudnessWord(value))
    }
}

/// The band between the quietest and loudest levels, with a dot for the sound right now.
struct ComfortRange: View {
    @EnvironmentObject private var controller: AudioController
    private let range = -50.0 ... -6.0

    private func position(_ level: Double, _ width: CGFloat) -> CGFloat {
        CGFloat((min(max(level, range.lowerBound), range.upperBound) - range.lowerBound)
            / (range.upperBound - range.lowerBound)) * width
    }

    var body: some View {
        let low = controller.settings.quietestLevelDB
        let high = controller.settings.loudestLevelDB
        let playing = controller.isActive && controller.meters.soundPresent
        let original = playing ? controller.meters.currentInputLUFS : nil
        let processed = playing ? controller.meters.currentOutputLUFS : nil
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 10)
                    Capsule().fill(Color.green.opacity(0.35))
                        .frame(width: max(position(high, w) - position(low, w), 4), height: 10)
                        .offset(x: position(low, w))
                    if let original {
                        Circle().strokeBorder(Color.gray, lineWidth: 2).frame(width: 14, height: 14)
                            .offset(x: position(original, w) - 7)
                            .animation(.linear(duration: 0.1), value: original)
                    }
                    if let processed {
                        Circle().fill(Color.accentColor).frame(width: 10, height: 10)
                            .offset(x: position(processed, w) - 5)
                            .animation(.linear(duration: 0.1), value: processed)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 16)
            HStack {
                Text("Softer").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("Comfortable range").font(.caption2).foregroundStyle(.green)
                Spacer()
                Text("Louder").font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                HStack(spacing: 4) {
                    Circle().strokeBorder(Color.gray, lineWidth: 2).frame(width: 10, height: 10)
                    Text("Original sound")
                }
                HStack(spacing: 4) {
                    Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                    Text("After EvenSound")
                }
                if original == nil {
                    Text("— play something to see it move").foregroundStyle(.secondary)
                }
            }
            .font(.caption2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Comfortable range from \(loudnessWord(low)) to \(loudnessWord(high))")
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

struct OverviewView: View {
    @EnvironmentObject private var controller: AudioController

    private var intensityDescription: String {
        let lead = "How quickly EvenSound reacts when sound suddenly gets louder or quieter. "
        switch controller.settings.intensity {
        case .gentle:
            return lead + "Gentle changes the volume slowly and smoothly, so it sounds the most natural. Good for music."
        case .balanced:
            return lead + "Balanced is a good middle ground for films, shows and everyday use."
        case .strong:
            return lead + "Strong reacts fastest, catching loud adverts and bangs almost at once. Good for late-night watching, but you may sometimes hear the volume moving."
        }
    }

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
                LevelSlider(
                    title: "Loudest sound",
                    caption: "Explosions, adverts and sudden bangs are kept from going louder than this.",
                    value: $controller.settings.loudestLevelDB,
                    range: controller.settings.loudestLevelRange)
                LevelSlider(
                    title: "Quietest sound",
                    caption: "Quiet voices and soft scenes are lifted up toward this.",
                    value: $controller.settings.quietestLevelDB,
                    range: controller.settings.quietestLevelRange)
                ComfortRange()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Intensity").font(.body.weight(.medium))
                    Picker("Intensity", selection: $controller.settings.intensity) {
                        ForEach(Intensity.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(intensityDescription)
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!controller.settings.isEnabled)

            Picker("Play sound on", selection: Binding(
                get: { controller.currentDeviceID },
                set: { controller.selectDevice($0) }
            )) {
                ForEach(controller.devices) { Text($0.name).tag($0.id) }
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
                    The Overview sets your loudest and quietest levels. These controls fine-tune how \
                    EvenSound gets sound there: the balancing style, how strongly it corrects, and how \
                    it treats sound in between. Intensity on the Overview still decides how quickly it reacts.

                    Levels are in decibels (dB). 0 dB is the loudest sound your Mac can play; \
                    lower numbers are quieter. Most videos and music sit between -30 and -10 dB.
                    """)
                Text(controller.keepRangeAtAnyVolume
                    ? "Levels are as you hear them: EvenSound takes your Mac's volume into account, so sound stays between them when you turn the volume up or down."
                    : "Your Mac's volume is applied after EvenSound, so turning it up or down makes everything louder or quieter, including your loudest level.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

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

                VStack(alignment: .leading, spacing: 4) {
                    Text("Your levels").font(.body.weight(.medium))
                    Text("Loudest sound: \(Int(controller.settings.loudestLevelDB.rounded())) dB  ·  Quietest sound: \(Int(controller.settings.quietestLevelDB.rounded())) dB")
                        .monospacedDigit()
                    Text("Set these with the two sliders on the Overview. Each balancing style remembers its own levels.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if controller.settings.profile == .curve {
                    CurveControls()
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Correction strength").font(.body.weight(.medium))
                    Text("How fully EvenSound moves sound to your levels. At 100% loud sound is held at your loudest level and quiet sound is lifted to your quietest level. Lower values correct only part of the way, keeping more of the original contrast.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    LabeledSlider(
                        title: "Lift quiet sound",
                        caption: "50% lifts quiet sound halfway to your quietest level; 100% lifts it all the way.",
                        value: $controller.settings.quietBoost)
                    LabeledSlider(
                        title: "Soften loud sound",
                        caption: "50% removes half of the extra loudness above your loudest level; 100% removes all of it.",
                        value: $controller.settings.loudReduction)
                }

                if controller.isActive {
                    Text("Live level: the grey bar is how loud the sound is coming in, the coloured bar is how loud it leaves EvenSound. The red and blue lines are your loudest and quietest levels. The bar turns orange while sound is above the red line.")
                        .font(.caption).foregroundStyle(.secondary)
                    LevelMeter(
                        input: controller.meters.currentInputLUFS,
                        output: controller.meters.currentOutputLUFS,
                        threshold: controller.settings.loudestLevelDB,
                        quietThreshold: controller.settings.quietestLevelDB,
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
                Toggle("Keep sound in my range at any volume", isOn: $controller.keepRangeAtAnyVolume)
                Text(controller.keepRangeAtAnyVolume
                    ? "EvenSound allows for your Mac's volume. Turn it up and loud sound is held back more; turn it down and quiet sound is lifted more, so what you hear stays between your quietest and loudest levels. Each speaker or pair of headphones keeps its own setting."
                    : "Your Mac's volume works as normal: it makes everything louder or quieter after EvenSound has balanced it.")
                    .font(.caption).foregroundStyle(.secondary)
                if controller.keepRangeAtAnyVolume {
                    HStack {
                        Button("My levels sound right at this volume") { controller.useCurrentVolumeAsReference() }
                            .disabled(controller.volumeOffsetDB == 0)
                        Spacer()
                        Text(volumeOffsetText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Text("Set the volume to where your levels feel right, then press this. EvenSound then holds that experience as the volume changes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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

    private var volumeOffsetText: String {
        let offset = Int(controller.volumeOffsetDB.rounded())
        if offset == 0 { return "Volume is where you set your levels" }
        return offset > 0 ? "Volume \(offset) dB higher — holding back" : "Volume \(-offset) dB lower — lifting"
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
