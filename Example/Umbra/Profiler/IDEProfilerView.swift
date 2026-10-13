import JavaIntelligence
import SwiftUI

/// The profiler tab: a header (what to look at, search, view), and under it the flame graph, the hot
/// methods table or the call tree of the selected kind of event.
struct IDEProfilerView: View {
    let session: IDEProfilerSession

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
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

                if session.kind == .cpu, !session.threadNames.isEmpty {
                    Picker("Thread", selection: $session.thread) {
                        Text("All Threads").tag(String?.none)
                        ForEach(session.threadNames, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Copy Folded Stacks") { copyFolded() }
                    Button("Save Folded Stacks…") { saveFolded() }
                    Divider()
                    Button("Save a Copy of the Recording…") { saveRecording() }
                    Button("Reveal in Finder") {
                        if let url = session.primaryRecording { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    Button("Open as Hex") { session.openAsHex?() }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(session.profile == nil)
            }
            HStack(spacing: IDEAppearance.Spacing.sm) {
                if session.kind != .gc {
                    Picker("View", selection: $session.mode) {
                        ForEach(IDEProfilerSession.Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    TextField("Find method", text: $session.searchText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(maxWidth: 220)
                }
                if !session.zoomStack.isEmpty, session.mode == .flame, session.kind != .gc {
                    Button { session.zoomOut() } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                        .controlSize(.small)
                        .keyboardShortcut(.escape, modifiers: [])
                }
                Spacer(minLength: 0)
                Text(statusLine)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.xs)
    }

    private var statusLine: String {
        guard let profile = session.profile else { return session.summaryLine }
        var parts = [session.totalDescription]
        if profile.cpu.isTruncated || profile.allocation.isTruncated || profile.contention.isTruncated {
            parts.append("some stacks folded into (other)")
        }
        if profile.truncatedSamples > 0 { parts.append("\(profile.truncatedSamples.formatted()) samples truncated") }
        if profile.threadsOverLimit > 0 { parts.append("thread filter covers the busiest \(JavaProfile.maximumThreads)") }
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
        case .ready:
            ready
        }
    }

    @ViewBuilder
    private var ready: some View {
        if session.kind == .gc {
            IDEProfilerGCTable(pauses: session.profile?.gcPauses ?? [])
        } else if let tree = session.tree, tree.totalSamples > 0 {
            switch session.mode {
            case .flame:
                IDEFlameGraphView(session: session)
                    .overlay(alignment: .bottom) { selectionBar }
            case .hot:
                IDEProfilerHotMethods(session: session)
            case .tree:
                IDEProfilerCallTree(session: session)
            }
        } else {
            status(emptyMessage, progress: false, detail: nil)
        }
    }

    private var emptyMessage: String {
        switch session.kind {
        case .cpu: return "The recording has no CPU samples. A run shorter than the sample period (10 ms) leaves none."
        case .allocations: return "No allocation samples (Java 16 or newer records them)."
        case .locks: return "No lock contention was recorded above the threshold."
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

// MARK: - Hot methods

private struct IDEProfilerHotMethods: View {
    let session: IDEProfilerSession

    var body: some View {
        let symbols = session.symbols
        let rows = filtered(session.hotMethods, symbols: symbols)
        HStack(spacing: 0) {
            Table(rows, selection: Binding(
                get: { session.selectedMethod },
                set: { session.selectedMethod = $0 }
            )) {
                TableColumn("Method") { row in
                    Text(symbols?.displayName(ofMethod: row.method) ?? "")
                        .font(IDEAppearance.Typography.body)
                        .lineLimit(1)
                        .help(symbols?.qualifiedName(ofMethod: row.method) ?? "")
                }
                TableColumn("Package") { row in
                    Text(symbols?.packageName(ofMethod: row.method) ?? "")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .lineLimit(1)
                }
                TableColumn("Self") { row in
                    Text(String(format: "%.1f%%", session.percent(row.selfCount)))
                        .font(IDEAppearance.Typography.monoSmall)
                }
                .width(60)
                TableColumn("Total") { row in
                    Text(String(format: "%.1f%%", session.percent(row.totalCount)))
                        .font(IDEAppearance.Typography.monoSmall)
                }
                .width(60)
            }
            .contextMenu(forSelectionType: Int32.self) { ids in
                if let id = ids.first {
                    Button("Open Source") { session.openSource(ofMethod: id) }
                }
            } primaryAction: { ids in
                if let id = ids.first { session.openSource(ofMethod: id) }
            }
            if let method = session.selectedMethod, let tree = session.tree, let symbols {
                Divider()
                callers(of: method, tree: tree, symbols: symbols)
                    .frame(width: 260)
            }
        }
    }

    private func filtered(_ rows: [JavaProfileTree.HotMethod], symbols: JavaProfileSymbols?) -> [IDEHotRow] {
        let query = session.searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard let symbols else { return [] }
        return rows
            .filter { query.isEmpty || symbols.qualifiedName(ofMethod: $0.method).lowercased().contains(query) }
            .prefix(2_000)
            .map { IDEHotRow(method: $0.method, selfCount: $0.selfCount, totalCount: $0.totalCount) }
    }

    private func callers(of method: Int32, tree: JavaProfileTree, symbols: JavaProfileSymbols) -> some View {
        let callers = tree.callers(of: method, symbols: symbols).prefix(50)
        let callees = tree.callees(of: method, symbols: symbols).prefix(50)
        return List {
            Section("Called by") {
                ForEach(Array(callers), id: \.method) { neighbour in
                    neighbourRow(neighbour, symbols: symbols)
                }
            }
            Section("Calls") {
                ForEach(Array(callees), id: \.method) { neighbour in
                    neighbourRow(neighbour, symbols: symbols)
                }
            }
        }
        .listStyle(.plain)
    }

    private func neighbourRow(_ neighbour: JavaProfileTree.Neighbour, symbols: JavaProfileSymbols) -> some View {
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
        .onTapGesture { session.selectedMethod = neighbour.method }
    }
}

struct IDEHotRow: Identifiable {
    var id: Int32 { method }
    var method: Int32
    var selfCount: Int
    var totalCount: Int
}

// MARK: - Call tree

private struct IDEProfilerCallTree: View {
    let session: IDEProfilerSession

    var body: some View {
        if let tree = session.tree, let symbols = session.symbols {
            List {
                ForEach(IDEProfilerTreeRow.rows(of: JavaProfileTree.root, in: tree)) { row in
                    IDEProfilerTreeNodeView(session: session, tree: tree, symbols: symbols, row: row, expandHottest: true)
                }
            }
            .listStyle(.plain)
        }
    }
}

struct IDEProfilerTreeRow: Identifiable {
    var id: Int { node }
    var node: Int

    static func rows(of parent: Int, in tree: JavaProfileTree) -> [IDEProfilerTreeRow] {
        tree.children(of: parent).prefix(200).map { IDEProfilerTreeRow(node: $0) }
    }
}

/// One node of the call tree, expanded lazily: its children are only listed when it is open, and the
/// hottest child of an expanded node opens first.
private struct IDEProfilerTreeNodeView: View {
    let session: IDEProfilerSession
    let tree: JavaProfileTree
    let symbols: JavaProfileSymbols
    let row: IDEProfilerTreeRow
    var expandHottest = false
    @State private var isExpanded = false

    var body: some View {
        let hasChildren = tree.hasChildren(row.node)
        if hasChildren {
            DisclosureGroup(isExpanded: $isExpanded) {
                if isExpanded {
                    ForEach(IDEProfilerTreeRow.rows(of: row.node, in: tree)) { child in
                        IDEProfilerTreeNodeView(session: session, tree: tree, symbols: symbols, row: child)
                    }
                }
            } label: {
                label
            }
            .onAppear {
                // The hottest path opens on its own at the top, like a profiler's "hot path".
                if expandHottest, !isExpanded, tree.children(of: JavaProfileTree.root).first == row.node { isExpanded = true }
            }
        } else {
            label
        }
    }

    private var label: some View {
        let frame = tree.frame(of: row.node)
        let total = tree.totalCount(of: row.node)
        let own = tree.selfCount(of: row.node)
        return HStack(spacing: IDEAppearance.Spacing.xs) {
            Text(IDEFlameGraphNSView.label(frame: frame, symbols: symbols))
                .font(IDEAppearance.Typography.body)
                .lineLimit(1)
            if frame >= 0, symbols.frame(frame).line > 0 {
                Text(":\(symbols.frame(frame).line)")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            Spacer(minLength: 0)
            Text(String(format: "%.1f%%", session.percent(total)))
                .font(IDEAppearance.Typography.monoSmall)
            Text(String(format: "self %.1f%%", session.percent(own)))
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if frame >= 0 { session.openSource(ofMethod: symbols.frame(frame).method, line: Int(symbols.frame(frame).line)) }
        }
        .onTapGesture {
            if frame >= 0 { session.selectedMethod = symbols.frame(frame).method }
        }
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
