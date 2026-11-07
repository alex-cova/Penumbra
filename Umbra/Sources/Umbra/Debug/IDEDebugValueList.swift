import SwiftUI

/// Visible debugger values so arrow keys can walk a value tree like Coverage. Children stay lazy:
/// expanding a row is what asks the adapter for the next level.
enum IDEDebugValueTree {
    struct Group: Equatable {
        var idPrefix = ""
        var isWatch = false
        var roots: [JavaDebugValue]
    }

    struct Row: Identifiable, Equatable {
        var id: String
        var value: JavaDebugValue
        var depth: Int
        var canDisclose: Bool
        var isExpanded: Bool
        var isLoading: Bool
        var loadError: String?
        /// A watch expression at depth 0, so the row can be edited or removed.
        var isWatch: Bool
        var title: String { value.name ?? value.expression }
    }

    static func flatten(
        roots: [JavaDebugValue],
        expanded: Set<String>,
        loaded: [String: [JavaDebugValue]],
        loading: Set<String>,
        errors: [String: String]
    ) -> [Row] {
        flatten(groups: [Group(roots: roots)], expanded: expanded, loaded: loaded, loading: loading, errors: errors)
    }

    static func flatten(
        groups: [Group],
        expanded: Set<String>,
        loaded: [String: [JavaDebugValue]],
        loading: Set<String>,
        errors: [String: String]
    ) -> [Row] {
        var rows: [Row] = []
        func visit(_ value: JavaDebugValue, depth: Int, prefix: String, isWatchGroup: Bool) {
            let id = prefix + value.id
            let canDisclose = value.hasChildren
            let isExpanded = canDisclose && expanded.contains(id)
            rows.append(Row(
                id: id, value: value, depth: depth, canDisclose: canDisclose, isExpanded: isExpanded,
                isLoading: loading.contains(id), loadError: errors[id],
                isWatch: isWatchGroup && depth == 0
            ))
            guard isExpanded else { return }
            for child in loaded[id] ?? value.children ?? [] {
                visit(child, depth: depth + 1, prefix: prefix, isWatchGroup: isWatchGroup)
            }
        }
        for group in groups {
            for root in group.roots {
                visit(root, depth: 0, prefix: group.idPrefix, isWatchGroup: group.isWatch)
            }
        }
        return rows
    }
}

/// A flattened, keyboard-first tree of debugger values. Evaluate, Memory, Variables and Quick
/// Evaluate all show one of these so expanding a node never traps arrow keys inside a disclosure.
struct IDEDebugValueList: View {
    @Environment(IDEWorkspace.self) private var workspace
    let session: JavaDebugSession
    let groups: [IDEDebugValueTree.Group]
    var resetID: String
    var emptyMessage: String
    var onAddWatch: ((String) -> Void)?
    var escapesToEditor = true
    var listFocus: FocusState<Bool>.Binding?

    @State private var expanded: Set<String> = []
    @State private var loaded: [String: [JavaDebugValue]] = [:]
    @State private var loading: Set<String> = []
    @State private var errors: [String: String] = [:]
    @State private var selectedID: String?
    @State private var typeahead = IDETypeaheadBuffer()
    @State private var editingWatch: String?
    @State private var watchDraft = ""
    @FocusState private var localFocus: Bool
    @State private var lastResetID = ""

    private var focus: FocusState<Bool>.Binding { listFocus ?? $localFocus }
    private var addWatch: (String) -> Void { onAddWatch ?? { workspace.addWatch($0) } }

    var body: some View {
        let rows = IDEDebugValueTree.flatten(
            groups: groups, expanded: expanded, loaded: loaded, loading: loading, errors: errors
        )
        return Group {
            if rows.isEmpty {
                Text(emptyMessage)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusable()
                    .focused(focus)
                    .focusEffectDisabled()
                    .onKeyPress(.escape) { handleEscape() }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows) { row in
                                rowView(row)
                                    .id(row.id)
                            }
                        }
                        .padding(.vertical, IDEAppearance.Spacing.xs)
                    }
                    .focusable()
                    .focused(focus)
                    .focusEffectDisabled()
                    .onKeyPress(phases: [.down, .repeat]) { press in
                        handleKey(press, rows: rows)
                    }
                    .onChange(of: selectedID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .onAppear { resetIfNeeded() }
        .onChange(of: resetID) { _, _ in resetIfNeeded(force: true) }
    }

    private func resetIfNeeded(force: Bool = false) {
        guard force || lastResetID != resetID else { return }
        lastResetID = resetID
        expanded = []
        loaded = [:]
        loading = []
        errors = [:]
        selectedID = nil
        editingWatch = nil
        typeahead.reset()
    }

