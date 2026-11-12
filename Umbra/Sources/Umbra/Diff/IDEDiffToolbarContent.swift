import SwiftUI

/// The diff toolbar's controls: change and file navigation, Jump to Source, the layout,
/// whitespace and highlighting options, collapsing, synchronized scrolling, and the count.
/// Extracted from `IDEDiffToolbar` so the toolbar stays a composition of subviews.
struct IDEDiffToolbarContent: View {
    @Bindable var model: IDEDiffToolbarModel
    @Bindable var session: IDEDiffSession

    var body: some View {
        let _ = model.revision
        IDEIconButton(systemImage: "arrow.up", help: "Previous Difference (⇧F7)", action: goToPreviousChange)
            .disabled(session.chunks.isEmpty)
        IDEIconButton(systemImage: "arrow.down", help: "Next Difference (F7)", action: goToNextChange)
            .disabled(session.chunks.isEmpty && !session.canMoveToFile(by: 1))
        IDEIconButton(systemImage: "arrow.left", help: "Compare Previous File", action: moveToPreviousFile)
            .disabled(!session.canMoveToFile(by: -1))
        IDEIconButton(systemImage: "arrow.right", help: "Compare Next File", action: moveToNextFile)
            .disabled(!session.canMoveToFile(by: 1))
        IDEIconButton(systemImage: "arrow.up.forward.square", help: "Jump to Source (F4)", action: jumpToSource)
            .disabled(session.request.workingTreePath == nil && session.request.filePath == nil)

        separator

        Picker("Layout", selection: $session.settings.layout) {
            Image(systemName: "rectangle.split.2x1").help("Side-by-side viewer").tag(IDEDiffLayout.sideBySide)
            Image(systemName: "rectangle").help("Unified viewer").tag(IDEDiffLayout.unified)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()

        Menu {
            Picker("Whitespace", selection: $session.settings.whitespace) {
                ForEach(IDEDiffWhitespacePolicy.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Text(session.settings.whitespace.title)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Whitespace")

        Menu {
            Picker("Highlight", selection: $session.settings.highlight) {
                ForEach(IDEDiffHighlightMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Text(session.settings.highlight.title)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Highlighting")

        IDEIconButton(
            systemImage: "rectangle.compress.vertical", help: "Collapse Unchanged Fragments",
            isActive: session.settings.collapsesUnchanged, action: toggleCollapsesUnchanged)
            .background(session.settings.collapsesUnchanged ? IDEAppearance.ColorToken.selection : .clear)
            .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
        IDEIconButton(
            systemImage: "link", help: "Synchronize Scrolling",
            isActive: session.settings.synchronizesScrolling, action: toggleSynchronizesScrolling)
            .background(session.settings.synchronizesScrolling ? IDEAppearance.ColorToken.selection : .clear)
            .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
            .disabled(session.settings.layout == .unified)

        Spacer(minLength: IDEAppearance.Spacing.sm)

        IDEDiffToolbarStatus(session: session)
    }

    private var separator: some View {
        Rectangle()
            .fill(IDEAppearance.ColorToken.border)
            .frame(width: 1, height: 16)
            .padding(.horizontal, 2)
    }

    private func goToPreviousChange() {
        model.viewer?.goToChange(forward: false)
    }

    private func goToNextChange() {
        model.viewer?.goToChange(forward: true)
    }

    private func moveToPreviousFile() {
        session.moveToFile(by: -1)
    }

    private func moveToNextFile() {
        session.moveToFile(by: 1)
    }

    private func jumpToSource() {
        model.viewer?.jumpToSource()
    }

    private func toggleCollapsesUnchanged() {
        session.settings.collapsesUnchanged.toggle()
    }

    private func toggleSynchronizesScrolling() {
        session.settings.synchronizesScrolling.toggle()
    }
}
