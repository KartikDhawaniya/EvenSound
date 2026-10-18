import EvenSoundDSP
import SwiftUI

struct SoundGraphView: View {
    private enum Window: Int, CaseIterable, Identifiable {
        case seconds15 = 15, seconds30 = 30, minute1 = 60, minutes5 = 300

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .seconds15: "15 s"
            case .seconds30: "30 s"
            case .minute1: "1 min"
            case .minutes5: "5 min"
            }
        }
    }

    @EnvironmentObject private var controller: AudioController
    @State private var window = Window.seconds30
    @State private var frozen: [LevelSample]?

    private var samples: [LevelSample] {
        let all = frozen ?? controller.history
        return Array(all.suffix(window.rawValue * 10))
    }

    private var limits: (upper: Double, lower: Double) {
        let s = controller.settings
        if s.profile == .curve {
            return (s.curveMaxDB, min(s.curveMinDB, s.curveMaxDB - SoundSettings.curveMinimumGap))
        }
        return (s.peakThresholdDB, min(s.quietThresholdDB, s.peakThresholdDB))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Sound over time").font(.title3.bold())
                Spacer()
                Picker("Show", selection: $window) {
                    ForEach(Window.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                Button(frozen == nil ? "Pause" : "Resume") {
                    frozen = frozen == nil ? controller.history : nil
                }
            }

            Text("The grey line is how loud the sound was coming in; the green line is how loud it left EvenSound. Newest is on the right. Dashed lines show your loudest (red) and quietest (blue) levels. When EvenSound is working well, the green line stays between them.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            LevelHistoryChart(
                samples: samples,
                capacity: window.rawValue * 10,
                upper: limits.upper,
                lower: limits.lower)
                .frame(height: 220)

            HStack(spacing: 14) {
                legend("Before", .gray)
                legend("After", .green)
                legend(controller.settings.profile == .curve ? "Maximum" : "Peak threshold", .red)
                legend(controller.settings.profile == .curve ? "Minimum" : "Quiet threshold", .blue)
            }
            .font(.caption)

            Text("Change EvenSound is making").font(.body.weight(.medium))
            Text("Green bars above the middle line mean sound was lifted; orange bars below mean it was turned down. Taller bars mean bigger changes.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ChangeChart(samples: samples, capacity: window.rawValue * 10)
                .frame(height: 90)
            HStack(spacing: 14) {
                legend("Raised", .green)
                legend("Turned down", .orange)
            }
            .font(.caption)

            if !controller.isActive {
                Text("Turn on Sound balance and play something to see the graph.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 14, height: 3)
            Text(title).foregroundStyle(.secondary)
        }
    }
}

/// Before/after loudness lines over time, newest on the right.
struct LevelHistoryChart: View {
    let samples: [LevelSample]
    let capacity: Int
    let upper: Double
    let lower: Double
    private let range = -60.0 ... 0.0

    var body: some View {
        Canvas { context, size in
            let labelWidth: CGFloat = 34
            let plot = CGRect(x: labelWidth, y: 4, width: size.width - labelWidth, height: size.height - 8)
            func y(_ level: Double) -> CGFloat {
                let clamped = min(max(level, range.lowerBound), range.upperBound)
                return plot.maxY - CGFloat((clamped - range.lowerBound) / (range.upperBound - range.lowerBound)) * plot.height
            }
            func x(_ index: Int) -> CGFloat {
                let offset = capacity - samples.count
                return plot.minX + CGFloat(offset + index) / CGFloat(max(capacity - 1, 1)) * plot.width
            }

            for level in stride(from: range.lowerBound, through: range.upperBound, by: 10) {
                var grid = Path()
                grid.move(to: CGPoint(x: plot.minX, y: y(level)))
                grid.addLine(to: CGPoint(x: plot.maxX, y: y(level)))
                context.stroke(grid, with: .color(.secondary.opacity(0.15)), lineWidth: 1)
                context.draw(
                    Text("\(Int(level))").font(.caption2).foregroundStyle(.secondary),
                    at: CGPoint(x: labelWidth - 4, y: y(level)), anchor: .trailing)
            }

            for (level, color) in [(upper, Color.red), (lower, Color.blue)] {
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: y(level)))
                line.addLine(to: CGPoint(x: plot.maxX, y: y(level)))
                context.stroke(line, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
            }

            context.stroke(path(\.input, x: x, y: y), with: .color(.gray), lineWidth: 1.5)
            context.stroke(path(\.output, x: x, y: y), with: .color(.green), lineWidth: 2)
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Graph of sound level before and after processing over time")
    }

    private func path(_ key: KeyPath<LevelSample, Double?>, x: (Int) -> CGFloat, y: (Double) -> CGFloat) -> Path {
        var path = Path()
        var drawing = false
        for (index, sample) in samples.enumerated() {
            guard let value = sample[keyPath: key] else {
                drawing = false
                continue
            }
            let point = CGPoint(x: x(index), y: y(value))
            if drawing { path.addLine(to: point) } else { path.move(to: point) }
            drawing = true
        }
        return path
    }
}

/// Output minus input over time: positive means raised, negative means turned down.
struct ChangeChart: View {
    let samples: [LevelSample]
    let capacity: Int
    private let limit = 20.0

    var body: some View {
        Canvas { context, size in
            let labelWidth: CGFloat = 34
            let plot = CGRect(x: labelWidth, y: 4, width: size.width - labelWidth, height: size.height - 8)
            let zero = plot.midY
            func y(_ change: Double) -> CGFloat {
                zero - CGFloat(min(max(change, -limit), limit) / limit) * plot.height / 2
            }
            let barWidth = max(plot.width / CGFloat(max(capacity, 1)), 0.5)
            let offset = capacity - samples.count

            for level in [-limit, 0, limit] {
                var grid = Path()
                grid.move(to: CGPoint(x: plot.minX, y: y(level)))
                grid.addLine(to: CGPoint(x: plot.maxX, y: y(level)))
                context.stroke(grid, with: .color(.secondary.opacity(level == 0 ? 0.5 : 0.15)), lineWidth: 1)
                context.draw(
                    Text(level == 0 ? "0" : String(format: "%+.0f", level)).font(.caption2).foregroundStyle(.secondary),
                    at: CGPoint(x: labelWidth - 4, y: y(level)), anchor: .trailing)
            }

            for (index, sample) in samples.enumerated() {
                guard let input = sample.input, let output = sample.output else { continue }
                let change = output - input
                guard abs(change) > 0.1 else { continue }
                let x = plot.minX + CGFloat(offset + index) / CGFloat(max(capacity - 1, 1)) * plot.width
                let top = min(y(change), zero)
                let rect = CGRect(x: x, y: top, width: barWidth, height: abs(y(change) - zero))
                context.fill(Path(rect), with: .color(change > 0 ? .green.opacity(0.7) : .orange.opacity(0.8)))
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Graph of how much sound is being raised or turned down over time")
    }
}