    private func rowView(_ row: IDEDebugValueTree.Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: IDEAppearance.Spacing.xs) {
                if row.isWatch {
                    Image(systemName: "eyeglasses")
                        .font(.system(size: 10))
                        .foregroundStyle(IDEAppearance.ColorToken.accent)
                }
                if let editingWatch, row.isWatch, (row.value.name ?? row.value.expression) == editingWatch {
                    TextField("Watch", text: $watchDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(IDEAppearance.Typography.monoSmall)
                        .onSubmit {
                            workspace.replaceWatch(editingWatch, with: watchDraft)
                            self.editingWatch = nil
                        }
                        .onExitCommand { self.editingWatch = nil }
                } else {
                    IDEDebugValueRow(
                        session: session, value: row.value, onAddWatch: addWatch,
                        embedsChildren: false, isExpanded: row.isExpanded
                    )
                }
            }
            if let loadError = row.loadError {
                Text(loadError)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 26)
            } else if row.isLoading {
                ProgressView().controlSize(.small).padding(.leading, 26)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 14 + CGFloat(IDEAppearance.Spacing.sm))
        .padding(.trailing, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.tight)
        .background(selectedID == row.id ? IDEAppearance.ColorToken.selection : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { activate(row) }
        .simultaneousGesture(TapGesture().onEnded { select(row, toggling: row.canDisclose) })
        .contextMenu { watchMenu(row) }
    }

    @ViewBuilder
    private func watchMenu(_ row: IDEDebugValueTree.Row) -> some View {
        if row.isWatch, let expression = row.value.name ?? optionalExpression(row) {
            Button("Edit Watch") { beginWatchEdit(expression) }
            Button("Remove Watch") { workspace.removeWatch(expression) }
        }
    }

    private func optionalExpression(_ row: IDEDebugValueTree.Row) -> String? {
        row.value.expression.isEmpty ? nil : row.value.expression
    }

    private func handleKey(_ press: KeyPress, rows: [IDEDebugValueTree.Row]) -> KeyPress.Result {
        if editingWatch != nil { return .ignored }
        let current = rows.first { $0.id == selectedID }
        switch press.key {
        case .upArrow, .downArrow:
            typeahead.reset()
            let delta = press.key == .downArrow ? 1 : -1
            if let id = IDEListNeighbor.move(selectedID, in: rows.map(\.id), by: delta),
               let row = rows.first(where: { $0.id == id }) {
                select(row, toggling: false)
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
            } else if let index = rows.firstIndex(where: { $0.id == current.id }),
                      let parent = rows[..<index].last(where: { $0.depth < current.depth }) {
                select(parent, toggling: false)
            }
            return .handled
        case .return:
            typeahead.reset()
            guard let current else { return .ignored }
            activate(current)
            return .handled
        case .escape:
            typeahead.reset()
            return handleEscape()
        default:
            guard let character = IDEListTypeahead.character(from: press) else { return .ignored }
            if let row = IDEListTypeahead.match(
                query: typeahead.typed(character), in: rows, selected: current, title: \.title
            ) {
                select(row, toggling: false)
            }
            return .handled
        }
    }

    private func handleEscape() -> KeyPress.Result {
        if editingWatch != nil {
            editingWatch = nil
            return .handled
        }
        guard escapesToEditor else { return .ignored }
        workspace.focusActiveEditor()
        return .handled
    }

    private func select(_ row: IDEDebugValueTree.Row, toggling: Bool) {
        selectedID = row.id
        focus.wrappedValue = true
        if toggling { toggle(row) }
    }

    private func toggle(_ row: IDEDebugValueTree.Row) {
        guard row.canDisclose else { return }
        if expanded.contains(row.id) {
            expanded.remove(row.id)
        } else {
            expanded.insert(row.id)
            ensureLoaded(row)
        }
    }

    private func activate(_ row: IDEDebugValueTree.Row) {
        if row.isWatch, let expression = row.value.name ?? optionalExpression(row) {
            beginWatchEdit(expression)
            return
        }
        select(row, toggling: false)
        if row.canDisclose { toggle(row) }
    }

    private func beginWatchEdit(_ expression: String) {
        watchDraft = expression
        editingWatch = expression
        focus.wrappedValue = true
    }

    private func ensureLoaded(_ row: IDEDebugValueTree.Row) {
        guard row.value.hasChildren, row.value.children == nil, loaded[row.id] == nil, !loading.contains(row.id) else { return }
        loading.insert(row.id)
        let id = row.id
        let expression = row.value.expression
        Task {
            switch await session.evaluate(expression, record: false) {
            case .value(let node):
                loaded[id] = node.children ?? []
                errors[id] = nil
            case .failure(let message):
                errors[id] = message
            }
            loading.remove(id)
        }
    }
}
