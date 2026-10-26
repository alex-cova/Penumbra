import AppKit
import EditorIntelligence
import JavaIntelligence

/// The questions the window asks on behalf of services and of its own state: whether to trust a
/// project's build scripts, the decompiler agreement, a Metal fallback notice, and discarding unsaved
/// editors. The dialogs that guard one workflow (revert, trash, reload) stay beside that workflow.
extension IDEWorkspace {
    func confirmDiscardingUnsavedChanges(
        messageText: String,
        confirmButtonTitle: String
    ) -> Bool {
        let dirtyCount = workbench.allDocuments().filter(\.isDirty).count
        guard dirtyCount > 0 else { return true }
        var alert = IDEAlert.confirm(messageText, detail: unsavedPromptText(), confirm: confirmButtonTitle)
        return alert.confirms()
    }

    func presentError(_ error: Error) {
        NSAlert(error: error).runModal()
    }

    func promptGradleTrust(for url: URL) async -> Bool {
        let name = url.lastPathComponent
        return await promptProjectTrust(
            message: "Trust and run Gradle build scripts for “\(name)”?",
            detail: "Gradle build scripts can run arbitrary code, including code from plugins they apply. Trust this folder only if you trust its contents."
        )
    }

    func promptProjectTrust(message: String, detail: String) async -> Bool {
        var alert = IDEAlert.confirm(message, detail: detail, confirm: "Trust Project", cancel: "Don't Trust")
        return await alert.confirms(in: window)
    }

    /// Whether the user already agreed to `topic`; never prompts.
    func hasConsent(to topic: ConsentTopic) -> Bool {
        switch topic {
        case .javaDecompiler: preferences.javaDecompilerAgreementAccepted
        default: false
        }
    }

    /// Asks for `topic`, showing the agreement when the host has one; a topic it does not know is refused.
    func requestConsent(to topic: ConsentTopic) async -> Bool {
        switch topic {
        case .javaDecompiler: await requestDecompilerConsent()
        default: false
        }
    }

    /// Shown once before Umbra first decompiles a `.class` file with no attached source. Accepting
    /// persists to ``IDEPreferences/javaDecompilerAgreementAccepted``, which the caller then treats
    /// as standing consent — this alert should not appear again.
    func requestDecompilerConsent() async -> Bool {
        var alert = IDEAlert.confirm(JavaDecompilerAgreement.title, confirm: "Accept")
        let scrollView = NSTextView.scrollableTextView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 420, height: 220)
        if let textView = scrollView.documentView as? NSTextView {
            textView.string = JavaDecompilerAgreement.text
            textView.isEditable = false
            textView.font = .systemFont(ofSize: 11)
        }
        alert.accessory = scrollView
        let accepted = await alert.confirms(in: window)
        if accepted {
            preferences.javaDecompilerAgreementAccepted = true
        }
        return accepted
    }

    func presentMetalFailureOnce(reason: String) {
        guard !hasPresentedMetalFailure else { return }
        hasPresentedMetalFailure = true
        var alert = IDEAlert.notice(
            "Metal rendering was disabled", detail: "\(reason)\n\nThe editor has switched to Core Graphics.",
            style: .warning)
        Task { await alert.present(in: window) }
    }
}
