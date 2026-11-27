import DatabaseKit
import Foundation

struct IDEDatabaseParameterInput: Equatable, Sendable {
    enum Kind: String, CaseIterable, Identifiable {
        case text = "Text"
        case integer = "Integer"
        case floatingPoint = "Float"
        case boolean = "Boolean"
        case null = "NULL"

        var id: Self { self }
    }

    var kind = Kind.text
    var text = ""

    var value: DatabaseValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .text: return .text(text)
        case .integer: return Int64(trimmed).map(DatabaseValue.int)
        case .floatingPoint:
            guard let value = Double(trimmed), value.isFinite else { return nil }
            return .double(value)
        case .boolean:
            switch trimmed.lowercased() {
            case "true", "1": return .bool(true)
            case "false", "0": return .bool(false)
            default: return nil
            }
        case .null: return .null
        }
    }
}
