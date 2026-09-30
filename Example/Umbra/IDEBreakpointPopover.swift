import AppKit
import JavaIntelligence
import Penumbra
import SwiftUI

/// Edits one breakpoint for the gutter popover and the Breakpoints tab. Toggles save at once;
/// the text fields (condition, log expression, pass count) save when committed, so a half-typed
/// condition never reaches a running program.
@MainActor
@Observable
final class IDEBreakpointEditor {
    private(set) var breakpoint: JavaBreakpoint
    var conditionDraft: String
    var logExpressionDraft: String
    var passCountDraft: String
    @ObservationIgnored private let save: (JavaBreakpoint) -> Void

    init(breakpoint: JavaBreakpoint, save: @escaping (JavaBreakpoint) -> Void) {
        self.breakpoint = breakpoint
        conditionDraft = breakpoint.condition ?? ""
        logExpressionDraft = breakpoint.logExpression ?? ""
        passCountDraft = breakpoint.passCount.map(String.init) ?? ""
        self.save = save
    }

    func update(_ change: (inout JavaBreakpoint) -> Void) {
        var updated = breakpoint
        change(&updated)
        guard updated != breakpoint else { return }
        breakpoint = updated
        save(updated)
    }

    /// Saves the text fields.
    func commitDrafts() {
        let condition = conditionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let log = logExpressionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let passCount = Int(passCountDraft.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
        update {
            $0.condition = condition.isEmpty ? nil : condition
            $0.logExpression = log.isEmpty ? nil : log
            $0.passCount = passCount
        }
    }

    var conditionProblem: String? { JavaExpressionSyntax.problem(in: conditionDraft) }
    var logExpressionProblem: String? { JavaExpressionSyntax.problem(in: logExpressionDraft) }

    var suspends: Binding<Bool> {
        Binding(
            get: { self.breakpoint.suspendPolicy != .none },
            set: { suspend in self.update { $0.suspendPolicy = suspend ? .all : .none } }
        )
    }

    /// All or Thread; shows All while Suspend is off.
    var suspendPolicy: Binding<JavaBreakpointSuspendPolicy> {
        Binding(
            get: { self.breakpoint.suspendPolicy == .none ? .all : self.breakpoint.suspendPolicy },
            set: { policy in self.update { $0.suspendPolicy = policy } }
        )
    }

    var isEnabled: Binding<Bool> {
        Binding(get: { self.breakpoint.isEnabled }, set: { value in self.update { $0.isEnabled = value } })
    }

    var logMessage: Binding<Bool> {
        Binding(get: { self.breakpoint.logMessage }, set: { value in self.update { $0.logMessage = value } })
    }

    var removeOnceHit: Binding<Bool> {
        Binding(get: { self.breakpoint.removeOnceHit }, set: { value in self.update { $0.removeOnceHit = value } })
    }
}

/// The popover a right click on a breakpoint opens, as in IntelliJ: Enabled, Suspend (All or
/// Thread), Condition, and More for everything else.
@MainActor
final class IDEBreakpointPopover: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private var editor: IDEBreakpointEditor?

    func present(breakpoint: JavaBreakpoint, workspace: IDEWorkspace, focusCondition: Bool, in textView: TextView) {
        dismiss()
        let editor = IDEBreakpointEditor(breakpoint: breakpoint) { [weak workspace] updated in
            workspace?.updateBreakpoint(updated)
        }
        self.editor = editor
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        let view = IDEBreakpointPopoverView(
            editor: editor,
            focusCondition: focusCondition,
            onMore: { [weak self, weak workspace] in
                self?.dismiss()
                workspace?.viewBreakpoints(select: breakpoint.id)
            },
            onRemove: { [weak self, weak workspace] in
                self?.dismiss()
                if let current = workspace?.breakpoints.first(where: { $0.id == breakpoint.id }) {
                    workspace?.removeBreakpoint(current)
                }
            },
            onDone: { [weak self] in self?.dismiss() }
        )
        popover.contentViewController = NSHostingController(rootView: view.preferredColorScheme(IDEAppearance.preferredColorScheme))
        self.popover = popover
        let location = textView.location(at: TextLocation(lineNumber: max(0, breakpoint.line - 1), column: 0)) ?? 0
        let caret = textView.caretRectInViewport(at: location)
        let anchor = CGRect(x: 0, y: caret.minY, width: max(textView.gutterWidth, 12), height: max(caret.height, 14))
        popover.show(relativeTo: anchor, of: textView, preferredEdge: .maxX)
    }

    func dismiss() {
        editor?.commitDrafts()
        popover?.close()
        popover = nil
        editor = nil
    }

    func popoverWillClose(_ notification: Notification) {
        editor?.commitDrafts()
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
        editor = nil
    }
}

private struct IDEBreakpointPopoverView: View {
    @Bindable var editor: IDEBreakpointEditor
    let focusCondition: Bool
    let onMore: () -> Void
    let onRemove: () -> Void
    let onDone: () -> Void

