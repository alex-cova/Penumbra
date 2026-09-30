import AppKit
import EditorIntelligence
import Penumbra
import SwiftUI

/// The Generate… popup (Java ▸ Generate…): pick what to generate, then tick the fields to use.
/// Shown as a popover at the caret; the result goes back through `completion` once.
@MainActor
final class IDEGeneratePrompt: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private var completion: ((CodeGenerationChoice?) -> Void)?

    func present(
        menu: CodeGenerationMenu,
        in textView: TextView,
        completion: @escaping (CodeGenerationChoice?) -> Void
    ) {
        dismiss(result: nil)
        self.completion = completion
        let anchorRange = textView.selectedRanges.first ?? NSRange(location: textView.selectedRange.location, length: 0)
        let view = IDEGeneratePromptView(menu: menu) { [weak self] choice in
            self?.dismiss(result: choice)
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

    private func dismiss(result: CodeGenerationChoice?) {
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

private struct IDEGeneratePromptView: View {
    let menu: CodeGenerationMenu
    let onFinish: (CodeGenerationChoice?) -> Void

    /// The option whose fields are being ticked; `nil` while the list of options is showing.
    @State private var picked: CodeGenerationOption?
    @State private var cursor = 0
    @State private var checked: Set<String> = []
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            Text(picked.map { "\($0.title) — \(menu.typeName)" } ?? "Generate — \(menu.typeName)")
                .font(IDEAppearance.Typography.sectionHeader)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            if let picked {
                fieldList(for: picked)
            } else {
                optionList
            }
        }
        .padding(IDEAppearance.Spacing.md)
        .frame(width: 280)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onExitCommand(perform: back)
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.return) { confirm() }
        .onKeyPress(.space) { toggleCurrent() }
    }

    // MARK: - Options

    private var optionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(menu.options.enumerated()), id: \.element.id) { position, option in
                row(highlighted: position == cursor) {
                    Text(option.title)
                        .font(IDEAppearance.Typography.body)
                        .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    Spacer()
                }
                .onTapGesture { pick(option) }
            }
        }
    }

    // MARK: - Fields

    private func fieldList(for option: CodeGenerationOption) -> some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            if option.fields.isEmpty {
                Text("No fields — an empty constructor will be generated.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(option.fields.enumerated()), id: \.element.id) { position, field in
                        row(highlighted: position == cursor) {
                            Image(systemName: checked.contains(field.name) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(
                                    checked.contains(field.name)
                                        ? IDEAppearance.ColorToken.accent : IDEAppearance.ColorToken.muted
                                )
                            Text(field.name)
                                .font(IDEAppearance.Typography.monoCaption)
                                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                            Text(field.typeText)
                                .font(IDEAppearance.Typography.monoSmall)
                                .foregroundStyle(IDEAppearance.ColorToken.muted)
                                .lineLimit(1)
                            Spacer()
                        }
                        .onTapGesture {
                            cursor = position
                            toggle(field)
                        }
                        .accessibilityAddTraits(checked.contains(field.name) ? .isSelected : [])
                    }
                }
            }
            .frame(maxHeight: 220)
            HStack {
                Button("Select All") { checked = Set(option.fields.map(\.name)) }
                    .disabled(option.fields.isEmpty)
                Button("None") { checked = [] }
                    .disabled(option.fields.isEmpty)
                Spacer()
                Button("Cancel") { onFinish(nil) }
                Button("Generate", action: { _ = confirm() })
                    .disabled(!canGenerate(option))
            }
            .font(IDEAppearance.Typography.caption)
        }
    }

    private func row<Content: View>(highlighted: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: IDEAppearance.Spacing.xs, content: content)
            .padding(.horizontal, IDEAppearance.Spacing.xs)
            .padding(.vertical, 4)
            .background(highlighted ? IDEAppearance.ColorToken.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
    }

    // MARK: - Actions

    private func canGenerate(_ option: CodeGenerationOption) -> Bool {
        option.allowsEmptySelection || !checked.isEmpty
    }

    private func pick(_ option: CodeGenerationOption) {
        guard !option.fields.isEmpty || option.allowsEmptySelection else { return }
        if option.fields.isEmpty {
            onFinish(CodeGenerationChoice(kind: option.kind, fieldNames: []))
            return
        }
        picked = option
        checked = Set(option.fields.map(\.name))
        cursor = 0
    }

    private func toggle(_ field: CodeGenerationField) {
        if checked.contains(field.name) {
            checked.remove(field.name)
        } else {
            checked.insert(field.name)
        }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        let count = picked?.fields.count ?? menu.options.count
        guard count > 0 else { return .handled }
        cursor = min(max(cursor + delta, 0), count - 1)
        return .handled
    }

    private func toggleCurrent() -> KeyPress.Result {
        guard let picked, picked.fields.indices.contains(cursor) else { return .ignored }
        toggle(picked.fields[cursor])
        return .handled
    }

    private func confirm() -> KeyPress.Result {
        if let picked {
            guard canGenerate(picked) else { return .handled }
            // Fields keep declaration order whatever order they were ticked in.
            let names = picked.fields.map(\.name).filter { checked.contains($0) }
            onFinish(CodeGenerationChoice(kind: picked.kind, fieldNames: names))
        } else if menu.options.indices.contains(cursor) {
            pick(menu.options[cursor])
        }
        return .handled
    }

    /// Esc steps back from the field list to the options, then closes.
    private func back() {
        if picked != nil {
            picked = nil
            cursor = 0
        } else {
            onFinish(nil)
        }
    }
}
