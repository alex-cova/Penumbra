import AppKit
import GitIntelligence
import SwiftUI

struct IDESourceControlPanel: View {
    @Environment(IDEWorkspace.self) private var workspace
    @Bindable private var gitStatus: IDEGitStatusModel
    @State private var mode = Mode.changes

    private enum Mode: String, CaseIterable, Identifiable {
        case changes = "Changes"
        case history = "History"

        var id: String { rawValue }
    }

    init(gitStatus: IDEGitStatusModel) {
        self._gitStatus = Bindable(wrappedValue: gitStatus)
    }

    private var stagedChanges: [IDEGitChange] {
        gitStatus.changes.filter { $0.staged != nil }
    }

    private var unstagedChanges: [IDEGitChange] {
        gitStatus.changes.filter { $0.unstaged != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 180)
            .padding(.horizontal, IDEAppearance.Spacing.md)
            .padding(.top, IDEAppearance.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)

            switch mode {
            case .changes: changesContent
            case .history: historyContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(IDEAppearance.ColorToken.editor)
        .clipped()
        .onAppear { gitStatus.loadHistory() }
    }

    private var changesContent: some View {
        VStack(spacing: 0) {
            commitBar
            if !gitStatus.actionStatus.isEmpty {
                Text(gitStatus.actionStatus)
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, IDEAppearance.Spacing.md)
                    .padding(.bottom, IDEAppearance.Spacing.xs)
            }
            splitContent(
                list: changeList,
                text: gitStatus.diffText ?? "Select a changed file to preview its diff."
            )
        }
    }

    private var historyContent: some View {
        VStack(spacing: 0) {
            historyFilters
            splitContent(
                list: historyList,
                text: gitStatus.commitDetailText ?? "Select a commit to see its changes.",
                listWidth: 380
            )
        }
    }

