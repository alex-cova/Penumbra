import AgentKit
import Foundation
import Observation
import WebKit

/// What the Browser tab accepts in its address field, and which local servers a chat's output mentions.
/// Pure, so it is tested without a web view.
enum IDEAIBrowserAddress {
    enum Result: Equatable {
        case url(URL)
        case rejected(String)
    }

    /// `localhost:3000` and other local hosts get `http://`, a host with a dot gets `https://`, and only
    /// `http`, `https` and `about:blank` are ever opened (never `file:`, `javascript:` or another app's scheme).
    static func normalize(_ text: String) -> Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected("Enter an address, such as localhost:3000.") }
        if trimmed.lowercased() == "about:blank" { return .url(URL(string: "about:blank")!) }
        guard !trimmed.contains(where: \.isWhitespace) else {
            return .rejected("Enter a web address, such as localhost:3000.")
        }

        // A scheme without slashes (`javascript:`, `mailto:`) is still a scheme, not a host with a port.
        let lower = trimmed.lowercased()
        let otherSchemes = ["javascript:", "data:", "file:", "vbscript:", "blob:", "mailto:", "tel:", "sms:", "ftp:", "ssh:", "view-source:"]
        if otherSchemes.contains(where: lower.hasPrefix) { return .rejected("Only http and https addresses can be opened here.") }

        if let range = trimmed.range(of: "://") {
            let scheme = trimmed[..<range.lowerBound].lowercased()
            guard scheme == "http" || scheme == "https" else {
                return .rejected("Only http and https addresses can be opened here.")
            }
            guard let url = URL(string: trimmed), url.host?.isEmpty == false else {
                return .rejected("That is not a valid address.")
            }
            return .url(url)
        }

        // The host is what comes before the first path, query or fragment, without a port.
        let authority = trimmed.prefix { !"/?#".contains($0) }
        let host = hostName(of: String(authority))
        guard !host.isEmpty else { return .rejected("That is not a valid address.") }
        let scheme = isLocal(host) ? "http" : "https"
        guard host.contains(".") || isLocal(host) || host.hasPrefix("["),
              let url = URL(string: "\(scheme)://\(trimmed)"), url.host?.isEmpty == false
        else { return .rejected("“\(trimmed)” does not look like an address. Try localhost:3000 or example.com.") }
        return .url(url)
    }

    private static func hostName(of authority: String) -> String {
        let withoutUser = authority.split(separator: "@").last.map(String.init) ?? authority
        if withoutUser.hasPrefix("["), let close = withoutUser.firstIndex(of: "]") {
            return String(withoutUser[...close]).lowercased()
        }
        return String(withoutUser.prefix { $0 != ":" }).lowercased()
    }

    private static func isLocal(_ host: String) -> Bool {
        host == "localhost" || host == "[::1]" || host == "0.0.0.0" || host.hasSuffix(".local") || host.hasSuffix(".localhost")
            || host.hasPrefix("127.") || host.hasPrefix("192.168.") || host.hasPrefix("10.")
    }

    // MARK: - Servers the chat started

    private static let serverPattern = try? NSRegularExpression(
        pattern: #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]):\d{2,5}(?:/[^\s"'<>)\]]*)?"#)

    /// Addresses of local servers named in the chat's tool output (a dev server's "ready on http://localhost:3000"),
    /// newest first, `0.0.0.0` shown as `localhost`, at most `limit`.
    static func localServers(in entries: [IDEAgentEntry], limit: Int = 5) -> [URL] {
        var found: [URL] = []
        var seen = Set<String>()
        for entry in entries.suffix(60).reversed() {
            guard case .toolCall = entry.kind else { continue }
            let text = entry.liveOutput.isEmpty ? (entry.output?.text ?? "") : entry.liveOutput
            // A chatty build can hold a lot of output; the start of a server's log is where it says where it listens.
            let sample = text.count > 200_000 ? String(text.prefix(200_000)) : text
            let nsText = sample as NSString
            let matches = serverPattern?.matches(in: sample, range: NSRange(location: 0, length: nsText.length)) ?? []
            for match in matches.reversed() {
                var raw = nsText.substring(with: match.range)
                while let last = raw.last, ".,;:".contains(last) { raw.removeLast() }
                raw = raw.replacingOccurrences(of: "0.0.0.0", with: "localhost")
                guard let url = URL(string: raw), seen.insert(url.absoluteString).inserted else { continue }
                found.append(url)
                if found.count == limit { return found }
            }
        }
        return found
    }
}

/// Lets a page navigate to the web and nothing else: a link to another app's scheme, `file:` or
/// `javascript:` is cancelled rather than handed to the system.
struct IDEAIBrowserNavigationPolicy: WebPage.NavigationDeciding {
    static func allows(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return ["http", "https", "about", "blob", "data"].contains(scheme)
    }

    @MainActor
    func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        Self.allows(action.request.url) ? .allow : .cancel
    }
}

/// The Browser tab's page: one per window, created when the tab first shows, so switching tabs or chats
/// keeps what was loaded. Nothing loads until the user enters an address or picks a server.
@MainActor @Observable
final class IDEAIBrowserModel {
    let page: WebPage
    /// Set by the first navigation; before it the tab shows its blank state instead of an empty web view.
    private(set) var hasStarted = false
    /// Why the last address was refused.
    var rejection: String?

