import JavaIntelligence
import SwiftUI

/// The profiler tab: a header (what to look at, search, view), and under it the flame graph, the hot
/// methods table or the call tree of the selected kind of event.
struct IDEProfilerView: View {
    let session: IDEProfilerSession

    var body: some View {
        VStack(spacing: 0) {
            // A run in progress has its own toolbar; the report's controls come with the report.
            if session.phase != .live {
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
        return VStack(spacing: IDEAppearance.Spacing.xs) {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                Picker("Event", selection: $session.kind) {
                    ForEach(IDEProfilerSession.Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
                .disabled(session.profile == nil)

                if session.kind != .gc, !session.threadNames.isEmpty {
                    Picker("Thread", selection: $session.thread) {
                        Text("All Threads").tag(String?.none)
                        ForEach(session.threadNames, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                }
                Spacer(minLength: 0)
                compareMenu
                presentationMenu
                exportMenu
            }
            .ideIconButtonSize(.compact)
            HStack(spacing: IDEAppearance.Spacing.sm) {
                if session.kind != .gc {
                    Picker("View", selection: $session.mode) {
                        ForEach(IDEProfilerSession.Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 400)
                    TextField("Find method", text: $session.searchText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(maxWidth: 220)
                        .onSubmit { session.nextMatch() }
                    searchStepper
                }
                if !session.zoomStack.isEmpty, session.mode == .flame, session.kind != .gc {
                    Button { session.zoomOut() } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                        .controlSize(.small)
                        .keyboardShortcut(.escape, modifiers: [])
                    Button("Fit") { session.resetZoom() }
                        .controlSize(.small)
                        .help("Show the whole graph again")
                }
                Spacer(minLength: 0)
                Text(statusLine)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
            }
            if !session.transforms.isEmpty || !session.classFilters.isEmpty || session.timeRange != nil
                || session.baselineTitle != nil {
                transformChips
            }
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.xs)
    }

    /// Previous / next match and "3 of 12", shown while there is a search.
    @ViewBuilder
    private var searchStepper: some View {
        let matches = session.searchMatches
        if !session.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            HStack(spacing: 2) {
                IDEIconButton(systemImage: "chevron.up", help: "Previous occurrence", isDisabled: matches.isEmpty) {
                    session.previousMatch()
                }
                IDEIconButton(systemImage: "chevron.down", help: "Next occurrence", isDisabled: matches.isEmpty) {
                    session.nextMatch()
                }
                Text(matches.isEmpty ? "no match" : "\((session.searchCursor % max(matches.count, 1)) + 1) of \(matches.count.formatted())")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(minWidth: 52, alignment: .leading)
            }
            .ideIconButtonSize(.compact)
        }
    }

    /// Each "what if" as a removable chip, in the order applied.
    private var transformChips: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            if let title = session.baselineTitle {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left.arrow.right")
                    switch session.baselineState {
                    case .loading:
                        Text("Reading baseline \(title)…").font(IDEAppearance.Typography.caption)
                    case .failed(let message):
                        Text("Baseline: \(message)").font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.error)
                    default:
                        Text("vs. \(title)").font(IDEAppearance.Typography.caption)
                        if let notice = session.comparisonCompatibility?.message {
                            let blocking = session.comparisonCompatibility?.isIncompatible ?? false
                            Image(systemName: blocking ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(blocking ? IDEAppearance.ColorToken.error : Color.yellow)
                                .help(notice)
                            Text(notice)
                                .font(IDEAppearance.Typography.caption)
                                .foregroundStyle(blocking ? IDEAppearance.ColorToken.error : IDEAppearance.ColorToken.muted)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    Button { session.clearBaseline() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .help("Stop comparing")
                }
                .padding(.horizontal, IDEAppearance.Spacing.sm)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.orange.opacity(0.2)))
            }
            if let range = session.timeRange {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                    Text("\(session.formattedOffset(range.lowerBound)) – \(session.formattedOffset(range.upperBound))")
                        .font(IDEAppearance.Typography.caption)
                    Button { session.timeRange = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .help("Show the whole recording")
                }
                .padding(.horizontal, IDEAppearance.Spacing.sm)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor.opacity(IDEAppearance.Opacity.tintWash)))
            }
            ForEach(session.transforms) { transform in
                HStack(spacing: 4) {
                    Text(transform.title)
                        .font(IDEAppearance.Typography.caption)
                        .lineLimit(1)
                    Button { session.removeTransform(transform) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .help("Remove this filter")
                }
                .padding(.horizontal, IDEAppearance.Spacing.sm)
                .padding(.vertical, 3)
                .background(Capsule().fill(IDEAppearance.ColorToken.muted.opacity(IDEAppearance.Opacity.tintWash)))
            }
            ForEach(session.classFilters) { filter in
                HStack(spacing: 4) {
                    Image(systemName: "eye.slash")
                    Text(filter.title)
                        .font(IDEAppearance.Typography.caption)
                        .lineLimit(1)
                    Button { session.removeClassFilter(filter) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .help("Show these classes again")
                }
                .padding(.horizontal, IDEAppearance.Spacing.sm)
                .padding(.vertical, 3)
                .background(Capsule().fill(IDEAppearance.ColorToken.muted.opacity(IDEAppearance.Opacity.tintWash)))
            }
            if !session.transforms.isEmpty || !session.classFilters.isEmpty {
                Button("Clear Filters") {
                    session.transforms = []
                    session.classFilters = []
                }
                    .buttonStyle(.link)
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
    }

    /// Compare With Baseline: another open recording, a recent profiled run, or a file.
    private var compareMenu: some View {
        IDEProfilerCompareMenu(session: session)
    }

    private var presentationMenu: some View {
        IDEProfilerPresentationMenu(session: session)
    }

    private var exportMenu: some View {
        IDEIconMenu(systemImage: "square.and.arrow.up", help: "Export", isDisabled: session.profile == nil) {
            Button("Copy Flame Graph Image") { copyImage() }
                .disabled(session.mode != .flame || session.kind == .gc)
            Button("Save Flame Graph Image…") { saveImage() }
                .disabled(session.mode != .flame || session.kind == .gc)
            Divider()
            Button("Copy Folded Stacks") { copyFolded() }
            Button("Save Folded Stacks…") { saveFolded() }
            Divider()
            Button("Save a Copy of the Recording…") { saveRecording() }
            Button("Reveal in Finder") {
                if let url = session.primaryRecording { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Button("Open as Hex") { session.openAsHex?() }
        }
    }

    private var statusLine: String {
        guard let profile = session.profile else { return session.summaryLine }
        var parts = [session.totalDescription]
        if profile.cpu.isTruncated || profile.allocation.isTruncated || profile.contention.isTruncated {
            parts.append("some stacks folded into (other)")
        }
        if profile.truncatedSamples > 0 { parts.append("\(profile.truncatedSamples.formatted()) samples truncated") }
        if profile.threadsOverLimit > 0 { parts.append("thread filter covers the first \(JavaProfile.maximumThreads.formatted()) threads") }
        let dropped = [profile.cpuSamplesTable, profile.allocationSamplesTable, profile.contentionSamplesTable].reduce(0) { $0 + $1.dropped }
        if dropped > 0 { parts.append("thread filter covers the first \(JavaSampleTable.capacity.formatted()) samples") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .idle, .summarizing:
            status("Reading recording…", progress: true, detail: session.summaryLine)
        case .reading(let lines):
            status("Reading recording… \(lines.formatted()) lines", progress: true, detail: session.summaryLine)
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
        case .needsJDK:
            VStack(spacing: IDEAppearance.Spacing.sm) {
                Text("Reading a recording needs the `jfr` tool of a JDK (Java 11 or newer), and none was found.")
                    .font(IDEAppearance.Typography.body)
                    .multilineTextAlignment(.center)
                HStack {
                    Button("Choose a JDK…") { session.chooseJDK?() }
                    Button("Open as Hex") { session.openAsHex?() }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .needsConfirmation(let megabytes):
            VStack(spacing: IDEAppearance.Spacing.sm) {
                Text("This recording is \(megabytes.formatted()) MB. Reading it can take a while and a lot of memory.")
                    .font(IDEAppearance.Typography.body)
                    .multilineTextAlignment(.center)
                Button("Read Anyway") { session.load(confirmed: true) }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .live:
            IDEProfilerLiveView(session: session)
        case .ready:
            ready
        }
    }

    @ViewBuilder
    private var ready: some View {
        if session.kind == .gc {
            IDEProfilerGCTable(pauses: session.visibleGCPauses)
        } else if let tree = session.tree, tree.totalSamples > 0 {
            switch session.mode {
            case .flame:
                IDEFlameGraphView(session: session)
                    .overlay(alignment: .bottom) { selectionBar }
            case .hot:
                if let comparison = session.comparison {
                    IDEProfilerComparisonTable(session: session, comparison: comparison)
                } else {
                    IDEProfilerHotMethods(session: session)
                }
            case .tree:
                IDEProfilerCallTree(session: session)
            case .timeline:
                IDEProfilerTimelineView(session: session)
            }
        } else {
            status(emptyMessage, progress: false, detail: nil)
        }
    }

    private var emptyMessage: String {
        if !session.transforms.isEmpty || session.timeRange != nil { return "Nothing is left after these filters." }
        if session.isComparing, let compatibility = session.comparisonCompatibility, compatibility.isIncompatible,
           let message = compatibility.message {
            return message
        }
        switch session.kind {
        case .cpu: return "The recording has no CPU samples. A run shorter than the sample period (10 ms) leaves none."
        case .allocations: return "No allocation samples (Java 16 or newer records them)."
        case .locks: return "No waits were recorded above the threshold (monitors, parks, sleeps, sockets and files)."
        case .gc: return ""
        }
    }

    private func status(_ text: String, progress: Bool, detail: String?) -> some View {
        VStack(spacing: IDEAppearance.Spacing.xs) {
            if progress { ProgressView().controlSize(.small) }
            Text(text)
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .multilineTextAlignment(.center)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The selected method in the flame graph, with what it costs and a way to its source.
    @ViewBuilder
    private var selectionBar: some View {
        if let method = session.selectedMethod, let symbols = session.symbols,
           let row = session.hotMethods.first(where: { $0.method == method }) {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                Text(symbols.qualifiedName(ofMethod: method))
                    .font(IDEAppearance.Typography.monoSmall)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("self \(String(format: "%.1f", session.percent(row.selfCount)))% · total \(String(format: "%.1f", session.percent(row.totalCount)))%")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Spacer(minLength: 0)
                Button("Open Source") { session.openSource(ofMethod: method) }
                    .controlSize(.small)
                Button { session.selectedMethod = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .padding(.vertical, 6)
            .background(.regularMaterial)
        }
    }

    // MARK: - Export

    private func copyFolded() {
        guard let text = session.foldedStacks() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func saveFolded() {
        guard let text = session.foldedStacks() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (session.primaryRecording?.deletingPathExtension().lastPathComponent ?? "profile") + ".folded"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func copyImage() {
        guard let data = session.flameGraphView?.pngData(), let image = NSImage(data: data) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    private func saveImage() {
        guard let data = session.flameGraphView?.pngData() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = (session.primaryRecording?.deletingPathExtension().lastPathComponent ?? "profile") + ".png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    private func saveRecording() {
        guard let source = session.primaryRecording else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = source.lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.copyItem(at: source, to: url)
    }
}

extension IDEProfilerSession {
    /// What the header says before the stacks are in.
    var summaryLine: String {
        guard let summary else { return "" }
        var parts: [String] = []
        if summary.executionSamples > 0 { parts.append("\(summary.executionSamples.formatted()) CPU samples") }
        if summary.allocationSamples > 0 { parts.append("\(summary.allocationSamples.formatted()) allocation samples") }
        if let duration = summary.durationDescription { parts.append(duration) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Hide class

/// "Hide Class" and "Hide Package" for the context menus of the lists and the trees.
struct IDEProfilerHideClassButtons: View {
    let session: IDEProfilerSession
    let className: String

    var body: some View {
        let simple = className.split(whereSeparator: { $0 == "." || $0 == "$" }).last.map(String.init) ?? className
        if let pattern = JavaClassPattern(className) {
            Button("Hide Class \(simple)") { session.addClassFilter(.pattern(pattern)) }
        }
        if let package = IDEProfilerSession.packageName(of: className), let pattern = JavaClassPattern(package) {
            Button("Hide Package \(package)") { session.addClassFilter(.pattern(pattern)) }
        }
    }
}

// MARK: - Presentation

/// Percentages, recursion, the fade threshold and which classes are hidden.
private struct IDEProfilerPresentationMenu: View {
    let session: IDEProfilerSession
    @State private var isAskingForPattern = false
    @State private var patternText = ""

    var body: some View {
        @Bindable var session = session
        return IDEIconMenu(
            systemImage: "slider.horizontal.3",
            help: "Presentation Settings",
            isDisabled: session.profile == nil || session.kind == .gc
        ) {
            Picker("Percentages", selection: $session.percentBase) {
                ForEach(IDEProfilerSession.PercentBase.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline)
            Toggle("Collapse Recursive Calls", isOn: $session.collapsesRecursion)
            Menu("Fade Nodes Below") {
                ForEach([0.0, 0.5, 1, 2, 5], id: \.self) { value in
                    Button {
                        session.nodeThresholdPercent = value
                    } label: {
                        Text(value == 0 ? "Off" : "\(String(format: "%g", value))% of samples")
                        if session.nodeThresholdPercent == value { Image(systemName: "checkmark") }
                    }
                }
            }
            Divider()
            Menu("Hide Classes") {
                Toggle("JDK Classes", isOn: filterBinding(.jdk))
                Toggle("Libraries", isOn: filterBinding(.libraries))
                Divider()
                Button("Matching…") {
                    patternText = ""
                    isAskingForPattern = true
                }
                if !session.classFilters.isEmpty {
                    Divider()
                    Button("Show All Classes") { session.classFilters = [] }
                }
            }
        }
        .alert("Hide Classes", isPresented: $isAskingForPattern) {
            TextField("org.springframework, *Proxy", text: $patternText)
            Button("Hide") {
                for pattern in JavaClassPattern.list(from: patternText) { session.addClassFilter(.pattern(pattern)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Class names or packages, separated by commas. * stands for any characters. What a hidden class calls is shown under its caller.")
        }
    }

    private func filterBinding(_ filter: IDEProfilerSession.ClassFilter) -> Binding<Bool> {
        Binding(
            get: { session.classFilters.contains(filter) },
            set: { _ in session.toggleClassFilter(filter) }
        )
    }
}

// MARK: - Hot methods

/// The method list: a sortable table on one side, and on the other what the selected method is
/// called by and what it calls, as IntelliJ's Back Traces, Merged Callees and Callee List.
private struct IDEProfilerHotMethods: View {
    let session: IDEProfilerSession
    @State private var sortOrder = [KeyPathComparator(\IDEHotRow.selfCount, order: .reverse)]
    @State private var detail: Detail = .backTraces

    enum Detail: String, CaseIterable, Identifiable {
        case backTraces = "Back Traces"
        case mergedCallees = "Merged Callees"
        case calleeList = "Callee List"

        var id: String { rawValue }
    }

    var body: some View {
        SplitPanes(minPrimary: 280, minSecondary: 240, defaultFraction: 0.6, storageKey: "umbra.profiler.methods.split") {
            table
        } secondary: {
            detailPane
        }
    }

    private var table: some View {
        let symbols = session.symbols
        let rows = filtered(session.hotMethods, symbols: symbols).sorted(using: sortOrder)
        return Table(rows, selection: Binding(
            get: { session.selectedMethod },
            set: { session.selectedMethod = $0 }
        ), sortOrder: $sortOrder) {
            TableColumn("Method", value: \.name) { row in
                Text(row.name)
                    .font(IDEAppearance.Typography.body)
                    .lineLimit(1)
                    .help(symbols?.qualifiedName(ofMethod: row.method) ?? "")
            }
            TableColumn("Package", value: \.package) { row in
                Text(row.package)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
            }
            TableColumn("Self", value: \.selfCount) { row in
                Text(String(format: "%.1f%%", session.percent(row.selfCount)))
                    .font(IDEAppearance.Typography.monoSmall)
            }
            .width(60)
            TableColumn("Total", value: \.totalCount) { row in
                Text(String(format: "%.1f%%", session.percent(row.totalCount)))
                    .font(IDEAppearance.Typography.monoSmall)
            }
            .width(60)
        }
        .contextMenu(forSelectionType: Int32.self) { ids in
            if let id = ids.first {
                Button("Open Source") { session.openSource(ofMethod: id) }
                Divider()
                Button("Show Back Traces") { session.selectedMethod = id; detail = .backTraces }
                Button("Show Merged Callees") { session.selectedMethod = id; detail = .mergedCallees }
                if let className = session.symbols?.methods[Int(id)].className, !className.isEmpty {
                    Divider()
                    IDEProfilerHideClassButtons(session: session, className: className)
                }
            }
        } primaryAction: { ids in
            if let id = ids.first { session.openSource(ofMethod: id) }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let method = session.selectedMethod, let symbols = session.symbols {
            VStack(spacing: 0) {
                HStack {
                    Picker("Detail", selection: $detail) {
                        ForEach(Detail.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Spacer(minLength: 0)
                }
                .padding(IDEAppearance.Spacing.xs)
                Divider()
                switch detail {
                case .backTraces:
                    if let tree = session.detailTree(.backTrace, method: method) {
                        detailTree(tree, symbols: symbols)
                    }
                case .mergedCallees:
                    if let tree = session.detailTree(.mergedCallees, method: method) {
                        detailTree(tree, symbols: symbols)
                    }
                case .calleeList:
                    calleeList(of: method, symbols: symbols)
                }
            }
        } else {
            Text("Select a method to see who calls it and what it calls.")
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailTree(_ tree: JavaProfileTree, symbols: JavaProfileSymbols) -> some View {
        IDEProfilerFlatTree(
            session: session, tree: tree, symbols: symbols, allowsTransforms: false,
            resetID: "\(session.selectedMethod.map { Int($0) } ?? -1)"
        )
    }

    private func calleeList(of method: Int32, symbols: JavaProfileSymbols) -> some View {
        let callees = session.tree?.callees(of: method, symbols: symbols).prefix(100) ?? []
        return List {
            ForEach(Array(callees), id: \.method) { neighbour in
                HStack {
                    Text(symbols.displayName(ofMethod: neighbour.method))
                        .font(IDEAppearance.Typography.body)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(String(format: "%.1f%%", session.percent(neighbour.count)))
                        .font(IDEAppearance.Typography.monoSmall)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                .contentShape(Rectangle())
                .accessibilityAddTraits(.isButton)
                .onTapGesture { session.selectedMethod = neighbour.method }
            }
        }
        .listStyle(.plain)
    }

    private func filtered(_ rows: [JavaProfileTree.HotMethod], symbols: JavaProfileSymbols?) -> [IDEHotRow] {
        let query = session.searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard let symbols else { return [] }
        return rows
            .filter { query.isEmpty || symbols.qualifiedName(ofMethod: $0.method).lowercased().contains(query) }
            .prefix(2_000)
            .map {
                IDEHotRow(
                    method: $0.method, name: symbols.displayName(ofMethod: $0.method),
                    package: symbols.packageName(ofMethod: $0.method), selfCount: $0.selfCount, totalCount: $0.totalCount
                )
            }
    }
}

struct IDEHotRow: Identifiable {
    var id: Int32 { method }
    var method: Int32
    var name: String
    var package: String
    var selfCount: Int
    var totalCount: Int
}

// MARK: - Compare menu

/// The ⇄ menu. Its candidates (open tabs, and the run folders on disk) are read when it appears and
/// when a baseline is set or cleared, not on every render of the header.
private struct IDEProfilerCompareMenu: View {
    let session: IDEProfilerSession
    @State private var candidates: [IDEProfilerSession.BaselineCandidate] = []

    var body: some View {
        @Bindable var session = session
        let open = candidates.filter { $0.profile != nil }
        let recent = candidates.filter { $0.profile == nil }
        IDEIconMenu(
            systemImage: "arrow.left.arrow.right",
            help: "Compare With Baseline",
            isActive: session.baselineTitle != nil,
            isDisabled: session.profile == nil || session.kind == .gc
        ) {
            if session.baselineTitle != nil {
                Button("Stop Comparing") { session.clearBaseline() }
                Picker("Compare", selection: $session.comparisonBasis) {
                    Text("By Share of Each Profile").tag(JavaProfileComparison.Basis.share)
                    Text("By Sample Count").tag(JavaProfileComparison.Basis.absolute)
                }
                .pickerStyle(.inline)
                Divider()
            }
            if !open.isEmpty {
                Section("Open Profiles") {
                    ForEach(open) { candidate in
                        Button(candidate.title) { session.setBaseline(candidate) }
                    }
                }
            }
            if !recent.isEmpty {
                Section("Recent Runs") {
                    ForEach(recent) { candidate in
                        Button("\(candidate.title) · \(candidate.subtitle)") { session.setBaseline(candidate) }
                    }
                }
            }
            Button("Choose Recording…") { session.chooseBaselineFile?() }
        }
        .onAppear { reload() }
        .onChange(of: session.phase) { reload() }
        .onChange(of: session.baselineTitle) { reload() }
    }

    private func reload() {
        candidates = session.baselineCandidates?() ?? []
    }
}

// MARK: - Comparison table

struct IDEComparisonRow: Identifiable {
    var id: JavaProfileSymbols.Method
    var name: String
    var package: String
    var baselineSelf: Double
    var targetSelf: Double
    var baselineTotal: Double
    var targetTotal: Double
    var selfChange: Double { targetSelf - baselineSelf }
    var totalChange: Double { targetTotal - baselineTotal }
}

/// Every method of either recording with its share of each, and the change in percentage points.
private struct IDEProfilerComparisonTable: View {
    let session: IDEProfilerSession
    let comparison: JavaProfileComparison
    @State private var sortOrder = [KeyPathComparator(\IDEComparisonRow.selfChange, order: .reverse)]

    var body: some View {
        let rows = makeRows().sorted(using: sortOrder)
        Table(rows, sortOrder: $sortOrder) {
            TableColumn("Method", value: \.name) { row in
                Text(row.name).font(IDEAppearance.Typography.body).lineLimit(1)
            }
            TableColumn("Package", value: \.package) { row in
                Text(row.package)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
            }
            TableColumn("Self before", value: \.baselineSelf) { share($0.baselineSelf) }.width(80)
            TableColumn("Self now", value: \.targetSelf) { share($0.targetSelf) }.width(72)
            TableColumn("Change", value: \.selfChange) { change($0.selfChange) }.width(72)
            TableColumn("Total before", value: \.baselineTotal) { share($0.baselineTotal) }.width(84)
            TableColumn("Total now", value: \.targetTotal) { share($0.targetTotal) }.width(76)
            TableColumn("Change ", value: \.totalChange) { change($0.totalChange) }.width(72)
        }
    }

    private func makeRows() -> [IDEComparisonRow] {
        let base = Double(max(comparison.baselineSamples, 1))
        let target = Double(max(comparison.targetSamples, 1))
        return comparison.rows.prefix(2_000).map { row in
            let className = row.method.className
            let simple = className.split(separator: ".").last.map(String.init) ?? className
            let package = className.lastIndex(of: ".").map { String(className[..<$0]) } ?? ""
            return IDEComparisonRow(
                id: row.method, name: (simple.isEmpty ? "" : simple + ".") + row.method.name, package: package,
                baselineSelf: Double(row.baselineSelf) * 100 / base, targetSelf: Double(row.targetSelf) * 100 / target,
                baselineTotal: Double(row.baselineTotal) * 100 / base, targetTotal: Double(row.targetTotal) * 100 / target
            )
        }
    }

    private func share(_ value: Double) -> some View {
        Text(String(format: "%.1f%%", value)).font(IDEAppearance.Typography.monoSmall)
    }

    private func change(_ value: Double) -> some View {
        Text(abs(value) < 0.05 ? "–" : String(format: "%+.1f", value))
            .font(IDEAppearance.Typography.monoSmall)
            .foregroundStyle(abs(value) < 0.05 ? IDEAppearance.ColorToken.muted : (value > 0 ? Color.red : Color.green))
    }
}

// MARK: - Call tree

/// Visible call-tree rows so arrow keys can walk the profiler like Coverage.
enum IDEProfilerCallTreeRows {
    static let childLimit = 200

    struct Row: Identifiable, Equatable {
        var id: Int { node }
        var node: Int
        var depth: Int
        var canDisclose: Bool
        var isExpanded: Bool
    }

    static func flatten(tree: JavaProfileTree, expanded: Set<Int>) -> [Row] {
        var rows: [Row] = []
        func visit(_ parent: Int, depth: Int) {
            for child in tree.children(of: parent).prefix(childLimit) {
                let canDisclose = tree.hasChildren(child)
                let isExpanded = canDisclose && expanded.contains(child)
                rows.append(Row(node: child, depth: depth, canDisclose: canDisclose, isExpanded: isExpanded))
                if isExpanded { visit(child, depth: depth + 1) }
            }
        }
        visit(JavaProfileTree.root, depth: 0)
        return rows
    }

    /// The hottest child of the root opens first, as the nested tree used to.
    static func hottestPath(in tree: JavaProfileTree) -> Set<Int> {
        guard let first = tree.children(of: JavaProfileTree.root).first else { return [] }
        return [first]
    }
}

private struct IDEProfilerCallTree: View {
    let session: IDEProfilerSession

    var body: some View {
        if let comparison = session.comparison {
            // The merged tree, with each node's share in the baseline and now, and the change.
            VStack(spacing: 0) {
                comparisonHeader
                Divider()
                IDEProfilerFlatTree(
                    session: session, tree: comparison.tree, symbols: comparison.symbols,
                    allowsTransforms: false, comparison: comparison,
                    resetID: "\(session.treeRevision)-\(session.comparisonBasis)"
                )
            }
        } else if let tree = session.tree, let symbols = session.symbols {
            IDEProfilerFlatTree(
                session: session, tree: tree, symbols: symbols, allowsTransforms: true,
                resetID: "\(session.treeRevision)"
            )
        }
    }

    /// Names the three number columns of a differential tree, in the order the rows have them.
    private var comparisonHeader: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Text("Method").font(IDEAppearance.Typography.caption)
            Spacer(minLength: 0)
            Text("Before").frame(width: IDEProfilerTreeNodeView.numberWidth, alignment: .trailing)
            Text("Now").frame(width: IDEProfilerTreeNodeView.numberWidth, alignment: .trailing)
            Text("Change").frame(width: IDEProfilerTreeNodeView.numberWidth, alignment: .trailing)
        }
        .font(IDEAppearance.Typography.caption)
        .foregroundStyle(IDEAppearance.ColorToken.muted)
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, 3)
    }
}

private struct IDEProfilerFlatTree: View {
    @Environment(IDEWorkspace.self) private var workspace
    let session: IDEProfilerSession
    let tree: JavaProfileTree
    let symbols: JavaProfileSymbols
    var allowsTransforms = true
    var comparison: JavaProfileComparison?
    let resetID: String
    @State private var expanded: Set<Int> = []
    @State private var selectedNode: Int?
    @State private var typeahead = IDETypeaheadBuffer()
    @FocusState private var isListFocused: Bool

    var body: some View {
        let rows = IDEProfilerCallTreeRows.flatten(tree: tree, expanded: expanded)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        IDEProfilerTreeNodeView(
                            session: session, tree: tree, symbols: symbols, row: row,
                            isSelected: isSelected(row),
                            allowsTransforms: allowsTransforms, comparison: comparison,
                            onSelect: { select(row) },
                            onActivate: { activate(row) }
                        )
                        .id(row.id)
                    }
                }
                .padding(.vertical, IDEAppearance.Spacing.xs)
            }
            .focusable()
            .focused($isListFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { press in
                handleKey(press, rows: rows)
            }
            .onChange(of: selectedNode) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            .onAppear { seedHottest() }
            .onChange(of: resetID) { _, _ in seedHottest(resetting: true) }
        }
    }

    private func seedHottest(resetting: Bool = false) {
        if resetting || expanded.isEmpty {
            expanded = IDEProfilerCallTreeRows.hottestPath(in: tree)
        }
        if resetting { selectedNode = nil }
    }

    private func isSelected(_ row: IDEProfilerCallTreeRows.Row) -> Bool {
        if selectedNode == row.node { return true }
        guard selectedNode == nil, comparison == nil else { return false }
        let frame = tree.frame(of: row.node)
        return frame >= 0 && session.selectedMethod == symbols.frame(frame).method
    }

    private func handleKey(_ press: KeyPress, rows: [IDEProfilerCallTreeRows.Row]) -> KeyPress.Result {
        let current = rows.first { $0.node == selectedNode }
        switch press.key {
        case .upArrow, .downArrow:
            typeahead.reset()
            let delta = press.key == .downArrow ? 1 : -1
            if let id = IDEListNeighbor.move(selectedNode, in: rows.map(\.node), by: delta),
               let row = rows.first(where: { $0.node == id }) {
                select(row)
            }
            return .handled
        case .rightArrow:
            typeahead.reset()
            guard let current, current.canDisclose, !current.isExpanded else { return .ignored }
            toggle(current)
            return .handled
        case .leftArrow:
            typeahead.reset()
            guard let current else { return .ignored }
            if current.canDisclose, current.isExpanded {
                toggle(current)
            } else if let index = rows.firstIndex(where: { $0.node == current.node }),
                      let parent = rows[..<index].last(where: { $0.depth < current.depth }) {
                select(parent)
            }
            return .handled
        case .return:
            typeahead.reset()
            guard let current else { return .ignored }
            activate(current)
            return .handled
        case .escape:
            typeahead.reset()
            workspace.focusActiveEditor()
            return .handled
        default:
            guard let character = IDEListTypeahead.character(from: press) else { return .ignored }
            if let row = IDEListTypeahead.match(
                query: typeahead.typed(character), in: rows, selected: current,
                title: { IDEFlameGraphNSView.label(frame: tree.frame(of: $0.node), symbols: symbols) }
            ) {
                select(row)
            }
            return .handled
        }
    }

    private func select(_ row: IDEProfilerCallTreeRows.Row) {
        selectedNode = row.node
        isListFocused = true
        let frame = tree.frame(of: row.node)
        if frame >= 0, comparison == nil { session.selectedMethod = symbols.frame(frame).method }
    }

    private func toggle(_ row: IDEProfilerCallTreeRows.Row) {
        guard row.canDisclose else { return }
        if expanded.contains(row.node) {
            expanded.remove(row.node)
        } else {
            expanded.insert(row.node)
        }
    }

    private func activate(_ row: IDEProfilerCallTreeRows.Row) {
        select(row)
        if row.canDisclose {
            toggle(row)
        } else {
            openSource(frame: tree.frame(of: row.node))
        }
    }

    private func openSource(frame: Int32) {
        guard frame >= 0 else { return }
        let method = symbols.method(ofFrame: frame)
        guard !method.className.isEmpty else { return }
        session.openFrame?(method.className, Int(symbols.frame(frame).line), symbols.sourcePath(ofFrame: frame))
    }
}

/// One visible call-tree row: indent, chevron, label and the share numbers.
private struct IDEProfilerTreeNodeView: View {
    let session: IDEProfilerSession
    let tree: JavaProfileTree
    let symbols: JavaProfileSymbols
    let row: IDEProfilerCallTreeRows.Row
    let isSelected: Bool
    /// Off for the detail pane's trees: their node numbers are not the shown tree's.
    var allowsTransforms = true
    /// Set for a differential tree: the numbers are shares before and now, and their change.
    var comparison: JavaProfileComparison?
    let onSelect: () -> Void
    let onActivate: () -> Void

    @State private var isHovering = false

    static let numberWidth: CGFloat = 52

    var body: some View {
        let frame = tree.frame(of: row.node)
        let total = tree.totalCount(of: row.node)
        let own = tree.selfCount(of: row.node)
        let denominator: Int? = {
            guard session.percentBase == .parent, let parent = tree.parent(of: row.node), parent != JavaProfileTree.root else { return nil }
            return tree.totalCount(of: parent)
        }()
        return HStack(spacing: IDEAppearance.Spacing.xs) {
            if row.canDisclose {
                IDEDisclosureChevron(isExpanded: row.isExpanded, size: 10, width: 12)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            } else {
                Spacer().frame(width: 12)
            }
            Text(IDEFlameGraphNSView.label(frame: frame, symbols: symbols))
                .font(IDEAppearance.Typography.body)
                .fontWeight(isSelected ? .semibold : .regular)
                .lineLimit(1)
            if frame >= 0, symbols.frame(frame).line > 0 {
                Text(":\(symbols.frame(frame).line)")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            Spacer(minLength: 0)
            if let comparison {
                comparisonNumbers(of: row.node, in: comparison)
            } else {
                Text(String(format: "%.1f%%", session.percent(total, of: denominator)))
                    .font(IDEAppearance.Typography.monoSmall)
                Text(String(format: "self %.1f%%", session.percent(own, of: denominator)))
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 14 + CGFloat(IDEAppearance.Spacing.sm))
        .padding(.trailing, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.tight)
        .background(isSelected ? IDEAppearance.ColorToken.selection : (isHovering ? IDEAppearance.ColorToken.controlHover : Color.clear))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2, perform: onActivate)
        .simultaneousGesture(TapGesture().onEnded(onSelect))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .contextMenu {
            if frame >= 0 {
                Button("Open Source") { openSource(frame: frame) }
                let className = symbols.method(ofFrame: frame).className
                if !className.isEmpty {
                    Divider()
                    IDEProfilerHideClassButtons(session: session, className: className)
                }
                if allowsTransforms {
                    Divider()
                    Button("Focus on Subtree") { session.focusOnSubtree(node: row.node) }
                    Button("Focus on Call") { session.focusOnCall(node: row.node) }
                    Button("Exclude Subtree") { session.excludeSubtree(node: row.node) }
                    Button("Exclude Call") { session.excludeCalls(node: row.node) }
                }
            }
        }
    }
}

extension IDEProfilerTreeNodeView {
    /// Before and now as a share of each recording's total (or of the parent's, when the tables
    /// are in percent of parent), and the difference in percentage points.
    @ViewBuilder
    fileprivate func comparisonNumbers(of node: Int, in comparison: JavaProfileComparison) -> some View {
        let parent = tree.parent(of: node)
        let useParent = session.percentBase == .parent && parent != nil && parent != JavaProfileTree.root
        let before = useParent
            ? Self.ratio(comparison.baselineShare(ofNode: node), to: comparison.baselineShare(ofNode: parent ?? 0))
            : comparison.baselineShare(ofNode: node)
        let now = useParent
            ? Self.ratio(comparison.targetShare(ofNode: node), to: comparison.targetShare(ofNode: parent ?? 0))
            : comparison.targetShare(ofNode: node)
        let change = (now - before) * 100
        Group {
            Text(String(format: "%.1f%%", before * 100))
            Text(String(format: "%.1f%%", now * 100))
            Text(abs(change) < 0.05 ? "–" : String(format: "%+.1f", change))
                .foregroundStyle(abs(change) < 0.05 ? IDEAppearance.ColorToken.muted : (change > 0 ? Color.red : Color.green))
        }
        .font(IDEAppearance.Typography.monoSmall)
        .frame(width: Self.numberWidth, alignment: .trailing)
    }

    fileprivate static func ratio(_ part: Double, to whole: Double) -> Double {
        whole > 0 ? part / whole : 0
    }

    fileprivate func openSource(frame: Int32) {
        guard frame >= 0 else { return }
        let method = symbols.method(ofFrame: frame)
        guard !method.className.isEmpty else { return }
        session.openFrame?(method.className, Int(symbols.frame(frame).line), symbols.sourcePath(ofFrame: frame))
    }
}

// MARK: - GC

private struct IDEProfilerGCTable: View {
    let pauses: [JavaGCPause]

    var body: some View {
        if pauses.isEmpty {
            Text("No garbage collections were recorded.")
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                summary
                Divider()
                Table(rows) {
                    TableColumn("#") { Text($0.id.formatted()).font(IDEAppearance.Typography.monoSmall) }.width(50)
                    TableColumn("Collector") { Text($0.pause.name).font(IDEAppearance.Typography.body) }
                    TableColumn("Cause") { Text($0.pause.cause).font(IDEAppearance.Typography.body) }
                    TableColumn("Pause") {
                        Text(String(format: "%.2f ms", Double($0.pause.nanoseconds) / 1_000_000))
                            .font(IDEAppearance.Typography.monoSmall)
                    }
                    .width(90)
                }
            }
        }
    }

    private struct Row: Identifiable {
        var id: Int
        var pause: JavaGCPause
    }

    private var rows: [Row] {
        pauses.enumerated().map { Row(id: $0.offset + 1, pause: $0.element) }
    }

    private var summary: some View {
        let total = pauses.reduce(0) { $0 + $1.nanoseconds }
        let longest = pauses.map(\.nanoseconds).max() ?? 0
        return HStack(spacing: IDEAppearance.Spacing.md) {
            Text("\(pauses.count.formatted()) collections")
            Text(String(format: "%.1f ms paused in total", Double(total) / 1_000_000))
            Text(String(format: "longest %.2f ms", Double(longest) / 1_000_000))
            Spacer(minLength: 0)
        }
        .font(IDEAppearance.Typography.caption)
        .foregroundStyle(IDEAppearance.ColorToken.muted)
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, 6)
    }
}
