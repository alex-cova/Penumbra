import Foundation
import JSONRPC
import LanguageServerProtocol

/// One piece of server work that reports progress (`$/progress` after `window/workDoneProgress/create`):
/// SourceKit-LSP's background indexing and its "Preparing" steps.
public struct LSPWorkProgress: Sendable, Equatable, Identifiable {
    public var token: String
    public var title: String
    public var message: String?
    /// 0...100 when the server knows the fraction.
    public var percentage: Int?

    public var id: String { token }

    public init(token: String, title: String, message: String? = nil, percentage: Int? = nil) {
        self.token = token
        self.title = title
        self.message = message
        self.percentage = percentage
    }

    /// `Indexing`, `Indexing: 3/10`, `Indexing: 3/10 (30%)`.
    public var summary: String {
        var text = title
        if let message, !message.isEmpty { text += ": \(message)" }
        if let percentage { text += " (\(percentage)%)" }
        return text
    }
}

/// Folds `$/progress` notifications into the list of work that is running now. Pure: the client owns
/// one and calls it from its event loop.
///
/// `begin` starts a token, `report` updates one the tracker knows (a report for an unknown token is
/// dropped, as the spec says nothing may follow `end`), `end` removes it. The list keeps the order
/// the work began in.
struct LSPWorkProgressTracker {
    private(set) var active: [LSPWorkProgress] = []

    /// True when the list the user would see changed.
    mutating func apply(_ params: ProgressParams) -> Bool {
        guard case .hash(let value)? = params.value, case .string(let kind)? = value["kind"] else { return false }
        let token = Self.key(params.token)
        let index = active.firstIndex { $0.token == token }
        switch kind {
        case "begin":
            let work = LSPWorkProgress(
                token: token,
                title: Self.string(value["title"]) ?? "",
                message: Self.string(value["message"]),
                percentage: Self.percentage(value["percentage"])
            )
            if let index {
                guard active[index] != work else { return false }
                active[index] = work
            } else {
                active.append(work)
            }
            return true
        case "report":
            guard let index else { return false }
            var work = active[index]
            if let message = Self.string(value["message"]) { work.message = message }
            if let percentage = Self.percentage(value["percentage"]) { work.percentage = percentage }
            guard work != active[index] else { return false }
            active[index] = work
            return true
        case "end":
            guard let index else { return false }
            active.remove(at: index)
            return true
        default:
            return false
        }
    }

    private static func key(_ token: ProgressToken) -> String {
        switch token {
        case .optionA(let number): return String(number)
        case .optionB(let text): return text
        }
    }

    private static func string(_ value: JSONValue?) -> String? {
        if case .string(let text)? = value { return text }
        return nil
    }

    private static func percentage(_ value: JSONValue?) -> Int? {
        guard case .number(let number)? = value, number.isFinite else { return nil }
        return min(100, max(0, Int(number.rounded())))
    }
}
