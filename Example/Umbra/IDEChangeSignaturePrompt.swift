import AppKit
import EditorIntelligence
import Penumbra
import SwiftUI

/// Dialog for Change Method Signature: rename, add a trailing parameter, or remove the last one.
@MainActor
final class IDEChangeSignaturePrompt: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private var completion: (([String: String]?) -> Void)?

    func present(
        descriptor: RefactoringDescriptor,
        in textView: TextView,
        completion: @escaping ([String: String]?) -> Void
    ) {
        dismiss(result: nil)
        self.completion = completion
        let anchorRange = textView.selectedRanges.first ?? NSRange(location: textView.selectedRange.location, length: 0)
        let suggested = descriptor.suggestedParameters
        let view = IDEChangeSignaturePromptView(
            title: descriptor.title,
            newName: suggested["newName"] ?? "",
            addType: suggested["addParameterType"] ?? "",
            addName: suggested["addParameterName"] ?? "",
            addDefault: suggested["addParameterDefault"] ?? "",
            removeLast: suggested["removeLastParameter"] == "true"
        ) { [weak self] parameters in
            self?.dismiss(result: parameters)
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

    private func dismiss(result: [String: String]?) {
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

private struct IDEChangeSignaturePromptView: View {
    let title: String
    let onFinish: ([String: String]?) -> Void

    @State private var newName: String
    @State private var addType: String
    @State private var addName: String
    @State private var addDefault: String
    @State private var removeLast: Bool
    @FocusState private var focusedField: Field?
    private let originalName: String

    private enum Field: Hashable {
        case name, type, paramName, defaultValue
    }

    init(
        title: String, newName: String, addType: String, addName: String, addDefault: String, removeLast: Bool,
        onFinish: @escaping ([String: String]?) -> Void
    ) {
        self.title = title
        self.onFinish = onFinish
        self.originalName = newName
        _newName = State(initialValue: newName)
        _addType = State(initialValue: addType)
        _addName = State(initialValue: addName)
        _addDefault = State(initialValue: addDefault)
        _removeLast = State(initialValue: removeLast)
    }

    private var nameProblem: String? { RenameTarget.validateIdentifier(newName) }

    private var canCommit: Bool {
        guard nameProblem == nil else { return false }
        if removeLast && !addFieldsEmpty { return false }
        if addFieldsPartial { return false }
        return newName != originalName || removeLast || !addFieldsEmpty
    }

    private var addFieldsEmpty: Bool {
        addType.trimmingCharacters(in: .whitespaces).isEmpty
            && addName.trimmingCharacters(in: .whitespaces).isEmpty
            && addDefault.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var addFieldsPartial: Bool {
        !addFieldsEmpty && (addType.trimmingCharacters(in: .whitespaces).isEmpty
            || addName.trimmingCharacters(in: .whitespaces).isEmpty
            || addDefault.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            Text(title)
                .font(IDEAppearance.Typography.sectionHeader)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            labeledField("Method name", text: $newName, field: .name)
            Text(nameProblem ?? " ")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.error)
                .lineLimit(2)
            Divider()
            Text("Add parameter (optional)")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            labeledField("Type", text: $addType, field: .type)
            labeledField("Name", text: $addName, field: .paramName)
            labeledField("Default at call sites", text: $addDefault, field: .defaultValue)
            Toggle("Remove last parameter", isOn: $removeLast)
                .font(IDEAppearance.Typography.caption)
            if addFieldsPartial {
                Text("Fill in all add-parameter fields, or leave them empty.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
            }
            if removeLast && !addFieldsEmpty {
                Text("Choose add or remove, not both.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
            }
            HStack {
                Spacer()
                Button("Cancel") { onFinish(nil) }
                Button("OK", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCommit)
            }
        }
        .padding(IDEAppearance.Spacing.md)
        .frame(width: 300)
        .onAppear { focusedField = .name }
        .onExitCommand { onFinish(nil) }
    }

    private func labeledField(_ label: String, text: Binding<String>, field: Field) -> some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Text(label)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: 120, alignment: .leading)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .font(IDEAppearance.Typography.monoSmall)
                .focused($focusedField, equals: field)
        }
    }

    private func commit() {
        guard canCommit else { return }
        onFinish([
            "newName": newName,
            "addParameterType": addType,
            "addParameterName": addName,
            "addParameterDefault": addDefault,
            "removeLastParameter": removeLast ? "true" : ""
        ])
    }
}