    /// The user's notes on the page's elements (and the agent's, when it pins its own findings).
    let annotations = IDEAIBrowserAnnotations()
    /// Select mode is on: the page outlines what the pointer is over and a click picks it.
    var isPicking = false
    /// An element just picked, waiting for its note.
    var pendingPick: IDEAIPendingPick?
    /// A note being edited, opened from its pin.
    var editingPin: IDEAIPinEdit?
    /// What the agent is doing to the page right now ("Clicking"), shown over it with a Stop button.
    var agentActivity: String?

    @ObservationIgnored private let controller = WKUserContentController()
    @ObservationIgnored private let bridge = IDEAIBrowserBridge()
    /// The name the page-world recorder hides its reader under, different for every page object.
    @ObservationIgnored let recorderName = "__umbraRec" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    /// The address of the page, readable from any thread: a permission rule is matched on it before a tool runs.
    @ObservationIgnored let pageInfo: IDEAIBrowserPageInfo
    /// Where the console and network listing last stopped, for `since_last`.
    @ObservationIgnored var consoleCursor: Double = 0
    @ObservationIgnored var networkCursor: Double = 0
    @ObservationIgnored private var urlTask: Task<Void, Never>?

    /// `pageInfo` belongs to the window, so a tool can match a rule on the address before this object exists.
    init(pageInfo: IDEAIBrowserPageInfo = IDEAIBrowserPageInfo()) {
        self.pageInfo = pageInfo
        IDEAIBrowserScripts.install(into: controller, handler: bridge, recorderName: recorderName)
        var configuration = WebPage.Configuration()
        configuration.userContentController = controller
        page = WebPage(configuration: configuration, navigationDecider: IDEAIBrowserNavigationPolicy())
        bridge.model = self
        annotations.onChange = { [weak self] in self?.syncOverlay() }
        // Keep `pageInfo` current as the page navigates (a link, a redirect, the address bar, the history).
        let page = page
        let info = pageInfo
        urlTask = Task { @MainActor in
            for await url in Observations({ page.url }) { info.set(url) }
        }
    }

    var canGoBack: Bool { !page.backForwardList.backList.isEmpty }
    var canGoForward: Bool { !page.backForwardList.forwardList.isEmpty }

    /// Opens what the user typed. Returns whether it was accepted.
    @discardableResult
    func go(to text: String) -> Bool {
        switch IDEAIBrowserAddress.normalize(text) {
        case .rejected(let reason):
            rejection = reason
            return false
        case .url(let url):
            open(url)
            return true
        }
    }

    func open(_ url: URL) {
        rejection = nil
        hasStarted = true
        page.load(url)
    }

    /// Loads a page from text and waits for it, for tests: the scripts and the message handler run as for a
    /// page from the network, with no network.
    func load(html: String, baseURL: URL) async {
        rejection = nil
        hasStarted = true
        do { for try await _ in page.load(html: html, baseURL: baseURL) {} } catch {}
    }

    func goBack() {
        guard let item = page.backForwardList.backList.last else { return }
        page.load(item)
    }

    func goForward() {
        guard let item = page.backForwardList.forwardList.first else { return }
        page.load(item)
    }

    func reload() { page.reload() }

    func stop() { page.stopLoading() }

    /// The window is closing: nothing keeps loading or holds the page, and WebKit lets go of the message handler
    /// (it holds one strongly).
    func teardown() {
        page.stopLoading()
        urlTask?.cancel()
        urlTask = nil
        pageInfo.set(nil)
        annotations.onChange = nil
        bridge.model = nil
        IDEAIBrowserScripts.remove(from: controller)
    }
}

/// The page's address as text, safe to read from anywhere. A permission rule is matched against it before a
/// tool runs, and the tool is not on the main actor.
final class IDEAIBrowserPageInfo: @unchecked Sendable {
    private let lock = NSLock()
    private var current: URL?

    func set(_ url: URL?) {
        lock.lock()
        current = url
        lock.unlock()
    }

    var url: URL? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// What a rule such as `browser_inspect(https://app.example.com/*)` is matched against: origin and path,
    /// never the query, fragment or credentials. `nil` while no page is open.
    var subject: String? { url.flatMap(Self.subject(for:)) }

    static func subject(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        let authority = host.contains(":") ? "[\(host)]" : host
        let port = url.port.map { ":\($0)" } ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        return "\(scheme)://\(authority)\(port)\(path)"
    }

    /// `scheme://host[:port]`, for the rule an "Always allow" button adds.
    static func originPattern(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        return "\(scheme)://\(host.contains(":") ? "[\(host)]" : host)\(url.port.map { ":\($0)" } ?? "")"
    }

    /// `localhost`, `127.0.0.1` and `[::1]`: this Mac's own dev servers.
    static func isLoopback(_ url: URL?) -> Bool {
        guard let host = url?.host(percentEncoded: false)?.lowercased() else { return false }
        return host == "localhost" || host == "::1" || host.hasPrefix("127.") || host.hasSuffix(".localhost")
    }
}
