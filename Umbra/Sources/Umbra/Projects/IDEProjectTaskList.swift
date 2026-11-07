import SwiftUI

/// Painted order of a SwiftPM or Xcode task sidebar: the tasks as the project system lists them.
enum IDEProjectTaskKeyboard {
    static func ids(_ tasks: [IDEProjectTask]) -> [String] {
        tasks.map(\.path)
    }
}

/// Arrow keys, type-ahead and Return through the runable rows of a SwiftPM or Xcode sidebar.
/// Targets and dependencies stay after the tasks and are not in the keyboard order.
struct IDEProjectTaskList<Header: View, Footer: View>: View {
    @Environment(IDEWorkspace.self) private var workspace
    let tasks: [IDEProjectTask]
    let isRunDisabled: Bool
    let onRun: (IDEProjectTask) -> Void
    var isListFocused: FocusState<Bool>.Binding
    @ViewBuilder var header: () -> Header
    @ViewBuilder var footer: () -> Footer

    @State private var selectedPath: String?
    @State private var typeahead = IDETypeaheadBuffer()

    private var keyboardIDs: [String] { IDEProjectTaskKeyboard.ids(tasks) }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header()
                    ForEach(tasks, id: \.path) { task in
                        IDEProjectTaskRow(
                            task: task,
                            isSelected: selectedPath == task.path,
                            isRunDisabled: isRunDisabled,
                            onSelect: { select(task.path) },
                            onRun: { run(task) }
                        )
                        .id(task.path)
                    }
                    footer()
                }
                .padding(.vertical, IDEAppearance.Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .focusable()
            .focusEffectDisabled()
            .focused(isListFocused)
            .onKeyPress(phases: [.down, .repeat]) { press in
                handleKey(press, scroller: scroller)
            }
            .onChange(of: keyboardIDs) { _, ids in
                if let selectedPath, !ids.contains(selectedPath) {
                    self.selectedPath = nil
                }
            }
        }
    }

    private func select(_ path: String) {
        selectedPath = path
        isListFocused.wrappedValue = true
    }

    private func run(_ task: IDEProjectTask) {
        select(task.path)
        guard !isRunDisabled else { return }
        onRun(task)
    }

    private func task(at path: String) -> IDEProjectTask? {
        tasks.first { $0.path == path }
    }

    private func moveSelection(by delta: Int, scroller: ScrollViewProxy) {
        guard let path = IDEListNeighbor.move(selectedPath, in: keyboardIDs, by: delta) else { return }
        selectedPath = path
        isListFocused.wrappedValue = true
        scroller.scrollTo(path)
    }

    private func handleKey(_ press: KeyPress, scroller: ScrollViewProxy) -> KeyPress.Result {
        switch press.key {
        case .upArrow:
            typeahead.reset()
            moveSelection(by: -1, scroller: scroller)
            return .handled
        case .downArrow:
            typeahead.reset()
            moveSelection(by: 1, scroller: scroller)
            return .handled
        case .return:
            typeahead.reset()
            guard let selectedPath, let task = task(at: selectedPath), !isRunDisabled else { return .ignored }
            run(task)
            return .handled
        case .escape:
            typeahead.reset()
            workspace.focusActiveEditor()
            return .handled
        default:
            return typeaheadSelect(press, scroller: scroller)
        }
    }

    private func typeaheadSelect(_ press: KeyPress, scroller: ScrollViewProxy) -> KeyPress.Result {
        guard let character = IDEListTypeahead.character(from: press) else { return .ignored }
        if let path = IDEListTypeahead.match(
            query: typeahead.typed(character),
            in: keyboardIDs,
            selected: selectedPath,
            title: { path in task(at: path)?.name ?? "" }
        ) {
            selectedPath = path
            isListFocused.wrappedValue = true
            scroller.scrollTo(path)
        }
        return .handled
    }
}

private struct IDEProjectTaskRow: View {
    let task: IDEProjectTask
    let isSelected: Bool
    let isRunDisabled: Bool
    let onSelect: () -> Void
    let onRun: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Button(action: onRun) {
                Image(systemName: "play.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(width: 12, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(isRunDisabled)
            .focusable(false)
            .help(task.summary)
            .accessibilityLabel("Run \(task.name)")
            Text(task.name)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2, perform: onRun)
        .simultaneousGesture(TapGesture().onEnded(onSelect))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(task.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var background: Color {
        if isSelected { return IDEAppearance.ColorToken.selection }
        return isHovering ? IDEAppearance.ColorToken.controlHover : Color.clear
    }
}
