import AgentKit
import Foundation

/// Which chat is changing which file right now, so two chats running at once do not edit the same
/// file unawares. A chat claims the files of an edit when it is about to make it, and keeps the claim
/// until its run ends. An edit to a file another chat's run holds asks first.
@MainActor
final class IDEAgentFileClaims {
    struct Holder: Equatable {
        let tab: UUID
        let title: String
    }

    private var holders: [String: Holder] = [:]

    /// `./src/../src/A.java` and `src/A.java` are one file. (`standardizingPath` leaves `..` alone in a
    /// relative path, so the components are resolved here.)
    nonisolated static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": if parts.last.map({ $0 != ".." }) == true { parts.removeLast() } else { parts.append(component) }
            default: parts.append(component)
            }
        }
        return (path.hasPrefix("/") ? "/" : "") + parts.joined(separator: "/")
    }

    /// The other chat holding any of `paths`, if there is one. Otherwise they are all claimed for `tab`.
    func claim(_ paths: [String], for tab: UUID, title: String) -> Holder? {
        let normalized = paths.map(Self.normalize)
        if let other = normalized.lazy.compactMap({ self.holders[$0] }).first(where: { $0.tab != tab }) { return other }
        for path in normalized { holders[path] = Holder(tab: tab, title: title) }
        return nil
    }

    func holder(of path: String) -> Holder? { holders[Self.normalize(path)] }

    /// A chat's run ended (or the chat was closed): its files are free.
    func release(tab: UUID) {
        holders = holders.filter { $0.value.tab != tab }
    }

    var claimedPaths: [String] { holders.keys.sorted() }
}

/// The claims, as the permission policy sees them: an edit to a file another chat holds asks.
struct IDEAgentClaimsGate: PermissionGate {
    let claims: IDEAgentFileClaims
    let tab: UUID
    let title: @MainActor () -> String

    func verdict(for call: ToolCallInfo) async -> PermissionVerdict? {
        guard call.risk == .edit, case .paths(let paths) = call.subject, !paths.isEmpty else { return nil }
        return await MainActor.run {
            guard let other = claims.claim(paths, for: tab, title: title()) else { return nil }
            return .ask(notes: ["Chat “\(other.title)” is changing this file in its current run."])
        }
    }
}
