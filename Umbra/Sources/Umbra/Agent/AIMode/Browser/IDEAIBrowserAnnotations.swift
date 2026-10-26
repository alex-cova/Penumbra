import Foundation
import Observation

/// What the picker captured about one element of the page. Everything here came from the page, so it is
/// data: capped, scrubbed of credential-shaped text, and only ever shown to the model as untrusted.
struct IDEAIElementInfo: Codable, Equatable, Sendable {
    struct Rect: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
        var w: Double
        var h: Double
    }

    /// A unique CSS path; ` >>> ` separates the steps through an open shadow root.
    var selector: String
    var tag: String
    var id: String?
    var classes: [String]
    var role: String?
    /// The accessible name: `aria-label`, label text, alt text or the visible text of a button or link.
    var label: String?
    var text: String
    /// `outerHTML` without input values, script bodies or event-handler attributes, cut at 1,500 characters.
    var html: String
    /// Page coordinates (scroll included).
    var rect: Rect
    var styles: [String: String]
    var ancestors: [String]
    /// How many input values were removed from `html`.
    var redactions: Int
    /// A framework component name and source file when the page exposes one (React, Vue, Svelte, Angular).
    var component: String?

    /// `button.primary`, for a chip or a label.
    var shortName: String {
        var name = tag
        if let id, !id.isEmpty { name += "#" + id } else if let first = classes.first { name += "." + first }
        return name
    }

    /// Caps and credential scrubbing for what arrives from the page, whatever the page sent.
    func sanitized() -> IDEAIElementInfo {
        var copy = self
        copy.selector = String(selector.prefix(2_000))
        copy.tag = String(tag.prefix(60))
        copy.id = id.map { String($0.prefix(200)) }
        copy.classes = classes.prefix(20).map { String($0.prefix(100)) }
        copy.role = role.map { String($0.prefix(60)) }
        copy.label = label.map { IDEAgentOutputScrubber.scrub(String($0.prefix(200))) }
        copy.text = IDEAgentOutputScrubber.scrub(String(text.prefix(300)))
        copy.html = IDEAgentOutputScrubber.scrub(String(html.prefix(2_000)))
        copy.styles = Dictionary(uniqueKeysWithValues: styles.prefix(40).map { (String($0.key.prefix(60)), String($0.value.prefix(160))) })
        copy.ancestors = ancestors.prefix(8).map { String($0.prefix(160)) }
        copy.redactions = max(0, redactions)
        copy.component = component.map { String($0.prefix(300)) }
        return copy
    }
}

/// A note on one element of the page, written by the user (or pinned by the agent).
struct IDEAIAnnotation: Identifiable, Equatable, Sendable {
    enum Author: String, Sendable { case user, agent }
    /// `open` has not gone to the agent; `sent` went with a message; `addressed` the agent said it dealt with it.
    enum Status: String, Sendable { case open, sent, addressed }

    let id: UUID
    var number: Int
    var note: String
    var author: Author
    var status: Status
    var pageURL: URL
    var pageTitle: String
    var element: IDEAIElementInfo
    /// The agent's answer when it marked the note addressed.
    var reply: String?
    var createdAt: Date

    var pageKey: String { IDEAIBrowserPageKey.key(for: pageURL) }

    /// One line for a chip: the note, else what the element is.
    var summary: String {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return String(text.split(separator: "\n").first.map(String.init) ?? text) }
        return element.label.flatMap { $0.isEmpty ? nil : $0 } ?? element.shortName
    }
}

enum IDEAIBrowserPageKey {
    /// `scheme://host:port/path` without query or fragment, so a note stays with its page across `?tab=2`
    /// and `#section` but not across routes.
    static func key(for url: URL) -> String {
        var key = (url.scheme ?? "") + "://" + (url.host ?? "").lowercased()
        if let port = url.port { key += ":\(port)" }
        var path = url.path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return key + (path.isEmpty ? "/" : path)
    }
}

/// The page's notes for one window. Native is the source of truth: the page's overlay asks for the notes
/// of its URL on every load, so they survive navigation and hot reload. Held in memory; not saved with the
/// window.
@MainActor @Observable
final class IDEAIBrowserAnnotations {
    /// At most this many notes; more than a person writes by hand.
    static let maximumCount = 100
    static let maximumNoteLength = 2_000

    private(set) var items: [IDEAIAnnotation] = []
    /// Notes whose element the overlay could not find on the current page.
    private(set) var missing: Set<UUID> = []
    private var nextNumber = 1
    /// Called after every change, so the bridge can push the notes to the overlay.
    @ObservationIgnored var onChange: (() -> Void)?

    var isEmpty: Bool { items.isEmpty }
    var openItems: [IDEAIAnnotation] { items.filter { $0.status == .open } }
    /// Open notes the user wrote: what goes to the agent with the next message. A note the agent pinned is its own.
    var userOpenItems: [IDEAIAnnotation] { items.filter { $0.status == .open && $0.author == .user } }

    func item(_ id: UUID) -> IDEAIAnnotation? { items.first { $0.id == id } }

    @discardableResult
    func add(
        note: String, author: IDEAIAnnotation.Author = .user, pageURL: URL, pageTitle: String, element: IDEAIElementInfo
    ) -> IDEAIAnnotation? {
        guard items.count < Self.maximumCount else { return nil }
        let annotation = IDEAIAnnotation(
            id: UUID(), number: nextNumber, note: String(note.prefix(Self.maximumNoteLength)), author: author,
            // The agent's own pin is not news to the agent.
            status: author == .agent ? .sent : .open, pageURL: pageURL, pageTitle: String(pageTitle.prefix(200)), element: element.sanitized(),
            reply: nil, createdAt: Date())
        nextNumber += 1
        items.append(annotation)
        onChange?()
        return annotation
    }

    func update(_ id: UUID, note: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].note = String(note.prefix(Self.maximumNoteLength))
        // Edited after it was sent: it is news again.
        if items[index].status == .sent { items[index].status = .open }
        onChange?()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        missing.remove(id)
        onChange?()
    }

    func clear() {
        items.removeAll()
        missing.removeAll()
        nextNumber = 1
        onChange?()
    }

    func markSent(_ ids: [UUID]) {
        for index in items.indices where ids.contains(items[index].id) && items[index].status == .open {
            items[index].status = .sent
        }
        onChange?()
    }

    /// The agent says these are dealt with, optionally with a reply.
    @discardableResult
    func resolve(_ ids: [UUID], reply: String?) -> Int {
        var count = 0
        for index in items.indices where ids.contains(items[index].id) {
            items[index].status = .addressed
            if let reply, !reply.isEmpty { items[index].reply = String(reply.prefix(500)) }
            count += 1
        }
        if count > 0 { onChange?() }
        return count
    }

    func setComponent(_ id: UUID, _ component: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].element.component = String(component.prefix(300))
    }

    func setMissing(_ ids: Set<UUID>) {
        guard ids != missing else { return }
        missing = ids
    }

    /// The notes for the overlay of `pageKey`, as the JSON its `sync` reads.
    func overlayPayload(forPageKey pageKey: String?) -> String {
        struct Row: Encodable {
            var id: String
            var number: Int
            var note: String
            var author: String
            var status: String
            var selector: String
            var tag: String
            var text: String
        }
        let rows = items.filter { pageKey == nil || $0.pageKey == pageKey }.map {
            Row(id: $0.id.uuidString, number: $0.number, note: $0.note, author: $0.author.rawValue,
                status: $0.status.rawValue, selector: $0.element.selector, tag: $0.element.tag, text: String($0.element.text.prefix(80)))
        }
        guard let data = try? JSONEncoder().encode(rows) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}
