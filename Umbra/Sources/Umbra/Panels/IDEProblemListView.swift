import EditorIntelligence
import JavaIntelligence
import SwiftIntelligence
import SwiftUI

/// The Problems tab's diagnostic list: build messages first, then the rows of expanded files.
struct IDEProblemListView: View {
    @Environment(IDEWorkspace.self) private var workspace
    @Binding var selectedRowID: String?
    @Binding var collapsedFiles: Set<URL>
    @Binding var typeahead: IDETypeaheadBuffer
    var isListFocused: FocusState<Bool>.Binding

    var body: some View {
        let (files, messages) = workspace.visibleProblems()
        let flatIDs = flatRowIDs(files: files, messages: messages)
        return Group {
            if files.isEmpty && messages.isEmpty {
                IDEProblemsEmptyState(
                    status: workspace.problems.resolutionSummary,
                    isEmpty: workspace.problems.isEmpty,
                    onAction: performResolutionAction
                )
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if workspace.problems.resolutionSummary != .complete {
                            IDEResolutionNote(status: workspace.problems.resolutionSummary, onAction: performResolutionAction)
                        }
                        ForEach(messages) { message in
                            IDEBuildMessageRowView(message: message, isSelected: selectedRowID == "message:\(message.id)") {
                                selectedRowID = "message:\(message.id)"
                                isListFocused.wrappedValue = true
                                workspace.openBuildMessage(message)
                            }
                            .id("message:\(message.id)")
                        }
                        ForEach(files) { file in
                            let isCollapsed = collapsedFiles.contains(file.url)
                            IDEProblemFileHeader(
                                file: file,
                                isCollapsed: isCollapsed,
                                directory: workspace.displayDirectory(of: file.url)
                            ) {
                                if isCollapsed { collapsedFiles.remove(file.url) } else { collapsedFiles.insert(file.url) }
                            }
                            if !collapsedFiles.contains(file.url) {
                                ForEach(file.rows) { row in
                                    IDEProblemRowView(
                                        row: row,
                                        isSelected: selectedRowID == row.id,
                                        onOpen: {
                                            selectedRowID = row.id
                                            isListFocused.wrappedValue = true
                                            workspace.openProblem(row)
                                        },
                                        onFix: { workspace.fixProblemWithAgent(row) },
                                        onQuickFixes: [IDEProblemsStore.inspectionSource, SwiftInspection.diagnosticSource].contains(row.diagnostic.source) ? { showQuickFixes(for: row) } : nil,
                                        rule: inspectionRule(for: row),
                                        onDisableRule: { workspace.disableInspection(code: $0.code, language: $0.language) },
                                        onQuietRule: { info in
                                            if let rule = JavaInspectionRule(code: info.code) {
                                                workspace.inspections.edit { $0.setSeverity(.noHighlighting, for: rule) }
                                            }
                                        },
                                        onConfigureRule: { workspace.showInspectionSettings(code: $0.code, language: $0.language) }
                                    )
                                    .id(row.id)
                                }
                            }
                        }
                    }
                    .padding(.vertical, IDEAppearance.Spacing.xs)
                }
                .focusable()
                .focused(isListFocused)
                .onKeyPress(phases: [.down, .repeat]) { press in
                    handleListKey(press, flatIDs: flatIDs, files: files, messages: messages, proxy: proxy)
                }
                .onChange(of: selectedRowID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Flat keyboard order: build messages first, then rows of expanded files.
    private func flatRowIDs(files: [ProblemFile], messages: [GradleProblem]) -> [String] {
        messages.map { "message:\($0.id)" }
            + files.flatMap { file in collapsedFiles.contains(file.url) ? [] : file.rows.map(\.id) }
    }

    private func handleListKey(
        _ press: KeyPress, flatIDs: [String], files: [ProblemFile], messages: [GradleProblem], proxy: ScrollViewProxy
    ) -> KeyPress.Result {
        switch press.key {
        case .upArrow, .downArrow:
            typeahead.reset()
            guard !flatIDs.isEmpty else { return .handled }
            let current = selectedRowID.flatMap { flatIDs.firstIndex(of: $0) }
            let next = press.key == .downArrow
                ? min((current ?? -1) + 1, flatIDs.count - 1)
                : max((current ?? flatIDs.count) - 1, 0)
            selectedRowID = flatIDs[next]
            return .handled
        case .return:
            typeahead.reset()
            guard let selectedRowID else { return .handled }
            if selectedRowID.hasPrefix("message:") {
                let raw = String(selectedRowID.dropFirst("message:".count))
                if let message = messages.first(where: { "\($0.id)" == raw }) { workspace.openBuildMessage(message) }
            } else if let row = files.flatMap(\.rows).first(where: { $0.id == selectedRowID }) {
                workspace.openProblem(row)
            }
            return .handled
        case .escape:
            typeahead.reset()
            workspace.focusActiveEditor()
            return .handled
        default:
            guard let character = IDEListTypeahead.character(from: press) else { return .ignored }
            if let id = IDEListTypeahead.match(
                query: typeahead.typed(character),
                in: flatIDs,
                selected: selectedRowID,
                title: { typeaheadTitle(for: $0, files: files, messages: messages) }
            ) {
                selectedRowID = id
            }
            return .handled
        }
    }

    private func typeaheadTitle(for id: String, files: [ProblemFile], messages: [GradleProblem]) -> String {
        if id.hasPrefix("message:") {
            let raw = String(id.dropFirst("message:".count))
            return messages.first { "\($0.id)" == raw }?.message ?? ""
        }
        guard let row = files.flatMap(\.rows).first(where: { $0.id == id }) else { return "" }
        return "\(row.url.lastPathComponent) \(row.diagnostic.message)"
    }

    /// The inspection behind a row, nil for compiler, editor and tool diagnostics.
    private func inspectionRule(for row: ProblemRow) -> IDEInspectionRuleInfo? {
        guard let code = row.diagnostic.code else { return nil }
        switch row.diagnostic.source {
        case IDEProblemsStore.inspectionSource: return IDEInspectionLanguage.java.rule(code: code)
        case SwiftInspection.diagnosticSource: return IDEInspectionLanguage.swift.rule(code: code)
        default: return nil
        }
    }

    private func showQuickFixes(for row: ProblemRow) {
        Task {
            let actions = await workspace.quickFixes(for: row)
            workspace.popUpQuickFixMenu(actions) { action in
                Task { await workspace.applyQuickFix(action, to: row.url) }
            }
        }
    }

    private func performResolutionAction(_ action: IDEResolutionStatus.Action) {
        switch action {
        case .syncProject: workspace.javaSupport.buildSystem?.reload()
        case .chooseJDK:
            workspace.requestedSettingsDomain = .java
            workspace.showSettings()
        }
    }
}
