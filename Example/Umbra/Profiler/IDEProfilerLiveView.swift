import Charts
import JavaIntelligence
import SwiftUI

/// Charts of a profiled run while it runs, as IntelliJ's live charts: CPU, heap, threads and
/// non-heap memory against time, with the actions a live process offers.
struct IDEProfilerLiveView: View {
    let session: IDEProfilerSession

    var body: some View {
        if let monitor = session.live {
            VStack(spacing: 0) {
                toolbar(monitor)
                Divider()
                if monitor.samples.count < 2 {
                    waiting(monitor)
                } else {
                    ScrollView {
                        VStack(spacing: IDEAppearance.Spacing.md) {
                            IDELiveChart(title: "CPU", unit: "%", samples: monitor.samples) { [$0.cpuPercent] }
                                .series(["JVM"], colors: [.green])
                            IDELiveChart(title: "Heap", unit: "MB", samples: monitor.samples) {
                                [$0.heapUsedBytes.map(Self.megabytes), $0.heapCommittedBytes.map(Self.megabytes)]
                            }
                            .series(["Used", "Committed"], colors: [.blue, .gray])
                            IDELiveChart(title: "Threads", unit: "", samples: monitor.samples) {
                                [$0.liveThreads.map(Double.init), $0.daemonThreads.map(Double.init)]
                            }
                            .series(["Live", "Daemon"], colors: [.orange, .red])
                            IDELiveChart(title: "Non-heap (metaspace)", unit: "MB", samples: monitor.samples) {
                                [$0.metaspaceUsedBytes.map(Self.megabytes)]
                            }
                            .series(["Used"], colors: [.purple])
                        }
                        .padding(IDEAppearance.Spacing.sm)
                    }
                }
            }
        }
    }

    private static func megabytes(_ bytes: Int) -> Double { Double(bytes) / 1_048_576 }

    private func toolbar(_ monitor: IDEProfilerLiveMonitor) -> some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Circle()
                .fill(monitor.status == .ended ? Color.gray : Color.green)
                .frame(width: 8, height: 8)
            Text(statusText(monitor))
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            if let notice = monitor.notice {
                Text(notice)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
                    .help(notice)
            }
            Spacer(minLength: 0)
            Button("Capture Snapshot") {
                Task {
                    if let url = await monitor.captureSnapshot() { session.openSnapshot?(url) }
                }
            }
            .disabled(monitor.pid == nil || monitor.isBusy)
            .help("Writes the recording so far and opens it, without stopping the program")
            Button("Perform GC") { Task { await monitor.collectGarbage() } }
                .disabled(monitor.pid == nil || monitor.isBusy)
            Button("Stop and Show Results") { session.stopRun?() }
                .keyboardShortcut(.cancelAction)
        }
        .controlSize(.small)
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.xs)
    }

    private func statusText(_ monitor: IDEProfilerLiveMonitor) -> String {
        switch monitor.status {
        case .waiting: return "Waiting for the JVM to start…"
        case .attached(let pid): return "Recording · process \(pid)"
        case .ended: return "The program ended"
        }
    }

    private func waiting(_ monitor: IDEProfilerLiveMonitor) -> some View {
        VStack(spacing: IDEAppearance.Spacing.xs) {
            ProgressView().controlSize(.small)
            Text(monitor.status == .waiting ? "Waiting for the JVM to start…" : "Reading the first values…")
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Text("The report opens here when the program ends.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One chart: up to a few lines over the monitor's samples. A reading the JVM did not give is a gap.
private struct IDELiveChart: View {
    let title: String
    let unit: String
    let samples: [IDEProfilerLiveMonitor.Sample]
    let values: (IDEProfilerLiveMonitor.Sample) -> [Double?]
    var names: [String] = []
    var colors: [Color] = []

    init(
        title: String, unit: String, samples: [IDEProfilerLiveMonitor.Sample],
        values: @escaping (IDEProfilerLiveMonitor.Sample) -> [Double?]
    ) {
        self.title = title
        self.unit = unit
        self.samples = samples
        self.values = values
    }

    func series(_ names: [String], colors: [Color]) -> IDELiveChart {
        var copy = self
        copy.names = names
        copy.colors = colors
        return copy
    }

    private struct Point: Identifiable {
        var id: String { "\(series)-\(second)" }
        var series: String
        var second: Double
        var value: Double
    }

    private var points: [Point] {
        samples.flatMap { sample in
            values(sample).enumerated().compactMap { index, value -> Point? in
                guard let value, index < names.count else { return nil }
                return Point(series: names[index], second: sample.seconds, value: value)
            }
        }
    }

    var body: some View {
        let points = points
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                Text(title).font(IDEAppearance.Typography.caption).fontWeight(.semibold)
                if let last = points.last(where: { $0.series == names.first }) {
                    Text(String(format: "%.0f", last.value) + (unit.isEmpty ? "" : " " + unit))
                        .font(IDEAppearance.Typography.monoSmall)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                Spacer(minLength: 0)
            }
            if points.isEmpty {
                Text("Not available")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(maxWidth: .infinity, minHeight: 70)
            } else {
                Chart(points) { point in
                    LineMark(x: .value("Time", point.second), y: .value(title, point.value))
                        .foregroundStyle(by: .value("Series", point.series))
                        .interpolationMethod(.monotone)
                }
                .chartForegroundStyleScale(domain: names, range: colors)
                .chartYScale(domain: .automatic(includesZero: true))
                .chartXAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let seconds = value.as(Double.self) { Text("\(Int(seconds)) s") }
                        }
                    }
                }
                .chartLegend(names.count > 1 ? .visible : .hidden)
                .frame(height: 96)
            }
        }
    }
}
