import AppKit
import DatabaseKit
import SwiftUI

struct IDEDatabaseInspectedValue: Sendable {
    let row: Int
    let column: ResultColumn
    let text: String
    let note: String?

    init(row: Int, column: ResultColumn, cell: DatabaseValue) {
        self.row = row
        self.column = column
        let content: (String, String?)
        switch cell {
        case .null: content = ("NULL", nil)
        case .missing: content = ("Missing", nil)
        case .unloaded: content = ("Unloaded", nil)
        case .text(let text) where text.isEmpty: content = ("", "Empty string")
        case .bytes(let count, let prefix):
            let hex = prefix.map { String(format: "%02X", $0) }.joined(separator: " ")
            content = (hex, prefix.count < count ? "First \(prefix.count) of \(count.formatted()) bytes" : "\(count.formatted()) bytes")
        case .truncated(let preview, let count):
            content = (preview, "Preview of a truncated value (\(count.formatted()) total units)")
        case .json(let json), .bson(_, let json):
            content = (IDEJSONText.format(json) ?? json, nil)
        default: content = (cell.rawText ?? "", nil)
        }
        (text, note) = content
    }
}

struct IDEDatabaseValueInspector: View {
    let value: IDEDatabaseInspectedValue
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(value.column.name).font(.headline).lineLimit(1)
                    Text("Row \((value.row + 1).formatted())" + (value.column.typeName.isEmpty ? "" : " · \(value.column.typeName)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                IDEIconButton(systemImage: "document.on.document", help: "Copy Value", action: copyValue)
                IDEIconButton(systemImage: "xmark", help: "Close Value Inspector", action: onClose)
            }
            if let note = value.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(value.text)
                    .font(IDEAppearance.Typography.monoSmall)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(IDEAppearance.Spacing.sm)
        .background(IDEAppearance.ColorToken.panel)
    }

    private func copyValue() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value.text, forType: .string)
    }
}
