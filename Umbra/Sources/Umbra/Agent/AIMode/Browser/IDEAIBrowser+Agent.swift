import Foundation
import WebKit

/// What the agent can read from the Browser tab's page. Every function returns plain text for the model; the
/// tool wraps it as untrusted. Page-derived strings are scrubbed of credential-shaped text here, and input
/// values are never read in the first place.
extension IDEAIBrowserModel {
    struct ReadFailure: LocalizedError {
        var message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static let notReadyMessage = "The page can't be read yet: it is still loading, or it blocks the inspector. Try again in a moment."

    /// Waits (briefly) for the page to stop loading, so a read does not describe half a page.
    func waitUntilLoaded(timeout: Double = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while page.isLoading, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }

    private func requireOpenPage() throws {
        guard hasStarted, page.url != nil else {
            throw ReadFailure("No page is open in the Browser tab. Ask the user to open one, or use browser_act with navigate.")
        }
    }

    func readerJSON(_ call: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        try requireOpenPage()
        await waitUntilLoaded()
        guard let text = await inspector("return window.__umbra." + call, arguments),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { throw ReadFailure(Self.notReadyMessage) }
        if let error = object["error"] as? String { throw ReadFailure(error) }
        return object
    }

    // MARK: - Outline and text

    /// The page as an outline of what is visible, with refs to use in `browser_act`.
    func readSnapshot(selector: String?, asText: Bool, maxNodes: Int = 400, maxChars: Int = 20_000) async throws -> String {
        if asText {
            let object = try await readerJSON("text(selector, limit)", ["selector": selector ?? "", "limit": 12_000])
            var out = header(object)
            let text = IDEAgentOutputScrubber.scrub(object["text"] as? String ?? "")
            out += text.isEmpty ? "(The page shows no text.)" : text
            if object["truncated"] as? Bool == true { out += "\n[… more text not shown; pass a selector to read a part]" }
            return out
        }
        let object = try await readerJSON("snapshot(selector, nodes, chars)", ["selector": selector ?? "", "nodes": maxNodes, "chars": maxChars])
        var out = header(object)
        if let viewport = object["viewport"] as? [String: Any], let w = viewport["w"] as? Int, let h = viewport["h"] as? Int {
            let scroll = object["scrollY"] as? Int ?? 0
            let height = object["height"] as? Int ?? 0
            out += "Viewport \(w)×\(h), scrolled \(scroll) of \(height) px\n\n"
        }
        let outline = IDEAgentOutputScrubber.scrub(object["outline"] as? String ?? "")
        out += outline.isEmpty ? "(Nothing visible yet.)" : outline
        if object["truncated"] as? Bool == true {
            out += "\n[… more elements not shown; pass a selector or a ref to read a part]"
        }
        if object["ready"] as? String == "loading" { out += "\n[The page was still loading when this was read.]" }
        return out
    }

    private func header(_ object: [String: Any]) -> String {
        var out = "Page: \(IDEAgentOutputScrubber.scrub(object["url"] as? String ?? ""))\n"
        if let title = object["title"] as? String, !title.isEmpty {
            out += "Title: \(IDEAgentOutputScrubber.scrub(String(title.prefix(200))))\n"
        }
        return out
    }

    // MARK: - One element

    /// What an element is, where it sits and how it looks. `ref` is from a snapshot; `selector` a CSS path.
    func readElement(target: String) async throws -> String {
        let object = try await readerJSON("inspect(target)", ["target": target])
        guard let info = (object["element"] as? [String: Any]).flatMap({ try? JSONSerialization.data(withJSONObject: $0) })
            .flatMap({ try? JSONDecoder().decode(IDEAIElementInfo.self, from: $0) })?.sanitized()
        else { throw ReadFailure(Self.notReadyMessage) }
        let ref = object["ref"] as? String ?? ""
        var out = "element \(ref): \(info.shortName)\n"
        out += "selector: \(info.selector)\n"
        var facts: [String] = []
        if let role = info.role { facts.append("role: \(role)") }
        if let label = info.label, !label.isEmpty { facts.append("name: \"\(label)\"") }
        facts.append("visible: \(object["visible"] as? Bool == true ? "yes" : "no")")
        facts.append("in viewport: \(object["inViewport"] as? Bool == true ? "yes" : "no")")
        out += facts.joined(separator: " · ") + "\n"
        if let box = object["box"] as? [String: Any] {
            let x = box["x"] as? Int ?? 0, y = box["y"] as? Int ?? 0, w = box["w"] as? Int ?? 0, h = box["h"] as? Int ?? 0
            out += "box: \(x),\(y) \(w)×\(h) (viewport px)\n"
        }
        if !info.text.isEmpty { out += "text: \(info.text)\n" }
        if let attributes = object["attributes"] as? [String: String], !attributes.isEmpty {
            out += "attributes: " + IDEAgentOutputScrubber.scrub(
                attributes.sorted { $0.key < $1.key }.map { "\($0.key)=\"\($0.value)\"" }.joined(separator: " ")) + "\n"
        }
        if !info.styles.isEmpty {
            out += "styles: " + info.styles.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; ") + "\n"
        }
        if !info.ancestors.isEmpty { out += "inside: " + info.ancestors.joined(separator: " < ") + "\n" }
        if let children = object["children"] as? Int { out += "children: \(children)\n" }
        if let component = await componentHint(forSelector: info.selector) { out += "component: \(component)\n" }
        out += "html: \(info.html)"
        if info.redactions > 0 { out += "\n(\(info.redactions) input value\(info.redactions == 1 ? "" : "s") removed)" }
        return out
    }

