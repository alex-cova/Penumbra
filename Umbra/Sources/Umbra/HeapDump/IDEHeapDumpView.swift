import JavaIntelligence
import SwiftUI

/// The heap dump tab: a header (mode, grouping, filter), and under it the Summary or the class
/// Histogram. Phase 1 of `docs/HEAP_DUMP_PLAN.md`: counts and shallow sizes of every object in the
/// file, before any reachability.
struct IDEHeapDumpView: View {
    let session: IDEHeapDumpSession

    var body: some View {
        VStack(spacing: 0) {
            if session.phase == .ready {
                header
                Divider()
            }
            content
        }
        .background(IDEAppearance.ColorToken.editor)
    }

    // MARK: - Header

    private var header: some View {
        @Bindable var session = session
        return HStack(spacing: IDEAppearance.Spacing.sm) {
            Picker("View", selection: $session.mode) {
                ForEach(IDEHeapDumpSession.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            if session.mode == .histogram {
                Picker("Group by", selection: $session.grouping) {
                    ForEach(IDEHeapDumpSession.Grouping.allCases) { Text("By \($0.rawValue)").tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
                TextField("Filter classes (a.b.*Foo for a pattern)", text: $session.filterText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 280)
            }
            Spacer(minLength: 0)
            Menu {
                Button("Reload") { session.load() }
                Button("Reveal in Finder") { session.revealInFinder?() }
                Button("Open as Hex") { session.openAsHex?() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("More")
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.xs)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .idle:
            status("Heap dump not read.", detail: nil) {
                Button("Read") { session.load() }
            }
        case .reading(let progress):
            VStack(spacing: IDEAppearance.Spacing.sm) {
                ProgressView(value: progress.fraction)
                    .frame(width: 260)
                Text("\(progress.phase.rawValue)…")
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                if progress.bytesTotal > 0 {
                    Text("\(Self.bytes(progress.bytesDone)) of \(Self.bytes(progress.bytesTotal))")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .monospacedDigit()
                }
                Button("Cancel") { session.cancel() }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: IDEAppearance.Spacing.sm) {
                Text(message)
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                HStack {
                    Button("Try Again") { session.load() }
                    Button("Open as Hex") { session.openAsHex?() }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            if let overview = session.overview {
                switch session.mode {
                case .summary: IDEHeapDumpSummaryView(session: session, overview: overview)
                case .histogram: IDEHeapDumpHistogramView(session: session)
                }
            }
        }
    }

    private func status<Actions: View>(_ text: String, detail: String?, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: IDEAppearance.Spacing.sm) {
            Text(text)
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            if let detail {
                Text(detail)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            actions()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .memory)
    }
}

/// Every object in the file is counted, reachable or not: an out-of-memory dump is written
/// without a collection first, and telling garbage apart needs the reference graph (phase 3).
private let unreachableNote = "Counts and sizes cover every object in the file, including unreachable ones. An out-of-memory dump is written without a garbage collection, so totals can be larger than tools that drop garbage on open (Eclipse MAT) report."

// MARK: - Summary

struct IDEHeapDumpSummaryView: View {
    let session: IDEHeapDumpSession
    let overview: HeapDumpOverview

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
                if overview.truncatedAt != nil || !overview.problems.isEmpty {
                    problems
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: IDEAppearance.Spacing.md, alignment: .top)],
                          alignment: .leading, spacing: IDEAppearance.Spacing.md) {
                    card("Heap") {
                        row("Objects", overview.objectCount.formatted())
                        row("Shallow size", IDEHeapDumpView.bytes(histogram.totalShallowBytes))
                        row("Instances", overview.instanceCount.formatted())
                        row("Object arrays", overview.objectArrayCount.formatted())
                        row("Primitive arrays", overview.primitiveArrayCount.formatted())
                        row("Classes", overview.classCount.formatted())
                        row("Class loaders", overview.classLoaderCount.formatted())
                    }
                    card("GC Roots") {
                        row("Total", overview.rootCount.formatted())
                        ForEach(rootKinds, id: \.self) { kind in
                            row(kind.rawValue, (overview.rootCounts[kind] ?? 0).formatted())
                        }
                        row("Threads", overview.threadCount.formatted())
                    }
                    card("File") {
                        // Decimal units, as Finder shows file sizes; heap sizes use binary units, as JVMs do.
                        row("Size", ByteCountFormatter.string(fromByteCount: overview.fileSize, countStyle: .file))
                        row("Format", overview.header.version)
                        row("Identifier size", "\(overview.header.idSize) bytes")
                        row("Written", overview.header.timestamp.formatted(date: .abbreviated, time: .standard))
                        row("Read in", String(format: "%.1f s", overview.elapsed))
                    }
                    layoutCard
                    IDEHeapIndexCard(objects: session.objects)
                }
                topClasses
                Text(unreachableNote)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(IDEAppearance.Spacing.lg)
            .frame(maxWidth: 1100, alignment: .leading)
        }
    }

    private var histogram: HeapHistogram {
        session.layoutOverride.map { overview.histogram(layout: $0) } ?? overview.histogram
    }

    private var rootKinds: [HprofRootKind] {
        HprofRootKind.allCases.filter { (overview.rootCounts[$0] ?? 0) > 0 && $0 != .threadObject }
    }

    private var layoutCard: some View {
        @Bindable var session = session
        return card("Object Layout") {
            Text(overview.layout.description)
                .font(IDEAppearance.Typography.caption)
                .fixedSize(horizontal: false, vertical: true)
            Text(layoutEvidence)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .fixedSize(horizontal: false, vertical: true)
            if overview.availableLayouts.count > 1 {
                Picker("Sizes use", selection: $session.layoutOverride) {
                    Text("Detected").tag(HeapObjectLayout?.none)
                    ForEach(overview.availableLayouts, id: \.self) { layout in
                        Text(layout.shortDescription).tag(HeapObjectLayout?.some(layout))
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private var layoutEvidence: String {
        guard let confidence = overview.layoutConfidence else {
            return "The dump gave too little evidence, so this is the usual default. HPROF does not record the layout; sizes are estimates."
        }
        return String(
            format: "Predicts %.1f%% of %@ sampled neighbour gaps. HPROF does not record the layout; sizes are estimates.",
            confidence * 100, overview.layoutSampleCount.formatted()
        )
    }

    private var problems: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            if let offset = overview.truncatedAt {
                Text("The file ends early (at byte \(offset.formatted())). What was read before that point is shown.")
            }
            ForEach(overview.problems, id: \.self) { Text($0) }
        }
        .font(IDEAppearance.Typography.caption)
        .foregroundStyle(IDEAppearance.ColorToken.error)
        .textSelection(.enabled)
        .padding(IDEAppearance.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IDEAppearance.ColorToken.error.opacity(IDEAppearance.Opacity.tintWash * 0.5),
                    in: RoundedRectangle(cornerRadius: IDEAppearance.Radius.card))
    }

    private var topClasses: some View {
        let top = Array(histogram.rows.prefix(10))
        let total = max(histogram.totalShallowBytes, 1)
        return card("Largest Classes by Shallow Size") {
            ForEach(top) { row in
                Button {
                    session.showInHistogram(row.name)
                } label: {
                    HStack(spacing: IDEAppearance.Spacing.sm) {
                        Text(row.name)
                            .font(IDEAppearance.Typography.monoSmall)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: IDEAppearance.Spacing.sm)
                        Text(row.count.formatted())
                            .font(IDEAppearance.Typography.monoSmall)
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                        Text(IDEHeapDumpView.bytes(row.shallowBytes))
                            .font(IDEAppearance.Typography.monoSmall)
                            .frame(width: 80, alignment: .trailing)
                        IDEHeapShareBar(share: Double(row.shallowBytes) / Double(total))
                            .frame(width: 80)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show \(row.name) in the histogram")
            }
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            Text(title)
                .font(IDEAppearance.Typography.sectionHeader)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            content()
        }
        .padding(IDEAppearance.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IDEAppearance.ColorToken.card, in: RoundedRectangle(cornerRadius: IDEAppearance.Radius.card))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Spacer(minLength: IDEAppearance.Spacing.sm)
            Text(value)
                .monospacedDigit()
                .textSelection(.enabled)
        }
        .font(IDEAppearance.Typography.caption)
    }
}

/// A thin bar for a share of the heap, 0...1.
struct IDEHeapShareBar: View {
    let share: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(IDEAppearance.ColorToken.border)
                Capsule().fill(IDEAppearance.ColorToken.accent)
                    .frame(width: max(2, proxy.size.width * min(max(share, 0), 1)))
            }
        }
        .frame(height: 4)
        .accessibilityLabel(String(format: "%.1f percent", share * 100))
    }
}

// MARK: - Histogram

struct IDEHeapDumpHistogramView: View {
    let session: IDEHeapDumpSession

    var body: some View {
        if session.objects.store == nil {
            classes
        } else {
            SplitPanes(minPrimary: 320, minSecondary: 320, defaultFraction: 0.5, storageKey: "umbra.heapDump.histogram.split") {
                classes
            } secondary: {
                IDEHeapObjectsPane(session: session)
            }
        }
    }

    @ViewBuilder
    private var classes: some View {
        @Bindable var session = session
        let total = max(session.histogram?.totalShallowBytes ?? 1, 1)
        VStack(spacing: 0) {
            Table(session.visibleRows, selection: $session.selectedRowIDs, sortOrder: $session.sortOrder) {
                TableColumn(session.grouping == .byPackage ? "Package" : "Class", value: \.name) { row in
                    Text(row.name)
                        .font(IDEAppearance.Typography.monoSmall)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.name)
                }
                TableColumn("Objects", value: \.count) { row in
                    Text(row.count.formatted())
                        .font(IDEAppearance.Typography.monoSmall)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 60, ideal: 84, max: 130)
                TableColumn("Shallow Size", value: \.shallowBytes) { row in
                    Text(IDEHeapDumpView.bytes(row.shallowBytes))
                        .font(IDEAppearance.Typography.monoSmall)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help("\(row.shallowBytes.formatted()) bytes")
                }
                .width(min: 60, ideal: 80, max: 130)
                TableColumn("% of Heap", value: \.shallowBytes) { row in
                    let share = Double(row.shallowBytes) / Double(total)
                    HStack(spacing: IDEAppearance.Spacing.xs) {
                        Text(String(format: "%.1f%%", share * 100))
                            .font(IDEAppearance.Typography.monoSmall)
                            .frame(width: 48, alignment: .trailing)
                        IDEHeapShareBar(share: share)
                    }
                }
                .width(min: 90, ideal: 110, max: 200)
            }
            .contextMenu(forSelectionType: HeapClassRow.ID.self) { ids in
                if let row = row(ids.first) {
                    if IDEHeapDumpSession.sourceClassName(of: row) != nil {
                        Button("Jump to Source") { session.openSource(of: row) }
                    }
                    if row.kind == .package {
                        Button("Show Classes in Package") {
                            session.grouping = .byClass
                            session.filterText = row.name.hasPrefix("(") ? "" : row.name + "."
                        }
                    }
                    Button("Copy Name") { copy(row.name) }
                }
                if ids.count > 1 {
                    Button("Copy \(ids.count) Rows") { copy(rows(ids)) }
                }
            } primaryAction: { ids in
                guard let row = row(ids.first) else { return }
                if row.kind == .package {
                    session.grouping = .byClass
                    session.filterText = row.name.hasPrefix("(") ? "" : row.name + "."
                } else {
                    session.openSource(of: row)
                }
            }
            Divider()
            footer
        }
    }

    private var footer: some View {
        let shown = session.visibleRows
        let objects = shown.reduce(0) { $0 + $1.count }
        let bytes = shown.reduce(Int64(0)) { $0 + $1.shallowBytes }
        let noun = session.grouping == .byPackage ? "packages" : "classes"
        return HStack(spacing: IDEAppearance.Spacing.sm) {
            Text("\(shown.count.formatted()) \(noun) · \(objects.formatted()) objects · \(IDEHeapDumpView.bytes(bytes))")
                .monospacedDigit()
            Spacer(minLength: IDEAppearance.Spacing.sm)
            Text("All objects in the file, including unreachable ones")
                .help(unreachableNote)
        }
        .font(IDEAppearance.Typography.caption)
        .foregroundStyle(IDEAppearance.ColorToken.muted)
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.xs)
    }

    private func row(_ id: HeapClassRow.ID?) -> HeapClassRow? {
        guard let id else { return nil }
        return session.visibleRows.first { $0.id == id }
    }

    /// Tab-separated, for a spreadsheet: name, objects, shallow bytes.
    private func rows(_ ids: Set<HeapClassRow.ID>) -> String {
        session.visibleRows.filter { ids.contains($0.id) }
            .map { "\($0.name)\t\($0.count)\t\($0.shallowBytes)" }
            .joined(separator: "\n")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
