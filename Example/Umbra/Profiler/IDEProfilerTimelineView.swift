import JavaIntelligence
import SwiftUI

/// The recording over time: a chart of the JVM's CPU load (heap use for allocations) with the
/// collections marked, then one lane per thread (green running, red waiting, blue allocating). Drag
/// across it to limit every other view to that time; click a lane to see the stack there.
struct IDEProfilerTimelineView: View {
    let session: IDEProfilerSession

    var body: some View {
        if let timeline = session.timeline {
            SplitPanes(minPrimary: 380, minSecondary: 220, defaultFraction: 0.7, storageKey: "umbra.profiler.timeline.split") {
                VStack(spacing: 0) {
                    IDEProfilerTimelineChart(session: session, timeline: timeline)
                        .frame(height: IDEProfilerTimelineLayout.chartHeight + IDEProfilerTimelineLayout.axisHeight)
                    Divider()
                    ScrollView(.vertical) {
                        IDEProfilerTimelineLanes(session: session, timeline: timeline)
                    }
                    if timeline.omittedLanes > 0 {
                        Text("\(timeline.omittedLanes.formatted()) quieter threads not shown")
                            .font(IDEAppearance.Typography.caption)
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                            .padding(4)
                    }
                }
            } secondary: {
                IDEProfilerTimelineEventPanel(session: session)
            }
        } else {
            Text("This recording has no event times, so there is no timeline.")
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

enum IDEProfilerTimelineLayout {
    static let gutter: CGFloat = 150
    static let chartHeight: CGFloat = 84
    static let axisHeight: CGFloat = 18
    static let laneHeight: CGFloat = 18
    static let trailing: CGFloat = 8

    /// Milliseconds at `x` in a canvas that is `width` wide.
    static func time(atX x: CGFloat, width: CGFloat, span: ClosedRange<Int32>) -> Int32 {
        let plot = max(width - gutter - trailing, 1)
        let fraction = min(max((x - gutter) / plot, 0), 1)
        return span.lowerBound + Int32(fraction * CGFloat(span.upperBound - span.lowerBound))
    }

    static func x(forTime time: Int32, width: CGFloat, span: ClosedRange<Int32>) -> CGFloat {
        let plot = max(width - gutter - trailing, 1)
        let length = max(CGFloat(span.upperBound - span.lowerBound), 1)
        return gutter + CGFloat(time - span.lowerBound) / length * plot
    }
}

private func timelineRangeOverlay(
    _ context: inout GraphicsContext, size: CGSize, span: ClosedRange<Int32>, range: ClosedRange<Int32>?, drag: ClosedRange<Int32>?
) {
    for (value, opacity) in [(range, 0.16), (drag, 0.25)] {
        guard let value else { continue }
        let left = IDEProfilerTimelineLayout.x(forTime: value.lowerBound, width: size.width, span: span)
        let right = IDEProfilerTimelineLayout.x(forTime: value.upperBound, width: size.width, span: span)
        let rect = CGRect(x: left, y: 0, width: max(right - left, 1), height: size.height)
        context.fill(Path(rect), with: .color(.accentColor.opacity(opacity)))
        context.fill(Path(CGRect(x: left, y: 0, width: 1, height: size.height)), with: .color(.accentColor))
        context.fill(Path(CGRect(x: right, y: 0, width: 1, height: size.height)), with: .color(.accentColor))
    }
}

/// Reads a drag across the plot as a time range, and a click as a point.
private struct IDEProfilerTimelineDrag: ViewModifier {
    let session: IDEProfilerSession
    let span: ClosedRange<Int32>
    @Binding var drag: ClosedRange<Int32>?
    /// A click (a drag shorter than three points): its place, and the width the plot was drawn at.
    var onClick: ((CGPoint, CGFloat) -> Void)?
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { proxy in
                Color.clear.onAppear { width = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, value in width = value }
            })
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard abs(value.translation.width) >= 3 else { return }
                        let a = IDEProfilerTimelineLayout.time(atX: value.startLocation.x, width: width, span: span)
                        let b = IDEProfilerTimelineLayout.time(atX: value.location.x, width: width, span: span)
                        drag = min(a, b)...max(a, b)
                    }
                    .onEnded { value in
                        defer { drag = nil }
                        if abs(value.translation.width) < 3 {
                            onClick?(value.location, width)
                            return
                        }
                        let a = IDEProfilerTimelineLayout.time(atX: value.startLocation.x, width: width, span: span)
                        let b = IDEProfilerTimelineLayout.time(atX: value.location.x, width: width, span: span)
                        if a != b { session.timeRange = min(a, b)...max(a, b) }
                    }
            )
    }
}

// MARK: - Chart

private struct IDEProfilerTimelineChart: View {
    let session: IDEProfilerSession
    let timeline: JavaProfileTimeline
    @State private var drag: ClosedRange<Int32>?

