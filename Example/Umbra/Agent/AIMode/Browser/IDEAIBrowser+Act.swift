import Foundation
import WebKit

/// What the agent can do to the Browser tab's page. These are the only verbs: no text is ever evaluated as
/// code. Each runs as DOM events on an element found by ref or selector, or as a navigation the tab's own
/// policy checks.
enum IDEAIBrowserAction: Equatable {
    case navigate(URL)
    case back
    case forward
    case reload
    case click(target: String)
    case type(target: String, text: String, submit: Bool, clear: Bool)
    case select(target: String, value: String)
    case press(target: String?, key: String)
    case scroll(target: String?, direction: String, amount: Int?)
    case wait(text: String?, milliseconds: Int)

    /// What the banner over the page says while it runs.
    var activity: String {
        switch self {
        case .navigate(let url): "Opening \(url.host(percentEncoded: false) ?? url.absoluteString)"
        case .back: "Going back"
        case .forward: "Going forward"
        case .reload: "Reloading"
        case .click: "Clicking"
        case .type: "Typing"
        case .select: "Choosing an option"
        case .press(_, let key): "Pressing \(key)"
        case .scroll: "Scrolling"
        case .wait: "Waiting"
        }
    }

    /// `wait` is bounded: the tool never holds the page for longer than this.
    static let maximumWait = 10_000
}

extension IDEAIBrowserModel {
    /// Runs one action and, unless told not to, describes what the page looks like afterwards (a short outline),
    /// so the agent sees the effect without another call.
    func perform(_ action: IDEAIBrowserAction, includeSnapshot: Bool) async throws -> String {
        setPicking(false)
        agentActivity = action.activity
        defer { agentActivity = nil }
        var message: String

        switch action {
        case .navigate(let url):
            guard IDEAIBrowserNavigationPolicy.allows(url), url.user == nil, url.password == nil else {
                throw ReadFailure("Only http and https addresses without a username or password can be opened.")
            }
            // `self.`: a bare `open(` at the start of a statement reads as the `open` modifier to Umbra's own Swift grammar.
            self.open(url)
            await settle()
            message = "Opened \(page.url?.absoluteString ?? url.absoluteString)."
        case .back:
            guard canGoBack else { throw ReadFailure("There is no earlier page.") }
            goBack()
            await settle()
            message = "Went back to \(page.url?.absoluteString ?? "the previous page")."
        case .forward:
            guard canGoForward else { throw ReadFailure("There is no later page.") }
            goForward()
            await settle()
            message = "Went forward to \(page.url?.absoluteString ?? "the next page")."
        case .reload:
            guard hasStarted else { throw ReadFailure("No page is open in the Browser tab.") }
            reload()
            await settle()
            message = "Reloaded \(page.url?.absoluteString ?? "the page")."
        case .click(let target):
            message = try await act("click(target)", ["target": target])
            await settle()
        case .type(let target, let text, let submit, let clear):
            message = try await act("type(target, text, submit, clear)", ["target": target, "text": text, "submit": submit, "clear": clear])
            await settle()
        case .select(let target, let value):
            message = try await act("select(target, value)", ["target": target, "value": value])
            await settle()
        case .press(let target, let key):
            message = try await act("press(target, key)", ["target": target ?? "", "key": key])
            await settle()
        case .scroll(let target, let direction, let amount):
            message = try await act("scroll(target, direction, amount)", ["target": target ?? "", "direction": direction, "amount": amount ?? 0])
        case .wait(let text, let milliseconds):
            message = await wait(for: text, milliseconds: min(max(milliseconds, 0), IDEAIBrowserAction.maximumWait))
        }

        guard includeSnapshot, hasStarted else { return message }
        if let outline = try? await readSnapshot(selector: nil, asText: false, maxNodes: 150, maxChars: 6_000) {
            message += "\n\n" + outline
        }
        return message
    }

    private func act(_ call: String, _ arguments: [String: Any]) async throws -> String {
        let object = try await readerJSON("act." + call, arguments)
        return IDEAgentOutputScrubber.scrub(object["message"] as? String ?? "Done.")
    }

    /// A moment for the page to react, then until it has stopped loading.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(300))
        await waitUntilLoaded(timeout: 8)
    }

    private func wait(for text: String?, milliseconds: Int) async -> String {
        guard let text, !text.isEmpty else {
            try? await Task.sleep(for: .milliseconds(milliseconds))
            return "Waited \(milliseconds) ms."
        }
        let wanted = text.lowercased()
        let deadline = Date().addingTimeInterval(Double(milliseconds) / 1000)
        while true {
            let object = try? await readerJSON("act.text()")
            if let shown = object?["text"] as? String, shown.lowercased().contains(wanted) { return "The text appeared." }
            if Date() >= deadline { return "The text did not appear within \(milliseconds) ms." }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// `button "Save"`, for the approval card: what a ref or selector points at right now. `nil` when it points at nothing.
    func describeTarget(_ target: String) async -> String? {
        guard let object = try? await readerJSON("inspect(target)", ["target": target]),
              let element = object["element"] as? [String: Any]
        else { return nil }
        let role = (element["role"] as? String) ?? (element["tag"] as? String) ?? "element"
        let name = (element["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (element["text"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(60)) }
        return IDEAgentOutputScrubber.scrub(name.map { "\(role) “\($0)”" } ?? role)
    }
}
