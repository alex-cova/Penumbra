import Foundation

/// A statement and its driver-native placeholders. Values are provided separately to the driver.
public struct SQLParameterPlan: Equatable, Sendable {
    public let sql: String
    public let labels: [String]
    /// Bind positions in wire order, indexing the values supplied for `labels`.
    public let bindingOrder: [Int]
    private let replacements: [Replacement]

    private struct Replacement: Equatable, Sendable {
        let source: NSRange
        let length: Int
    }

    public init(_ statement: String, dialect: SQLDialect) {
        let source = statement as NSString
        let sql = NSMutableString(string: statement)
        var labels: [String] = []
        var positions: [String: Int] = [:]
        var bindingOrder: [Int] = []
        var replacements: [(NSRange, String)] = []
        for token in SQLLexer(statement, dialect: dialect).tokenize() where token.kind == .parameter {
            let spelling = source.substring(with: token.range)
            guard let prefix = spelling.first else { continue }
            switch prefix {
            case ":": break
            case "$" where dialect != .mysql: break
            case "?" where dialect != .postgres: break
            case "@" where dialect == .sqlite: break
            default: continue
            }
            let position: Int
            if spelling != "?", let existing = positions[spelling] {
                position = existing
            } else {
                position = labels.count
                labels.append(spelling == "?" ? "Parameter \(position + 1)" : spelling)
                if spelling != "?" { positions[spelling] = position }
            }
            if dialect == .postgres {
                if position == bindingOrder.count { bindingOrder.append(position) }
                replacements.append((token.range, "$\(position + 1)"))
            } else {
                bindingOrder.append(position)
                replacements.append((token.range, "?"))
            }
        }
        for (range, replacement) in replacements.reversed() {
            sql.replaceCharacters(in: range, with: replacement)
        }
        self.sql = sql as String
        self.labels = labels
        self.bindingOrder = bindingOrder
        self.replacements = replacements.map { Replacement(source: $0.0, length: $0.1.utf16.count) }
    }

    /// Maps a driver position to the full original placeholder or a point between source units.
    public func sourceRange(at position: Int) -> NSRange? {
        guard position > 0,
              let index = sql.unicodeScalars.index(sql.unicodeScalars.startIndex, offsetBy: position - 1,
                                                   limitedBy: sql.unicodeScalars.endIndex) else { return nil }
        let offset = String(sql.unicodeScalars[..<index]).utf16.count
        var delta = 0
        for replacement in replacements {
            let start = replacement.source.location + delta
            if offset < start { break }
            if offset < start + replacement.length { return replacement.source }
            delta += replacement.length - replacement.source.length
        }
        return NSRange(location: offset - delta, length: 0)
    }
}
