import Foundation
import LanguageServerProtocol

/// A call-hierarchy or type-hierarchy row. `token` is the server's item, sent back on the
/// incoming, outgoing, supertype and subtype requests.
public struct LSPHierarchySymbol: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case call
        case type
    }

    public var name: String
    public var detail: String?
    public var uri: String
    public var symbolKind: Int
    public var kind: Kind
    public var token: Data

    public init(name: String, detail: String?, uri: String, symbolKind: Int, kind: Kind, token: Data) {
        self.name = name
        self.detail = detail
        self.uri = uri
        self.symbolKind = symbolKind
        self.kind = kind
        self.token = token
    }

    init?(call item: CallHierarchyItem) {
        guard let token = try? JSONEncoder().encode(item) else { return nil }
        self.init(
            name: item.name, detail: item.detail, uri: item.uri, symbolKind: item.kind.rawValue,
            kind: .call, token: token
        )
    }

    init?(type item: TypeHierarchyItem) {
        guard let token = try? JSONEncoder().encode(item) else { return nil }
        self.init(
            name: item.name, detail: item.detail, uri: item.uri, symbolKind: item.kind.rawValue,
            kind: .type, token: token
        )
    }

    var callItem: CallHierarchyItem? {
        guard kind == .call else { return nil }
        return try? JSONDecoder().decode(CallHierarchyItem.self, from: token)
    }

    var typeItem: TypeHierarchyItem? {
        guard kind == .type else { return nil }
        return try? JSONDecoder().decode(TypeHierarchyItem.self, from: token)
    }
}
