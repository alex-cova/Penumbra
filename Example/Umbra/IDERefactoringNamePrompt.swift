import AppKit
import EditorIntelligence
import Penumbra
import SwiftUI

/// Inline name prompt for refactorings (extract variable, …).
@MainActor
final class IDERefactoringNamePrompt: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private var completion: ((String?) -> Void)?

    func present(
        title: String,
        suggestedName: String,
        in textView: TextView,
        validate: @escaping @Sendable (String) -> String?,
        completion: @escaping (String?) -> Void
    ) {
        dismiss(result: nil)
        self.completion = completion
        let anchorRange = textView.selectedRanges.first ?? NSRange(location: textView.selectedRange.location, length: 0)
        let view = IDERefactoringNamePromptView(
            title: title, suggestedName: suggestedName, validate: validate
        ) { [weak self] name in
            self?.dismiss(result: name)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: view.preferredColorScheme(.dark))
        self.popover = popover
        let caret = textView.caretRectInViewport(at: anchorRange.location)
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
        dismiss(result: nil)
    }
}

private struct IDERefactoringNamePromptView: View {
    let title: String
    let validate: @Sendable (String) -> String?
    let onFinish: (String?) -> Void

    @State private var name: String
    @FocusState private var isFocused: Bool

    init(
        title: String, suggestedName: String, validate: @escaping @Sendable (String) -> String?,
        onFinish: @escaping (String?) -> Void
    ) {
        self.title = title
        self.validate = validate
        self.onFinish = onFinish
        _name = State(initialValue: suggestedName)
    }

    private var problem: String? { validate(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            Text(title)
                .font(IDEAppearance.Typography.sectionHeader)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(IDEAppearance.Typography.monoSmall)
                .focused($isFocused)
                .onSubmit(commit)
                .frame(width: 240)
                .accessibilityLabel("Name")
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
        onFinish(name)
    }
}
