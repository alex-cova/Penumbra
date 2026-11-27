import DatabaseKit
import SwiftUI

/// What the user typed for one value, before it becomes a `SQLiteCellValue`. Shared by the cell
/// editor and the new-row sheet.
struct IDEDatabaseValueDraft: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case text = "Text", integer = "Integer", real = "Real", null = "NULL", defaultValue = "Default"
        case currentTimestamp = "CURRENT_TIMESTAMP", currentDate = "CURRENT_DATE", currentTime = "CURRENT_TIME"
        var id: Self { self }
    }

    enum Resolved: Equatable {
        case set(SQLiteCellValue)
        /// An insert leaves the column out and SQLite fills it.
        case omit
        case invalid(String)
    }

    var kind: Kind
    var text: String

    init(kind: Kind = .text, text: String = "") {
        self.kind = kind
        self.text = text
    }

    init(_ cell: SQLiteCellValue) {
        switch cell {
        case .value(let value):
            switch value {
            case .int: kind = .integer
            case .double: kind = .real
            case .null: kind = .null
            default: kind = .text
            }
            text = value.rawText ?? ""
        case .expression(let expression):
            text = ""
            switch expression {
            case .currentTimestamp: kind = .currentTimestamp
            case .currentDate: kind = .currentDate
            case .currentTime: kind = .currentTime
            case .columnDefault: kind = .defaultValue
            }
        }
    }

    func resolve(column: String, defaultExpression: String?, insert: Bool) -> Resolved {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .text: return .set(.value(.text(text)))
        case .integer:
            return Int64(trimmed).map { .set(.value(.int($0))) } ?? .invalid("\(column) needs a whole number.")
        case .real:
            return Double(trimmed).flatMap { $0.isFinite ? Resolved.set(.value(.double($0))) : nil }
                ?? .invalid("\(column) needs a finite number.")
        case .null: return .set(.value(.null))
        case .defaultValue:
            if insert { return .omit }
            guard let defaultExpression else { return .invalid("\(column) has no default.") }
            return .set(.expression(.columnDefault(defaultExpression)))
        case .currentTimestamp: return .set(.expression(.currentTimestamp))
        case .currentDate: return .set(.expression(.currentDate))
        case .currentTime: return .set(.expression(.currentTime))
        }
    }
}

/// A kind picker and, for a typed kind, its text field.
struct IDEDatabaseValueField: View {
    let name: String
    var typeName = ""
    let allowsNull: Bool
    let allowsDefault: Bool
    /// The clock functions; only SQLite offers them.
    var allowsClock = true
    @Binding var draft: IDEDatabaseValueDraft

    private var kinds: [IDEDatabaseValueDraft.Kind] {
        IDEDatabaseValueDraft.Kind.allCases.filter {
            ($0 != .null || allowsNull) && ($0 != .defaultValue || allowsDefault)
                && (allowsClock || ![.currentTimestamp, .currentDate, .currentTime].contains($0))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(.callout.weight(.medium))
                if !typeName.isEmpty { Text(typeName).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Picker("Value Type", selection: $draft.kind) {
                    ForEach(kinds) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("\(name) value type")
            }
            if [.text, .integer, .real].contains(draft.kind) {
                TextField(name, text: $draft.text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .accessibilityLabel("\(name) value")
            }
        }
    }
}