    private var historyFilters: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Menu {
                Button("All Branches") { gitStatus.historyBranch = nil; gitStatus.loadHistory() }
                Divider()
                ForEach(gitStatus.branches, id: \.self) { branch in
                    Button(branch) { gitStatus.historyBranch = branch; gitStatus.loadHistory() }
                }
            } label: {
                Label(gitStatus.historyBranch ?? "All Branches", systemImage: "arrow.triangle.branch")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Menu {
                Button("All Authors") { gitStatus.historyAuthor = nil; gitStatus.loadHistory() }
                Divider()
                ForEach(gitStatus.authors, id: \.self) { author in
                    Button(author) { gitStatus.historyAuthor = author; gitStatus.loadHistory() }
                }
            } label: {
                Label(gitStatus.historyAuthor ?? "All Authors", systemImage: "person")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            HStack(spacing: IDEAppearance.Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                TextField("Search commit messages", text: $gitStatus.historySearch)
                    .textFieldStyle(.plain)
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                if !gitStatus.historySearch.isEmpty {
                    Button { gitStatus.historySearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
            }
            .padding(.horizontal, IDEAppearance.Spacing.sm)
            .padding(.vertical, IDEAppearance.Spacing.xs)
            .background(IDEAppearance.ColorToken.tabActive)
            .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
            .frame(maxWidth: 260)
            .onChange(of: gitStatus.historySearch) { gitStatus.loadHistory(debounced: true) }

            Spacer(minLength: 0)
        }
        .font(IDEAppearance.Typography.caption)
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .padding(.vertical, IDEAppearance.Spacing.xs)
    }

    /// Fixed-width list beside the detail view. Deliberately not `HSplitView`: its AppKit-backed
    /// split view reports a minimum size that pushed the whole window layout when hosted in the
    /// bottom panel.
    private func splitContent(list: some View, text: String, listWidth: CGFloat = 280) -> some View {
        HStack(spacing: 0) {
            list
                .frame(width: listWidth)
                .frame(maxHeight: .infinity)
            Rectangle()
                .fill(IDEAppearance.ColorToken.border)
                .frame(width: 1)
            IDESourceControlDiffView(
                text: text,
                fontName: workspace.preferences.fontName,
                fontSize: workspace.preferences.fontSize
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var historyList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if gitStatus.commits.isEmpty {
                    Text("No commits")
                        .font(IDEAppearance.Typography.body)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .padding(.horizontal, IDEAppearance.Spacing.md)
                        .padding(.top, IDEAppearance.Spacing.sm)
                }
                ForEach(gitStatus.commits) { commit in
                    IDESourceControlCommitRow(
                        commit: commit,
                        isSelected: gitStatus.selectedCommitHash == commit.hash,
                        onSelect: { gitStatus.selectCommit(commit.hash) }
                    )
                }
            }
            .padding(.vertical, IDEAppearance.Spacing.xs)
        }
    }

    private var commitBar: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            TextField("Commit message", text: $gitStatus.commitMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1...3)
                .padding(.horizontal, IDEAppearance.Spacing.sm)
                .padding(.vertical, IDEAppearance.Spacing.xs)
                .background(IDEAppearance.ColorToken.tabActive)
                .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
                .onSubmit { gitStatus.commit() }

            Button("Commit") {
                gitStatus.commit()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(
                gitStatus.isBusy
                    || gitStatus.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || stagedChanges.isEmpty
            )
        }
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .padding(.vertical, IDEAppearance.Spacing.sm)
    }

    private var changeList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
                if stagedChanges.isEmpty && unstagedChanges.isEmpty {
                    Text("No changes")
                        .font(IDEAppearance.Typography.body)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .padding(.horizontal, IDEAppearance.Spacing.md)
                        .padding(.top, IDEAppearance.Spacing.sm)
                } else {
                    if !stagedChanges.isEmpty {
                        sectionHeader("Staged Changes", count: stagedChanges.count)
                        ForEach(stagedChanges) { change in
                            IDESourceControlChangeRow(
                                change: change,
                                isSelected: gitStatus.selectedChangePath == change.path,
                                showsStage: false,
                                onSelect: { gitStatus.selectChange(change.path) },
                                onOpen: { Task { await workspace.openDocument(from: URL(fileURLWithPath: change.path)) } },
                                onStage: {},
                                onUnstage: { gitStatus.unstage(path: change.path) }
                            )
                        }
                    }
                    if !unstagedChanges.isEmpty {
                        sectionHeader("Changes", count: unstagedChanges.count)
                        ForEach(unstagedChanges) { change in
                            IDESourceControlChangeRow(
                                change: change,
                                isSelected: gitStatus.selectedChangePath == change.path,
                                showsStage: true,
                                onSelect: { gitStatus.selectChange(change.path) },
                                onOpen: { Task { await workspace.openDocument(from: URL(fileURLWithPath: change.path)) } },
                                onStage: { gitStatus.stage(path: change.path) },
                                onUnstage: {}
                            )
                        }
                    }
                }
            }
            .padding(.vertical, IDEAppearance.Spacing.sm)
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        Text("\(title) (\(count))")
            .font(IDEAppearance.Typography.sectionHeader)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .padding(.horizontal, IDEAppearance.Spacing.md)
            .padding(.top, IDEAppearance.Spacing.xs)
    }
}

private enum IDEGitGraphMetrics {
    static let laneWidth: CGFloat = 12
    static let rowHeight: CGFloat = 38
    static let palette: [Color] = [
        Color(red: 0.25, green: 0.72, blue: 0.55), Color(red: 0.85, green: 0.65, blue: 0.2),
        Color(red: 0.4, green: 0.6, blue: 0.95), Color(red: 0.85, green: 0.4, blue: 0.5),
        Color(red: 0.65, green: 0.5, blue: 0.9), Color(red: 0.3, green: 0.75, blue: 0.85),
    ]

    static func color(_ lane: Int) -> Color { palette[lane % palette.count] }
}

private struct IDEGitGraphView: View {
    let row: GitGraphRow

    private let metrics = IDEGitGraphMetrics.self

    var body: some View {
        let lanes = min(row.laneCount, 8)
        Canvas { context, size in
            func x(_ lane: Int) -> CGFloat { (CGFloat(min(lane, 7)) + 0.5) * metrics.laneWidth }
            func y(_ anchor: GitGraphAnchor) -> CGFloat {
                switch anchor {
                case .top: return 0
                case .center: return size.height / 2
                case .bottom: return size.height
                }
            }
            for segment in row.segments {
                var path = Path()
                let start = CGPoint(x: x(segment.fromLane), y: y(segment.fromAnchor))
                let end = CGPoint(x: x(segment.toLane), y: y(segment.toAnchor))
                path.move(to: start)
                if segment.fromLane == segment.toLane {
                    path.addLine(to: end)
                } else {
                    let midY = (start.y + end.y) / 2
                    path.addCurve(
                        to: end,
                        control1: CGPoint(x: start.x, y: midY),
                        control2: CGPoint(x: end.x, y: midY)
                    )
                }
                context.stroke(path, with: .color(metrics.color(segment.colorIndex)), lineWidth: 1.5)
            }
            let mid = size.height / 2
            let dot = CGRect(x: x(row.nodeLane) - 4, y: mid - 4, width: 8, height: 8)
            context.fill(Path(ellipseIn: dot), with: .color(metrics.color(row.colorIndex)))
        }
        .frame(width: CGFloat(max(lanes, 1)) * metrics.laneWidth, height: metrics.rowHeight)
    }
}