    var body: some View {
        let showsHeap = session.kind == .allocations && !timeline.heap.isEmpty
        Canvas { context, size in
            let layout = IDEProfilerTimelineLayout.self
            let plot = CGRect(
                x: layout.gutter, y: 4, width: max(size.width - layout.gutter - layout.trailing, 1), height: layout.chartHeight - 8
            )
            context.fill(Path(plot), with: .color(Color.primary.opacity(0.04)))

            for band in timeline.gcBands {
                let x = layout.x(forTime: band.start, width: size.width, span: timeline.span)
                let end = layout.x(
                    forTime: band.start + Int32(clamping: Int(band.milliseconds.rounded(.up))), width: size.width, span: timeline.span
                )
                context.fill(Path(CGRect(x: x, y: plot.minY, width: max(end - x, 2), height: plot.height)), with: .color(.orange.opacity(0.45)))
            }

            if showsHeap {
                let maximum = max(timeline.heap.map(\.usedBytes).max() ?? 1, 1)
                var path = Path()
                var started = false
                for point in timeline.heap {
                    let x = layout.x(forTime: point.time, width: size.width, span: timeline.span)
                    let y = plot.maxY - plot.height * CGFloat(point.usedBytes) / CGFloat(maximum)
                    if started { path.addLine(to: CGPoint(x: x, y: y)) } else { path.move(to: CGPoint(x: x, y: y)); started = true }
                }
                context.stroke(path, with: .color(.blue), lineWidth: 1.5)
                let label = "Heap · peak " + ByteCountFormatter.string(fromByteCount: Int64(maximum), countStyle: .memory)
                context.draw(Text(label).font(.caption2).foregroundColor(.secondary), at: CGPoint(x: 8, y: plot.minY + 8), anchor: .leading)
            } else {
                // `jdk.CPULoad` is one reading per second of the second before it: a bar back to
                // the previous reading (or a second before the first).
                func bars(_ value: (JavaLoadPoint) -> Float, color: Color) {
                    var previous = timeline.span.lowerBound
                    for (index, point) in timeline.cpuLoad.enumerated() {
                        let start = index == 0 ? max(point.time - 1_000, timeline.span.lowerBound) : previous
                        let left = layout.x(forTime: start, width: size.width, span: timeline.span)
                        let right = layout.x(forTime: point.time, width: size.width, span: timeline.span)
                        let level = plot.height * CGFloat(min(max(value(point), 0), 1))
                        context.fill(
                            Path(CGRect(x: left, y: plot.maxY - max(level, 1), width: max(right - left - 1, 1), height: max(level, 1))),
                            with: .color(color)
                        )
                        previous = point.time
                    }
                }
                bars({ $0.machineTotal }, color: .gray.opacity(0.35))
                bars({ $0.jvmTotal }, color: .green.opacity(0.7))
                context.draw(
                    Text(timeline.cpuLoad.isEmpty ? "CPU load: not recorded" : "CPU load · JVM (green) of machine (grey)")
                        .font(.caption2).foregroundColor(.secondary),
                    at: CGPoint(x: 8, y: plot.minY + 8), anchor: .leading
                )
            }

            // Seconds along the bottom.
            let length = Double(timeline.span.upperBound - timeline.span.lowerBound)
            let step = Self.tickStep(forSeconds: length / 1000)
            var seconds = 0.0
            while seconds * 1000 <= length {
                let x = layout.x(forTime: timeline.span.lowerBound + Int32(seconds * 1000), width: size.width, span: timeline.span)
                context.fill(Path(CGRect(x: x, y: plot.maxY, width: 1, height: 4)), with: .color(.secondary))
                context.draw(
                    Text(String(format: step < 1 ? "%.1f s" : "%.0f s", seconds)).font(.caption2).foregroundColor(.secondary),
                    at: CGPoint(x: x + 3, y: plot.maxY + 12), anchor: .leading
                )
                seconds += step
            }
            timelineRangeOverlay(&context, size: size, span: timeline.span, range: session.timeRange, drag: drag)
        }
        .modifier(IDEProfilerTimelineDrag(session: session, span: timeline.span, drag: $drag))
    }

    /// A tick spacing in seconds that leaves about ten labels.
    static func tickStep(forSeconds seconds: Double) -> Double {
        let raw = max(seconds / 10, 0.01)
        let magnitude = pow(10, floor(log10(raw)))
        for factor in [1.0, 2, 5, 10] where factor * magnitude >= raw { return factor * magnitude }
        return 10 * magnitude
    }
}

// MARK: - Lanes

private struct IDEProfilerTimelineLanes: View {
    let session: IDEProfilerSession
    let timeline: JavaProfileTimeline
    @State private var drag: ClosedRange<Int32>?