    @FocusState private var conditionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            HStack {
                Text(editor.breakpoint.title)
                    .font(IDEAppearance.Typography.body.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: IDEAppearance.Spacing.sm)
                Button(action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .help("Remove Breakpoint")
            }
            Toggle("Enabled", isOn: editor.isEnabled)
            HStack(spacing: IDEAppearance.Spacing.sm) {
                Toggle("Suspend:", isOn: editor.suspends)
                Picker("", selection: editor.suspendPolicy) {
                    Text("All").tag(JavaBreakpointSuspendPolicy.all)
                    Text("Thread").tag(JavaBreakpointSuspendPolicy.thread)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
                .disabled(!editor.suspends.wrappedValue)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Condition:")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                IDEExpressionField(
                    text: $editor.conditionDraft,
                    placeholder: "A boolean expression, e.g. i == 3",
                    problem: editor.conditionProblem,
                    onSubmit: {
                        editor.commitDrafts()
                        onDone()
                    }
                )
                .focused($conditionFocused)
            }
            HStack {
                Button("More (⇧⌘F8)", action: onMore)
                    .buttonStyle(.link)
                Spacer()
                Button("Done") {
                    editor.commitDrafts()
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(IDEAppearance.Spacing.md)
        .frame(width: 340)
        .onAppear {
            if focusCondition { conditionFocused = true }
        }
    }
}

/// A single-line field for a Java expression, outlined in red with the reason when it does not
/// parse. It is saved anyway: the debugger reports what it cannot evaluate.
struct IDEExpressionField: View {
    @Binding var text: String
    let placeholder: String
    let problem: String?
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(IDEAppearance.Typography.monoSmall)
                .onSubmit(onSubmit)
                .overlay {
                    if problem != nil {
                        RoundedRectangle(cornerRadius: 5).stroke(IDEAppearance.ColorToken.error, lineWidth: 1)
                    }
                }
            if let problem {
                Text(problem)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
            }
        }
    }
}

/// Every property of a breakpoint, for the Breakpoints tab's detail pane.
struct IDEBreakpointPropertiesForm: View {
    @Bindable var editor: IDEBreakpointEditor

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            Text(editor.breakpoint.title)
                .font(IDEAppearance.Typography.body.weight(.semibold))
            Toggle("Enabled", isOn: editor.isEnabled)
            kindOptions
            HStack(spacing: IDEAppearance.Spacing.sm) {
                Toggle("Suspend:", isOn: editor.suspends)
                Picker("", selection: editor.suspendPolicy) {
                    Text("All").tag(JavaBreakpointSuspendPolicy.all)
                    Text("Thread").tag(JavaBreakpointSuspendPolicy.thread)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
                .disabled(!editor.suspends.wrappedValue)
            }
            label("Condition:")
            IDEExpressionField(text: $editor.conditionDraft, placeholder: "A boolean expression",
                               problem: editor.conditionProblem, onSubmit: editor.commitDrafts)
            Divider()
            label("Log:")
            Toggle("“Breakpoint hit” message", isOn: editor.logMessage)
            label("Evaluate and log:")
            IDEExpressionField(text: $editor.logExpressionDraft, placeholder: "An expression, e.g. \"i=\" + i",
                               problem: editor.logExpressionProblem, onSubmit: editor.commitDrafts)
            Divider()
            Toggle("Remove once hit", isOn: editor.removeOnceHit)
            HStack {
                Text("Disable until hit count:")
                TextField("", text: $editor.passCountDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .onSubmit(editor.commitDrafts)
            }
            .help("Let this many hits pass, then stop once.")
            HStack {
                Spacer()
                Button("Apply", action: editor.commitDrafts)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .font(IDEAppearance.Typography.body)
    }

    @ViewBuilder
    private var kindOptions: some View {
        switch editor.breakpoint.kind {
        case .exception(let className, let caught, let uncaught):
            HStack {
                Toggle("Caught exception", isOn: Binding(get: { caught }, set: { value in
                    editor.update { $0.kind = .exception(className: className, caught: value, uncaught: uncaught) }
                }))
                Toggle("Uncaught exception", isOn: Binding(get: { uncaught }, set: { value in
                    editor.update { $0.kind = .exception(className: className, caught: caught, uncaught: value) }
                }))
            }
        case .field(let className, let fieldName, let access, let modification):
            HStack {
                Toggle("Field access", isOn: Binding(get: { access }, set: { value in
                    editor.update { $0.kind = .field(className: className, fieldName: fieldName, access: value, modification: modification) }
                }))
                Toggle("Field modification", isOn: Binding(get: { modification }, set: { value in
                    editor.update { $0.kind = .field(className: className, fieldName: fieldName, access: access, modification: value) }
                }))
            }
        case .line, .method:
            EmptyView()
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(IDEAppearance.Typography.caption)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
    }
}