private struct IDESourceControlCommitRow: View {
    let commit: IDEGitCommit
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            if let graph = commit.graph {
                IDEGitGraphView(row: graph)
            }
            VStack(alignment: .leading, spacing: 2) {
                (Text(refsPrefix).foregroundStyle(IDEAppearance.ColorToken.gitAdded)
                    + Text(commit.subject).foregroundStyle(IDEAppearance.ColorToken.foreground))
                    .font(IDEAppearance.Typography.tabLabel)
                    .lineLimit(1)
                Text("\(commit.shortHash)  \(commit.author) · \(commit.relativeDate)")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: IDEGitGraphMetrics.rowHeight)
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .background(isSelected ? IDEAppearance.ColorToken.selection : (isHovering ? IDEAppearance.ColorToken.controlHover : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }

    private var refsPrefix: String {
        commit.refs.isEmpty ? "" : "[\(commit.refs)] "
    }
}

private struct IDESourceControlChangeRow: View {
    let change: IDEGitChange
    let isSelected: Bool
    let showsStage: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onStage: () -> Void
    let onUnstage: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Button(action: showsStage ? onStage : onUnstage) {
                Image(systemName: showsStage ? "plus.circle" : "minus.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(width: IDEAppearance.Spacing.iconButton, height: IDEAppearance.Spacing.iconButton)
            }
            .buttonStyle(.plain)
            .help(showsStage ? "Stage File" : "Unstage File")

            Image(systemName: IDEFileIcon.systemName(forFilename: change.relativePath))
                .font(.system(size: 11))
                .foregroundStyle(statusColor)
                .frame(width: 14)

            Text(change.relativePath)
                .font(IDEAppearance.Typography.tabLabel)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            Text(statusLabel)
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, 3)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onTapGesture(count: 2, perform: onOpen)
        .onHover { isHovering = $0 }
        .padding(.horizontal, IDEAppearance.Spacing.xs)
    }

    private var rowBackground: Color {
        if isSelected {
            return IDEAppearance.ColorToken.selection
        }
        if isHovering {
            return IDEAppearance.ColorToken.controlHover
        }
        return .clear
    }

    private var displayedStatus: IDEGitFileStatus? {
        showsStage ? change.unstaged : change.staged
    }

    private var statusColor: Color {
        switch displayedStatus {
        case .modified: IDEAppearance.ColorToken.gitModified
        case .added, .untracked: IDEAppearance.ColorToken.gitAdded
        case .conflicted: IDEAppearance.ColorToken.gitConflict
        case .ignored: IDEAppearance.ColorToken.gitIgnored
        case .none: IDEAppearance.ColorToken.muted
        }
    }

    private var statusLabel: String {
        switch displayedStatus {
        case .modified: "M"
        case .added: "A"
        case .untracked: "?"
        case .conflicted: "U"
        case .ignored: "!"
        case .none: ""
        }
    }
}

struct IDESourceControlDiffView: NSViewRepresentable {
    let text: String
    let fontName: String
    let fontSize: Double

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = IDEAppearance.NSToken.editor

        let textView = IDEDiffTextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = IDEAppearance.NSToken.editor
        textView.textColor = IDEAppearance.NSToken.foreground
        textView.insertionPointColor = IDEAppearance.NSToken.foreground
        textView.font = IDEEditorFonts.nsFont(familyName: fontName, size: CGFloat(fontSize))
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.render(text, fontName: fontName, fontSize: fontSize)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.render(text, fontName: fontName, fontSize: fontSize)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        weak var textView: IDEDiffTextView?
        private var renderedText = ""
        private var renderedFontName = ""
        private var renderedFontSize = 0.0

