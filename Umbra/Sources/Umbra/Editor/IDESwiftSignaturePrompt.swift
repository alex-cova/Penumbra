import AppKit
import EditorIntelligence
import Observation
import Penumbra
import SwiftIntelligence
import SwiftUI

/// The parameter list Change Function Signature edits: a row per parameter, in the order they will have, with what
/// the user may change about each. Pure state, so the form and its tests share the rules.
@MainActor
@Observable
final class IDESwiftSignatureModel {
    let functionName: String
    private let original: [SwiftSignatureParameter]
    var parameters: [SwiftSignatureParameter]

    init(functionName: String, parameters: [SwiftSignatureParameter]) {
        self.functionName = functionName
        original = parameters
        self.parameters = parameters
    }

    /// Built from the descriptor's suggestion: the function's name and the current parameter list.
    convenience init?(descriptor: RefactoringDescriptor) {
        guard let change = SwiftSignatureChange(json: descriptor.suggestedParameters["parameters"]) else { return nil }
        self.init(functionName: descriptor.suggestedParameters["functionName"] ?? "function", parameters: change.parameters)
    }

    var isChanged: Bool { parameters != original }

    /// Why the list cannot be applied, nil when it can.
    var problem: String? {
        SwiftChangeSignature.problem(in: SwiftSignatureChange(parameters: parameters), oldCount: original.count)
    }

    var canCommit: Bool { isChanged && problem == nil }

    /// What the declaration will read like.
    var preview: String {
        let list = parameters.map { parameter -> String in
            let naming = parameter.label == "_" ? "_ \(parameter.name)" : (parameter.label == parameter.name ? parameter.name : "\(parameter.label) \(parameter.name)")
            let value = parameter.defaultValue.trimmingCharacters(in: .whitespaces)
            return "\(naming): \(parameter.type)" + (value.isEmpty ? "" : " = \(value)")
        }
        return "\(functionName)(\(list.joined(separator: ", ")))"
    }

    func canMove(_ index: Int, by offset: Int) -> Bool { parameters.indices.contains(index + offset) }

    func move(_ index: Int, by offset: Int) {
        guard canMove(index, by: offset) else { return }
        parameters.swapAt(index, index + offset)
    }

    func remove(_ index: Int) {
        guard parameters.indices.contains(index) else { return }
        parameters.remove(at: index)
    }

    /// A new parameter at the end: it starts as `value: Int = 0`, the commonest need, to be edited.
    func addParameter() {
        var name = "value"
        var number = 2
        while parameters.contains(where: { $0.name == name || $0.label == name }) {
            name = "value\(number)"
            number += 1
        }
        parameters.append(SwiftSignatureParameter(label: name, name: name, type: "Int", defaultValue: "0"))
    }

    /// The label follows the name while they have been the same, as when writing a declaration.
    func rename(_ index: Int, to name: String) {
        guard parameters.indices.contains(index) else { return }
        if parameters[index].label == parameters[index].name { parameters[index].label = name }
        parameters[index].name = name
    }

    /// What the form hands back to the provider.
    var result: [String: String] { ["parameters": SwiftSignatureChange(parameters: parameters).json] }
}

/// Change Function Signature for Swift: a popover under the caret with the parameter list to edit.
@MainActor
final class IDESwiftSignaturePrompt: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private var completion: (([String: String]?) -> Void)?

    func present(
        descriptor: RefactoringDescriptor,
        in textView: TextView,
        completion: @escaping ([String: String]?) -> Void
    ) {
        dismiss(result: nil)
        guard let model = IDESwiftSignatureModel(descriptor: descriptor) else {
            completion(nil)
            return
        }
        self.completion = completion
        let anchorRange = textView.selectedRanges.first ?? NSRange(location: textView.selectedRange.location, length: 0)
        let view = IDESwiftSignaturePromptView(model: model) { [weak self] result in
            self?.dismiss(result: result)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: view.preferredColorScheme(IDEAppearance.preferredColorScheme))
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

struct IDESwiftSignaturePromptView: View {
    @State var model: IDESwiftSignatureModel
    let onFinish: ([String: String]?) -> Void

    init(model: IDESwiftSignatureModel, onFinish: @escaping ([String: String]?) -> Void) {
        _model = State(initialValue: model)
        self.onFinish = onFinish
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            Text("Change Signature of \u{201C}\(model.functionName)\u{201D}")
                .font(IDEAppearance.Typography.sectionHeader)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            HStack(spacing: IDEAppearance.Spacing.xs) {
                Color.clear.frame(width: 44)
                header("Label", width: 90)
                header("Name", width: 100)
                header("Type", width: 110)
                header("Default", width: 80)
                header("Calls get", width: 80)
            }
            ForEach(Array(model.parameters.enumerated()), id: \.offset) { index, parameter in
                row(index, parameter)
            }
            Button { model.addParameter() } label: { Label("Add Parameter", systemImage: "plus") }
                .buttonStyle(.link)
            Divider()
            Text(model.preview)
                .font(IDEAppearance.Typography.monoSmall)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.problem ?? " ")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.error)
                .lineLimit(2)
            HStack {
                Spacer()
                Button("Cancel") { onFinish(nil) }
                Button("Refactor") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canCommit)
            }
        }
        .padding(IDEAppearance.Spacing.md)
        .frame(width: 560)
        .onExitCommand { onFinish(nil) }
    }

    private func header(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(IDEAppearance.Typography.caption)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .frame(width: width, alignment: .leading)
    }

    private func row(_ index: Int, _ parameter: SwiftSignatureParameter) -> some View {
        let isNew = parameter.oldIndex == nil
        return HStack(spacing: IDEAppearance.Spacing.xs) {
            Button { model.move(index, by: -1) } label: { Image(systemName: "arrow.up") }
                .buttonStyle(.borderless)
                .disabled(!model.canMove(index, by: -1))
                .help("Move up")
            Button { model.move(index, by: 1) } label: { Image(systemName: "arrow.down") }
                .buttonStyle(.borderless)
                .disabled(!model.canMove(index, by: 1))
                .help("Move down")
            field("label", text: Binding(get: { model.parameters[index].label }, set: { model.parameters[index].label = $0 }), width: 90)
            field("name", text: Binding(get: { model.parameters[index].name }, set: { model.rename(index, to: $0) }), width: 100)
            if isNew {
                field("Type", text: Binding(get: { model.parameters[index].type }, set: { model.parameters[index].type = $0 }), width: 110)
            } else {
                Text(parameter.type)
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
                    .frame(width: 110, alignment: .leading)
            }
            field("none", text: Binding(get: { model.parameters[index].defaultValue }, set: { model.parameters[index].defaultValue = $0 }), width: 80)
            if isNew {
                field("none", text: Binding(get: { model.parameters[index].callSiteValue }, set: { model.parameters[index].callSiteValue = $0 }), width: 80)
            } else {
                Color.clear.frame(width: 80)
            }
            Button { model.remove(index) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Remove this parameter")
        }
    }

    private func field(_ prompt: String, text: Binding<String>, width: CGFloat) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.roundedBorder)
            .font(IDEAppearance.Typography.monoSmall)
            .frame(width: width)
    }

    private func commit() {
        guard model.canCommit else { return }
        onFinish(model.result)
    }
}