    var body: some View {
        let layout = IDEProfilerTimelineLayout.self
        let height = CGFloat(timeline.lanes.count) * layout.laneHeight
        Canvas { context, size in
            let plotWidth = max(size.width - layout.gutter - layout.trailing, 1)
            let bucketWidth = plotWidth / CGFloat(timeline.bucketCount)
            for (index, lane) in timeline.lanes.enumerated() {
                let y = CGFloat(index) * layout.laneHeight
                if index % 2 == 1 {
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: layout.laneHeight)), with: .color(Color.primary.opacity(0.03)))
                }
                context.draw(
                    Text(lane.name).font(.caption).foregroundColor(session.thread == lane.name ? .accentColor : .primary),
                    at: CGPoint(x: 8, y: y + layout.laneHeight / 2), anchor: .leading
                )
                for bucket in 0..<timeline.bucketCount {
                    let x = layout.gutter + CGFloat(bucket) * bucketWidth
                    let wait = lane.waiting[bucket]
                    if wait > 0.02 {
                        context.fill(
                            Path(CGRect(x: x, y: y + 3, width: bucketWidth + 0.5, height: layout.laneHeight - 6)),
                            with: .color(.red.opacity(0.25 + 0.65 * Double(wait)))
                        )
                    }
                    let run = lane.running[bucket]
                    if run > 0.02 {
                        context.fill(
                            Path(CGRect(x: x, y: y + 3, width: bucketWidth + 0.5, height: layout.laneHeight - 6)),
                            with: .color(.green.opacity(0.3 + 0.7 * Double(run)))
                        )
                    }
                    if lane.allocated[bucket] > 0 {
                        context.fill(
                            Path(CGRect(x: x, y: y + layout.laneHeight - 5, width: bucketWidth + 0.5, height: 3)),
                            with: .color(.blue.opacity(0.85))
                        )
                    }
                }
            }
            if let event = session.timelineEvent {
                let x = layout.x(forTime: event.time, width: size.width, span: timeline.span)
                context.fill(Path(CGRect(x: x, y: 0, width: 1.5, height: size.height)), with: .color(.accentColor))
            }
            timelineRangeOverlay(&context, size: size, span: timeline.span, range: session.timeRange, drag: drag)
        }
        .frame(height: max(height, 1))
        .modifier(IDEProfilerTimelineDrag(session: session, span: timeline.span, drag: $drag) { point, width in
            let index = Int(point.y / layout.laneHeight)
            guard index >= 0, index < timeline.lanes.count else { return }
            let time = layout.time(atX: point.x, width: width, span: timeline.span)
            // A bucket and a half either side: a click on a bar, not on a pixel of it.
            let tolerance = max(Int32(timeline.bucketMilliseconds * 1.5), 15)
            session.selectTimelineEvent(thread: timeline.lanes[index].name, near: time, toleranceMilliseconds: tolerance)
        })
    }
}

// MARK: - Event panel

private struct IDEProfilerTimelineEventPanel: View {
    let session: IDEProfilerSession

    var body: some View {
        if let event = session.timelineEvent, let symbols = session.symbols {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: icon(for: event.kind))
                    Text("\(event.thread) · \(session.formattedOffset(event.time))")
                        .font(IDEAppearance.Typography.body)
                    Spacer(minLength: 0)
                    Button("Copy Stack") { copyStack(symbols: symbols) }
                        .controlSize(.small)
                }
                .padding(IDEAppearance.Spacing.xs)
                Divider()
                List {
                    ForEach(Array(session.timelineEventFrames.enumerated()), id: \.offset) { _, frame in
                        HStack(spacing: 4) {
                            Text(IDEFlameGraphNSView.label(frame: frame, symbols: symbols))
                                .font(IDEAppearance.Typography.body)
                                .lineLimit(1)
                            if symbols.frame(frame).line > 0 {
                                Text(":\(symbols.frame(frame).line)")
                                    .font(IDEAppearance.Typography.monoSmall)
                                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            session.openSource(ofMethod: symbols.frame(frame).method, line: Int(symbols.frame(frame).line))
                        }
                    }
                }
                .listStyle(.plain)
            }
        } else {
            Text("Click a thread's bar to see its stack there. Drag across the timeline to limit every view to that time.")
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func icon(for kind: JavaSampleKind) -> String {
        switch kind {
        case .cpu: return "play.fill"
        case .allocation: return "memorychip"
        case .contention: return "pause.fill"
        }
    }

    private func copyStack(symbols: JavaProfileSymbols) {
        let lines = session.timelineEventFrames.map { frame -> String in
            let line = symbols.frame(frame).line
            let name = symbols.qualifiedName(ofMethod: symbols.frame(frame).method)
            return line > 0 ? "\(name):\(line)" : name
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
