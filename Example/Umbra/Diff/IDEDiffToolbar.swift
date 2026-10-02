import Observation
import SwiftUI

/// Connects the SwiftUI toolbar to its viewer, which owns the text views the actions move.
@MainActor
@Observable
final class IDEDiffToolbarModel {
    @ObservationIgnored weak var viewer: IDEDiffViewerView?
    var session: IDEDiffSession?
    /// Bumped when the viewer changed something the session does not publish.
    private(set) var revision = 0

    func refresh() {
        revision &+= 1
    }
}

/// The diff tab's toolbar, after IntelliJ's: change and file navigation, Jump to Source, the
/// layout, whitespace and highlighting options, collapsing, synchronized scrolling, and the count.
struct IDEDiffToolbar: View {
    @Bindable var model: IDEDiffToolbarModel

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            if let session = model.session {
                content(session)
            }
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(IDEAppearance.ColorToken.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(IDEAppearance.ColorToken.border).frame(height: 1)
        }
    }

    @ViewBuilder
    private func content(_ session: IDEDiffSession) -> some View {
        let _ = model.revision
        button("arrow.up", help: "Previous Difference (⇧F7)") { model.viewer?.goToChange(forward: false) }
            .disabled(session.chunks.isEmpty)
        button("arrow.down", help: "Next Difference (F7)") { model.viewer?.goToChange(forward: true) }
            .disabled(session.chunks.isEmpty && !session.canMoveToFile(by: 1))
        button("arrow.left", help: "Compare Previous File") { session.moveToFile(by: -1) }
            .disabled(!session.canMoveToFile(by: -1))
        button("arrow.right", help: "Compare Next File") { session.moveToFile(by: 1) }
            .disabled(!session.canMoveToFile(by: 1))
        button("arrow.up.forward.square", help: "Jump to Source (F4)") { model.viewer?.jumpToSource() }
            .disabled(session.request.workingTreePath == nil && session.request.filePath == nil)

        separator

        Picker("", selection: Binding(get: { session.settings.layout }, set: { session.settings.layout = $0 })) {
            Image(systemName: "rectangle.split.2x1").help("Side-by-side viewer").tag(IDEDiffLayout.sideBySide)
            Image(systemName: "rectangle").help("Unified viewer").tag(IDEDiffLayout.unified)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()

        Menu {
            Picker("Whitespace", selection: Binding(get: { session.settings.whitespace }, set: { session.settings.whitespace = $0 })) {
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
            Picker("Highlight", selection: Binding(get: { session.settings.highlight }, set: { session.settings.highlight = $0 })) {
                ForEach(IDEDiffHighlightMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Text(session.settings.highlight.title)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Highlighting")

        toggle("rectangle.compress.vertical", isOn: session.settings.collapsesUnchanged, help: "Collapse Unchanged Fragments") {
            session.settings.collapsesUnchanged.toggle()
        }
        toggle("link", isOn: session.settings.synchronizesScrolling, help: "Synchronize Scrolling") {
            session.settings.synchronizesScrolling.toggle()
        }
        .disabled(session.settings.layout == .unified)

        Spacer(minLength: IDEAppearance.Spacing.sm)

        status(session)
    }

    @ViewBuilder
    private func status(_ session: IDEDiffSession) -> some View {
        if let message = session.message {
            Text(message)
                .foregroundStyle(IDEAppearance.ColorToken.error)
                .lineLimit(1)
                .help(message)
        } else if let reason = session.readOnlyReason {
            Text(reason)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .lineLimit(1)
        } else if session.isRightDirty {
            Text("Edited, saved on ⌘S or when you leave the tab")
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .lineLimit(1)
        }
        Text(counter(session))
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
    }

    private func counter(_ session: IDEDiffSession) -> String {
        switch session.state {
        case .loading: return "Loading…"
        case .binary, .failed: return ""
        case .ready: break
        }
        let count = session.chunks.count
        guard count > 0 else { return "No differences" }
        let noun = count == 1 ? "difference" : "differences"
        if let current = session.currentChunkIndex, current < count {
            return "\(current + 1) of \(count) \(noun)"
        }
        return "\(count) \(noun)"
    }

    private var separator: some View {
        Rectangle()
            .fill(IDEAppearance.ColorToken.border)
            .frame(width: 1, height: 16)
            .padding(.horizontal, 2)
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        IDEExplorerToolbarButton(systemImage: symbol, help: help, action: action)
    }

    private func toggle(_ symbol: String, isOn: Bool, help: String, action: @escaping () -> Void) -> some View {
        IDEExplorerToolbarButton(systemImage: symbol, help: help, isActive: isOn, action: action)
            .background(isOn ? IDEAppearance.ColorToken.selection : .clear)
            .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
    }
}
