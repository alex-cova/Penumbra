import AppKit

/// One `NSAlert`, described instead of assembled: a title, some detail, buttons, and optionally a
/// field. The app's confirmations, notices and prompts all go through it so they read and behave alike.
///
/// A blocking call (`runModal`, `confirms`, `promptForText`) is for code that cannot continue without
/// the answer. The `async` ones show a sheet on `window` when there is one and fall back to a modal
/// alert when there is not, so prefer them wherever the caller can wait.
@MainActor
struct IDEAlert {
    struct Button {
        var title: String
        /// Draws the button as destructive (red text on macOS).
        var isDestructive = false
    }

    var title: String
    var detail: String?
    var style: NSAlert.Style = .informational
    var buttons: [Button]
    /// The index of the button that means yes, for `confirms`.
    var confirmIndex = 0
    var accessory: NSView?
    var initialFirstResponder: NSView?
    /// A checkbox under the text ("Remember my choice"); read it back from `suppressionIsChecked`.
    var suppressionTitle: String?
    private(set) var suppressionIsChecked = false

    // MARK: Builders

    /// A yes/no question. A destructive one lists Cancel first so Return answers no.
    static func confirm(
        _ title: String, detail: String? = nil, confirm: String, cancel: String = "Cancel",
        isDestructive: Bool = false, style: NSAlert.Style = .warning
    ) -> IDEAlert {
        if isDestructive {
            return IDEAlert(
                title: title, detail: detail, style: style,
                buttons: [Button(title: cancel), Button(title: confirm, isDestructive: true)], confirmIndex: 1)
        }
        return IDEAlert(title: title, detail: detail, style: style, buttons: [Button(title: confirm), Button(title: cancel)])
    }

    /// Something the user has to know, with one OK button.
    static func notice(_ title: String, detail: String? = nil, style: NSAlert.Style = .informational) -> IDEAlert {
        IDEAlert(title: title, detail: detail, style: style, buttons: [Button(title: "OK")])
    }

    /// Several answers; `run` and `present` return the index of the one chosen.
    static func choice(
        _ title: String, detail: String? = nil, style: NSAlert.Style = .warning, buttons: [Button]
    ) -> IDEAlert {
        IDEAlert(title: title, detail: detail, style: style, buttons: buttons)
    }

    // MARK: Blocking

    /// The index of the clicked button.
    @discardableResult
    mutating func runModal() -> Int {
        if let declined = declineUnderTest() { return declined }
        let alert = makeAlert()
        let response = alert.runModal()
        suppressionIsChecked = alert.suppressionButton?.state == .on
        return Self.index(of: response)
    }

    /// Whether the user chose the confirming button.
    mutating func confirms() -> Bool { runModal() == confirmIndex }

    /// Runs a prompt with one text field and returns what was typed, trimmed, or nil on Cancel.
    static func promptForText(
        _ title: String, detail: String? = nil, initial: String = "", placeholder: String? = nil,
        confirm: String, isMonospaced: Bool = false, width: CGFloat = 280
    ) -> String? {
        var (alert, field) = textPrompt(
            title, detail: detail, initial: initial, placeholder: placeholder, confirm: confirm,
            isMonospaced: isMonospaced, width: width)
        guard alert.runModal() == 0 else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Sheet when there is a window

    /// The index of the clicked button, from a sheet on `window` or a modal alert without one.
    mutating func present(in window: NSWindow?) async -> Int {
        if let declined = declineUnderTest() { return declined }
        let alert = makeAlert()
        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }
        suppressionIsChecked = alert.suppressionButton?.state == .on
        return Self.index(of: response)
    }

    mutating func confirms(in window: NSWindow?) async -> Bool {
        await present(in: window) == confirmIndex
    }

    static func promptForText(
        _ title: String, detail: String? = nil, initial: String = "", placeholder: String? = nil,
        confirm: String, isMonospaced: Bool = false, width: CGFloat = 280, in window: NSWindow?
    ) async -> String? {
        var (alert, field) = textPrompt(
            title, detail: detail, initial: initial, placeholder: placeholder, confirm: confirm,
            isMonospaced: isMonospaced, width: width)
        guard await alert.present(in: window) == 0 else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Internals

    /// XCTest loads this module into the test process. A modal alert there has nobody to click
    /// it, and `runModal` nests a run loop that never returns, so the suite hangs. Decline
    /// instead (the button that is not `confirmIndex`). A real Umbra process is unchanged.
    private func declineUnderTest() -> Int? {
        guard Self.isRunningUnderXCTest else { return nil }
        let line = "IDEAlert declined without a modal under XCTest: \(title)\n"
        FileHandle.standardError.write(Data(line.utf8))
        guard buttons.count > 1 else { return 0 }
        return confirmIndex == 0 ? 1 : 0
    }

    private static var isRunningUnderXCTest: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil {
            return true
        }
        return NSClassFromString("XCTestCase") != nil
    }

    private func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        if let detail { alert.informativeText = detail }
        for button in buttons {
            let added = alert.addButton(withTitle: button.title)
            added.hasDestructiveAction = button.isDestructive
        }
        if let accessory { alert.accessoryView = accessory }
        if let initialFirstResponder { alert.window.initialFirstResponder = initialFirstResponder }
        if let suppressionTitle {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = suppressionTitle
        }
        return alert
    }

    private static func index(of response: NSApplication.ModalResponse) -> Int {
        response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    private static func textPrompt(
        _ title: String, detail: String?, initial: String, placeholder: String?, confirm: String,
        isMonospaced: Bool, width: CGFloat
    ) -> (IDEAlert, NSTextField) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        field.stringValue = initial
        field.placeholderString = placeholder
        if isMonospaced { field.font = .monospacedSystemFont(ofSize: 12, weight: .regular) }
        var alert = IDEAlert(
            title: title, detail: detail, style: .informational,
            buttons: [Button(title: confirm), Button(title: "Cancel")])
        alert.accessory = field
        alert.initialFirstResponder = field
        return (alert, field)
    }
}