        func render(_ text: String, fontName: String, fontSize: Double) {
            guard let textView else { return }
            let font = IDEEditorFonts.nsFont(familyName: fontName, size: CGFloat(fontSize))
            if renderedText != text || renderedFontName != fontName || renderedFontSize != fontSize {
                let (attributed, bands) = Self.style(text, font: font)
                textView.lineBands = bands
                textView.textStorage?.setAttributedString(attributed)
                textView.needsDisplay = true
                renderedText = text
                renderedFontName = fontName
                renderedFontSize = fontSize
            }
        }

        /// Colours a unified diff: foreground per line kind, plus full-width background bands for
        /// added/removed lines. Hunk state matters so `--- a/file` is not mistaken for a removal.
        private static func style(_ text: String, font: NSFont) -> (NSAttributedString, [IDEDiffTextView.Band]) {
            let result = NSMutableAttributedString()
            var bands: [IDEDiffTextView.Band] = []
            let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            let base = IDEAppearance.NSToken.foreground
            let muted = NSColor.secondaryLabelColor
            var inHunk = false
            var location = 0

            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let string = String(line) + "\n"
                var color = base
                var lineFont = font
                var band: NSColor?
                if line.hasPrefix("diff --git") {
                    inHunk = false
                    color = base
                    lineFont = bold
                    band = NSColor.white.withAlphaComponent(0.06)
                } else if line.hasPrefix("--- ") && line.hasSuffix(" ---") {
                    inHunk = false
                    color = NSColor.systemYellow
                    lineFont = bold
                } else if line.hasPrefix("@@") {
                    inHunk = true
                    color = NSColor.systemCyan
                    band = NSColor.systemCyan.withAlphaComponent(0.08)
                } else if inHunk, line.hasPrefix("+") {
                    color = NSColor.systemGreen
                    band = NSColor.systemGreen.withAlphaComponent(0.14)
                } else if inHunk, line.hasPrefix("-") {
                    color = NSColor.systemRed
                    band = NSColor.systemRed.withAlphaComponent(0.14)
                } else if !inHunk {
                    if line.hasPrefix("commit ") {
                        color = NSColor.systemYellow
                        lineFont = bold
                    } else if line.hasPrefix("index ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
                        || line.hasPrefix("new file") || line.hasPrefix("deleted file")
                        || line.hasPrefix("Author:") || line.hasPrefix("Date:") || line.hasPrefix("similarity")
                        || line.hasPrefix("rename ") {
                        color = muted
                    }
                }
                let length = (string as NSString).length
                result.append(NSAttributedString(string: string, attributes: [.font: lineFont, .foregroundColor: color]))
                if let band { bands.append(.init(range: NSRange(location: location, length: length - 1), color: band)) }
                location += length
            }
            return (result, bands)
        }
    }
}

/// Read-only text view that paints a full-width background behind flagged lines.
final class IDEDiffTextView: NSTextView {
    struct Band {
        let range: NSRange
        let color: NSColor
    }

    var lineBands: [Band] = []

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        for band in lineBands {
            let glyphs = layoutManager.glyphRange(forCharacterRange: band.range, actualCharacterRange: nil)
            band.color.setFill()
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, _, _ in
                let fill = NSRect(x: 0, y: lineRect.minY + origin.y, width: max(self.bounds.width, lineRect.maxX), height: lineRect.height)
                if fill.intersects(rect) { fill.fill() }
            }
        }
        _ = textContainer
    }
}

struct IDESourceControlControls: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Button("Stage All") {
                workspace.gitStatus.stageAll()
            }
            .buttonStyle(.borderless)
            .font(IDEAppearance.Typography.caption)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .disabled(workspace.gitStatus.isBusy)

            Button("Unstage All") {
                workspace.gitStatus.unstageAll()
            }
            .buttonStyle(.borderless)
            .font(IDEAppearance.Typography.caption)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .disabled(workspace.gitStatus.isBusy)

            Button(action: { workspace.gitStatus.refresh() }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .help("Refresh")
            .accessibilityLabel("Refresh Source Control")
            .disabled(workspace.gitStatus.isBusy)
        }
    }
}

#Preview {
    IDESourceControlPanel(gitStatus: {
        let model = IDEGitStatusModel()
        return model
    }())
    .environment(IDEWorkspace())
    .frame(width: 720, height: 320)
    .preferredColorScheme(.dark)
}
