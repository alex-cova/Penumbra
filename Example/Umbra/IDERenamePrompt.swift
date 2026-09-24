import AppKit
import EditorIntelligence
import Penumbra
import SwiftUI

/// The inline "new name" prompt: a popover at the caret with a text field and live validation.
/// Return confirms (when the name is valid), Escape or a click elsewhere cancels.
@MainActor
final class IDERenamePrompt: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private var completion: ((String?) -> Void)?

    func present(target: RenameTarget, in textView: TextView, completion: @escaping (String?) -> Void) {
        dismiss(result: nil)
        self.completion = completion
        let view = IDERenamePromptView(target: target) { [weak self] name in
            self?.dismiss(result: name)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: view.preferredColorScheme(.dark))
        self.popover = popover
        let caret = textView.caretRectInViewport(at: target.range.start.utf16Offset)
        let anchor = caret.isEmpty ? CGRect(x: 0, y: 0, width: 1, height: 16) : caret.insetBy(dx: 0, dy: -1)
        popover.show(relativeTo: anchor, of: textView, preferredEdge: .maxY)
    }

    private func dismiss(result: String?) {
        let pending = completion
        completion = nil
        let current = popover
        popover = nil
        current?.close()
        pending?(result)
    }

    func popoverDidClose(_ notification: Notification) {
        // Escape or a click outside: treat as cancel unless a result already went out.
        dismiss(result: nil)
    }
}

private struct IDERenamePromptView: View {
    let target: RenameTarget
    let onFinish: (String?) -> Void

    @State private var name: String
    @FocusState private var isFocused: Bool

    init(target: RenameTarget, onFinish: @escaping (String?) -> Void) {
        self.target = target
        self.onFinish = onFinish
        _name = State(initialValue: target.currentName)
    }

    private var problem: String? {
        name == target.currentName ? nil : target.validate(name)
    }

    private var title: String {
        target.kindDescription.map { "Rename \($0)" } ?? "Rename"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            Text(title)
                .font(IDEAppearance.Typography.sectionHeader)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            TextField("New name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(IDEAppearance.Typography.monoSmall)
                .focused($isFocused)
                .onSubmit(commit)
                .frame(width: 240)
                .accessibilityLabel("New name")
            Text(problem ?? " ")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.error)
                .lineLimit(2)
                .frame(width: 240, alignment: .leading)
        }
        .padding(IDEAppearance.Spacing.md)
        .onAppear { isFocused = true }
        .onExitCommand { onFinish(nil) }
    }

    private func commit() {
        guard problem == nil else { return }
        onFinish(name == target.currentName ? nil : name)
    }
}