    /// The framework component behind an element, read in the page's own world; `nil` when there is none.
    func componentHint(forSelector selector: String) async -> String? {
        guard let result = try? await page.callJavaScript(
            IDEAIBrowserScripts.componentHint, arguments: ["selector": selector], contentWorld: .page) as? String,
            !result.isEmpty
        else { return nil }
        return IDEAgentOutputScrubber.scrub(String(result.prefix(300)))
    }

    // MARK: - Console and network (recorded in the page world)

    private struct Entry: Decodable {
        var t: Double
        var level: String?
        var text: String?
        var method: String?
        var url: String?
        var status: Int?
        var error: String?
        var ms: Int?
    }

    private func recorded(_ kind: String) async throws -> [Entry] {
        try requireOpenPage()
        guard let text = try? await page.callJavaScript(
            "var f = window[name]; return f ? f(kind) : ''", arguments: ["name": recorderName, "kind": kind], contentWorld: .page) as? String,
            !text.isEmpty
        else { throw ReadFailure("The recorder is not on this page yet (it was loaded before the Browser tab saw it, or it is still loading). Reload the page and try again.") }
        return (try? JSONDecoder().decode([Entry].self, from: Data(text.utf8))) ?? []
    }

    /// Console output, uncaught errors and unhandled rejections since the page loaded.
    func readConsole(level: String, sinceLast: Bool, limit: Int) async throws -> String {
        var entries = try await recorded("log")
        let total = entries.count
        if sinceLast { entries = entries.filter { $0.t > consoleCursor } }
        if let newest = entries.map(\.t).max() { consoleCursor = max(consoleCursor, newest) }
        let rank = ["debug": 0, "log": 1, "info": 1, "warn": 2, "error": 3]
        let floor = ["all": 0, "warn": 2, "error": 3][level] ?? 0
        entries = entries.filter { (rank[$0.level ?? "log"] ?? 1) >= floor }
        let shown = entries.suffix(max(1, min(limit, 100)))
        guard !shown.isEmpty else {
            return total == 0 ? "The console has nothing since the page loaded." : "Nothing new\(level == "all" ? "" : " at that level")."
        }
        var out = shown.map { "[\($0.level ?? "log")] \(IDEAgentOutputScrubber.scrub($0.text ?? ""))" }.joined(separator: "\n")
        if entries.count > shown.count { out = "[\(entries.count - shown.count) earlier entries not shown]\n" + out }
        return out
    }

    /// Requests that failed or answered 4xx/5xx: method, address without its query, status and time.
    func readNetwork(sinceLast: Bool, limit: Int) async throws -> String {
        var entries = try await recorded("net")
        let total = entries.count
        if sinceLast { entries = entries.filter { $0.t > networkCursor } }
        if let newest = entries.map(\.t).max() { networkCursor = max(networkCursor, newest) }
        let shown = entries.suffix(max(1, min(limit, 100)))
        guard !shown.isEmpty else {
            return total == 0 ? "No request has failed since the page loaded." : "No new failed requests."
        }
        return shown.map { entry in
            let status = (entry.status ?? 0) == 0 ? (entry.error.map { "failed: \(IDEAgentOutputScrubber.scrub($0))" } ?? "failed") : "HTTP \(entry.status ?? 0)"
            return "\(entry.method ?? "GET") \(IDEAgentOutputScrubber.scrub(entry.url ?? "")) → \(status) (\(entry.ms ?? 0) ms)"
        }.joined(separator: "\n")
    }

    // MARK: - The user's notes

    /// The notes as the agent should read them; `resolve` marks some addressed, `reply` goes with them.
    func readAnnotations(resolve numbers: [Int], reply: String?) -> String {
        if !numbers.isEmpty {
            let ids = annotations.items.filter { numbers.contains($0.number) }.map(\.id)
            let count = annotations.resolve(ids, reply: reply)
            if count == 0 { return "None of those note numbers exist. Notes: " + annotations.items.map { String($0.number) }.joined(separator: ", ") }
        }
        let notes = annotations.items
        guard !notes.isEmpty else { return "The Browser tab has no notes." }
        var out = IDEAgentBrowserNotesBlock.make(notes, showStatus: true)
        if !numbers.isEmpty { out = "Marked addressed: \(numbers.map(String.init).joined(separator: ", ")).\n\n" + out }
        return out
    }

    /// The agent pins a note of its own on an element (a finding, a question), shown in purple on the page.
    func annotateElement(target: String, note: String) async throws -> String {
        let object = try await readerJSON("inspect(target)", ["target": target])
        guard let data = (object["element"] as? [String: Any]).flatMap({ try? JSONSerialization.data(withJSONObject: $0) }),
              let info = try? JSONDecoder().decode(IDEAIElementInfo.self, from: data), let url = page.url
        else { throw ReadFailure(Self.notReadyMessage) }
        guard let annotation = annotations.add(note: note, author: .agent, pageURL: url, pageTitle: page.title, element: info) else {
            throw ReadFailure("The page already has as many notes as it can hold.")
        }
        Task { await fetchComponentHint(for: annotation.id, selector: info.selector) }
        return "Pinned note \(annotation.number) on \(info.shortName)."
    }
}
