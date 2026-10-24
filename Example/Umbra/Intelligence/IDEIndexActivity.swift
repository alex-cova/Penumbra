import Foundation

/// An index a window builds in the background, as the agent's name search needs to tell it apart.
/// The user-facing progress toast (`IDEProjectStatus`) is shared by every project system and carries
/// errors too, so it cannot say which index is building.
enum IDEIndexKind: String, CaseIterable, Sendable {
    /// Java project sources (stubs and the open-buffer overlay): what name search reads.
    case javaSources
    /// Java dependency jars: needed to resolve types, so usages and implementations depend on it.
    case javaDependencies
    /// The Java identifier index that Find Usages and implementations start from.
    case javaUsages
    case swift
    case typeScript

    var label: String {
        switch self {
        case .javaSources: "Java project sources"
        case .javaDependencies: "Java dependencies"
        case .javaUsages: "the Java usage index"
        case .swift: "Swift symbols"
        case .typeScript: "TypeScript symbols"
        }
    }
}

/// Which indexes are building right now, written by the language supports and read by the agent.
///
/// A build calls ``begin(_:)`` on the main actor *before* its task starts (so the gap between a
/// project change and the first line of the walk is covered) and ``end(_:)`` in a `defer` inside
/// that task. Tokens are counted, so a superseded build that ends late cannot report a kind ready
/// while its replacement is still running.
@MainActor
final class IDEIndexActivity {
    struct Token: Hashable, Sendable {
        fileprivate let id: Int
        let kind: IDEIndexKind
    }

    private var open: [Int: IDEIndexKind] = [:]
    private var next = 0

    func begin(_ kind: IDEIndexKind) -> Token {
        next += 1
        open[next] = kind
        return Token(id: next, kind: kind)
    }

    /// Safe to call twice.
    func end(_ token: Token) {
        open[token.id] = nil
    }

    var active: Set<IDEIndexKind> { Set(open.values) }

    func isActive(_ kind: IDEIndexKind) -> Bool { open.values.contains(kind) }
}
