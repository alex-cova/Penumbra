import AppKit
import EditorIntelligence
import Foundation
import JavaIntelligence
import Penumbra

// MARK: - ⌥↩ inspection commands

extension IDEWorkspace {
    /// What the editor's ⌥↩ menu hands back: an inspection command (change the active profile or
    /// open its settings), otherwise a Run / Debug action.
    func performCodeActionCommand(_ command: CodeActionCommand) {
        if command.id == IDEManualInjectionCodeActionProvider.injectCommand {
            performInjectLanguageCommand(command)
            return
        }
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

// MARK: - Inject language (temporary language injections)

extension IDEWorkspace {
    /// `Inject language…` (⌥↩, caret in a string): asks which language, records a temporary
    /// injection over the action's range, and rebuilds the pane's mode — an explicit user action,
    /// so a full reparse is acceptable. Temporary highlights last until the document closes.
    func performInjectLanguageCommand(_ command: CodeActionCommand) {
        guard command.arguments.count >= 2,
              let location = Int(command.arguments[0]),
              let length = Int(command.arguments[1]),
              length > 0 else {
            return
        }
        let pane = workbench.activePane
        guard let document = pane.selectedDocument, document.contentKind == .text else {
            return
        }
        let textLength = (sourceText(for: document) as NSString).length
        let range = NSRange(location: max(0, min(location, textLength)),
                            length: max(0, min(length, max(0, textLength - location))))
        guard range.length > 0 else {
            return
        }
        let options = IDELanguageSupport.selectableSyntaxes.filter { $0.id != nil }
        guard !options.isEmpty else {
            return
        }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 24), pullsDown: false)
        popup.addItems(withTitles: options.map(\.displayName))
        let alert = NSAlert()
        alert.messageText = "Inject language"
        alert.informativeText = "Temporarily highlight the string as the selected language, until this tab closes."
        alert.accessoryView = popup
        alert.addButton(withTitle: "Inject")
        alert.addButton(withTitle: "Cancel")
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else {
                return
            }
            let selected = popup.indexOfSelectedItem
            guard options.indices.contains(selected), let identifier = options[selected].id else {
                return
            }
            let key = IDEManualInjectionStore.key(url: document.url, displayName: document.displayName)
            manualInjectionStore.addInjection(
                ManualLanguageInjection(utf16Range: range, languageIdentifier: identifier, source: .temporary),
                forKey: key)
            rebuildLanguageModeForInjection(in: pane)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// Rebuilds the pane's mode with the same language but the document's injection provider, so
    /// a new temporary injection takes effect without touching `setLanguage` semantics.
    func rebuildLanguageModeForInjection(in pane: EditorPane) {
        guard let document = pane.selectedDocument, document.contentKind == .text else {
            return
        }
        let languageMode: LanguageMode
        if let language = document.language {
            languageMode = TreeSitterLanguageMode(language: language,
                                                  languageProvider: Self.languageProvider,
                                                  manualInjectionProvider: manualInjectionProvider(for: document))
        } else {
            languageMode = PlainTextLanguageMode()
        }
        let host = host(for: pane.id)
        host.textView.languageIdentifier = document.languageIdentifier
        preferences.applySmartKeys(to: host.textView)
        host.textView.setLanguageMode(languageMode)
        Task { await workspaceBridge.syncPane(pane) }
    }
}
