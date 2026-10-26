import Foundation
import WebKit

/// What the overlay tells Swift. Decoded from JSON text and checked field by field: the overlay is our own
/// script, but it lives in the page's document, so nothing it sends is taken on trust.
struct IDEAIBrowserMessage: Decodable {
    var t: String
    var element: IDEAIElementInfo?
    var vr: IDEAIElementInfo.Rect?
    var id: String?
    var ids: [String]?
    var url: String?

    static let maximumBytes = 200_000

    static func decode(_ body: Any) -> IDEAIBrowserMessage? {
        guard let text = body as? String, text.utf8.count <= maximumBytes,
              let message = try? JSONDecoder().decode(IDEAIBrowserMessage.self, from: Data(text.utf8))
        else { return nil }
        return message
    }
}

/// Receives the inspector world's messages and hands them to the model. WebKit holds a message handler
/// strongly, so this holds the model weakly and `IDEAIBrowserScripts.remove(from:)` drops it with the window.
@MainActor
final class IDEAIBrowserBridge: NSObject, WKScriptMessageHandler {
    weak var model: IDEAIBrowserModel?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only the top document speaks; a frame inside it is not inspected.
        guard message.frameInfo.isMainFrame, let model, let decoded = IDEAIBrowserMessage.decode(message.body) else { return }
        model.handle(decoded)
    }
}

/// A picked element waiting for its note.
struct IDEAIPendingPick: Identifiable, Equatable {
    let id = UUID()
    var element: IDEAIElementInfo
    /// In the web view's own coordinates, so the note editor can sit next to the element.
    var viewRect: IDEAIElementInfo.Rect
}

/// An existing note being edited, opened from its pin.
struct IDEAIPinEdit: Identifiable, Equatable {
    var id: UUID
    var viewRect: IDEAIElementInfo.Rect
}

extension IDEAIBrowserModel {
    /// The key the notes of the page showing now are filed under.
    var currentPageKey: String? { page.url.map(IDEAIBrowserPageKey.key(for:)) }

    /// Runs a function body in the inspector world (the page cannot see it). Returns the string it returned,
    /// or `nil` when there is no document yet or the call threw.
    @discardableResult
    func inspector(_ body: String, _ arguments: [String: Any] = [:]) async -> String? {
        guard hasStarted else { return nil }
        do {
            return try await page.callJavaScript(body, arguments: arguments, contentWorld: IDEAIBrowserScripts.inspectorWorld) as? String
        } catch {
            return nil
        }
    }

    /// Select mode: the page outlines what the pointer is over, a click picks it instead of reaching the page.
    func setPicking(_ on: Bool) {
        guard !on || hasStarted else { return }
        isPicking = on
        if !on { cancelPick() }
        Task { await inspector("return window.__umbra.setPicking(on)", ["on": on]) }
    }

    /// ↑ parent, ↓ child of the element under the pointer (the page also takes the arrow keys).
    func climb(_ delta: Int) {
        Task { await inspector("return window.__umbra.climb(delta)", ["delta": delta]) }
    }

    /// Pushes this page's notes to the overlay.
    func syncOverlay() {
        let payload = annotations.overlayPayload(forPageKey: currentPageKey)
        Task { await inspector("return window.__umbra.sync(payload)", ["payload": payload]) }
    }

    func revealAnnotation(_ id: UUID) {
        Task { await inspector("return window.__umbra.flash(id)", ["id": id.uuidString]) }
    }

    // MARK: - Messages from the overlay

    func handle(_ message: IDEAIBrowserMessage) {
        switch message.t {
        case "ready":
            // A new document: it starts without pick mode or pins.
            syncOverlay()
            if isPicking { Task { await inspector("return window.__umbra.setPicking(true)") } }
        case "picked":
            guard let element = message.element, let rect = message.vr else { return }
            editingPin = nil
            pendingPick = IDEAIPendingPick(element: element.sanitized(), viewRect: rect)
        case "pin":
            guard let text = message.id, let id = UUID(uuidString: text), annotations.item(id) != nil, let rect = message.vr else { return }
            pendingPick = nil
            editingPin = IDEAIPinEdit(id: id, viewRect: rect)
        case "missing":
            annotations.setMissing(Set((message.ids ?? []).compactMap(UUID.init(uuidString:))))
        case "pickEnded":
            isPicking = false
            pendingPick = nil
        default:
            break
        }
    }

    // MARK: - The note editor

    /// Saves the note for the picked element and pins it.
    func commitPick(note: String) {
        guard let pick = pendingPick, let url = page.url else { return }
        pendingPick = nil
        Task { await inspector("return window.__umbra.clearDraft()") }
        guard let annotation = annotations.add(
            note: note.trimmingCharacters(in: .whitespacesAndNewlines), pageURL: url, pageTitle: page.title, element: pick.element)
        else {
            rejection = "That is as many notes as the page can hold. Delete some first."
            return
        }
        Task { await fetchComponentHint(for: annotation.id, selector: pick.element.selector) }
    }

    func cancelPick() {
        guard pendingPick != nil else { return }
        pendingPick = nil
        Task { await inspector("return window.__umbra.clearDraft()") }
    }

    func saveEdit(_ id: UUID, note: String) {
        annotations.update(id, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
        editingPin = nil
    }

    func deleteAnnotation(_ id: UUID) {
        annotations.remove(id)
        if editingPin?.id == id { editingPin = nil }
    }

    /// The framework component behind an element (React, Vue, Svelte, Angular), read in the page's own world
    /// because the frameworks keep it in properties of the DOM node that an isolated world cannot see.
    /// Best effort; the answer is page data like everything else here.
    func fetchComponentHint(for id: UUID, selector: String) async {
        guard let result = try? await page.callJavaScript(
            IDEAIBrowserScripts.componentHint, arguments: ["selector": selector], contentWorld: .page) as? String,
            !result.isEmpty
        else { return }
        annotations.setComponent(id, IDEAgentOutputScrubber.scrub(result))
    }
}
