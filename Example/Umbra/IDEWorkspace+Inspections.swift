import EditorIntelligence
import Foundation
import JavaIntelligence

// MARK: - ⌥↩ inspection commands

extension IDEWorkspace {
    /// What the editor's ⌥↩ menu hands back: an inspection command (change the active profile or
    /// open its settings), otherwise a Run / Debug action.
    func performCodeActionCommand(_ command: CodeActionCommand) {
        guard let code = command.arguments.first, let rule = JavaInspectionRule(code: code) else {
            performRunCodeAction(command)
            return
        }
        switch command.id {
        case JavaInspectionCommand.disable:
            inspections.edit { $0.setEnabled(false, for: rule) }
        case JavaInspectionCommand.quiet:
            inspections.edit { $0.setSeverity(.noHighlighting, for: rule) }
        case JavaInspectionCommand.configure:
            showInspectionSettings(for: rule)
        default:
            performRunCodeAction(command)
        }
    }

    /// Opens Settings › Java › Inspections with `rule` found, its group selected and its scopes open.
    func showInspectionSettings(for rule: JavaInspectionRule) {
        inspections.focusedRuleCode = rule.code
        requestedSettingsDomain = .java
        showSettings()
    }

    /// The readable name of a diagnostic's code for the editor's hover ("java-inspection" +
    /// "string-comparison-identity" → the rule's title).
    nonisolated static func diagnosticTitle(source: String, code: String) -> String? {
        guard source == "java-inspection" else { return nil }
        return JavaInspectionRule(code: code)?.title
    }
}
