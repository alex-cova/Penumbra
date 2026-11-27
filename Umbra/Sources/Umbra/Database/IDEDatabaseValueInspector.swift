import AppKit
import DatabaseKit
import SwiftUI

/// One cell as the inspector shows it. `origin` says where the text came from: the result the
/// grid stored, or a live read of the row that can differ from it.
struct IDEDatabaseInspectedValue: Sendable {
    enum Origin: Equatable, Sendable {
        case stored
        case live(Date)
    }

    let row: Int
    let column: ResultColumn
    let text: String
    let note: String?
    let cell: DatabaseValue
    var origin: Origin = .stored
    /// Which result column the cell is in, so a live read can name it.
    var columnIndex = -1
    /// What the stored result held, kept while a live value is shown so the two can be compared.
    var storedCell: DatabaseValue?

    init(row: Int, column: ResultColumn, cell: DatabaseValue) {
        self.row = row
        self.column = column
        self.cell = cell
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

    /// The same cell, re-read from the database.
    init(live cell: DatabaseValue, replacing stored: IDEDatabaseInspectedValue, at date: Date = Date()) {
        self.init(row: stored.row, column: stored.column, cell: cell)
        columnIndex = stored.columnIndex
        origin = .live(date)
        storedCell = stored.storedCell ?? stored.cell
    }

    /// The stored value is cut (text) or partial (binary), so the rest can be fetched by key.
    var isPartial: Bool {
        switch cell {
        case .truncated: true
        case .bytes(let count, let prefix): prefix.count < count
        default: false
        }
    }

    var isLive: Bool { if case .live = origin { true } else { false } }

    /// A live read that is not what the result stored. Only meaningful when the stored value was
    /// whole; a stored preview cannot be compared with the full text it was cut from.
    var changedSinceQuery: Bool {
        guard isLive, let storedCell else { return false }
        switch storedCell {
        case .truncated, .unloaded: return false
        case .bytes(let count, let prefix): return prefix.count == count && storedCell != cell
        default: return storedCell != cell
        }
    }
}

struct IDEDatabaseValueInspector: View {
    let value: IDEDatabaseInspectedValue
    var canLoadFull = false
    var isLoading = false
    var error: String?
    var onLoadFull: () -> Void = {}
    var onShowStored: () -> Void = {}
    let onClose: () -> Void
    @State private var format: IDEDatabaseValueFormat?

    private var formats: [IDEDatabaseValueFormat] { IDEDatabaseValueFormats.available(for: value.cell) }
    private var selected: IDEDatabaseValueFormat { format.flatMap { formats.contains($0) ? $0 : nil } ?? formats[0] }

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
            provenance
            if formats.count > 1 {
                Picker("View As", selection: Binding(get: { selected }, set: { format = $0 })) {
                    ForEach(formats) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("View value as")
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red) }
            content
        }
        .padding(IDEAppearance.Spacing.sm)
        .background(IDEAppearance.ColorToken.panel)
    }

    /// Where the shown value came from, in words and colour, so a fresh read is never mistaken
    /// for the stored preview the grid still holds.
    @ViewBuilder private var provenance: some View {
        if case .live(let date) = value.origin {
            VStack(alignment: .leading, spacing: 2) {
                Label("Live read at \(date.formatted(date: .omitted, time: .standard))", systemImage: "bolt.horizontal.circle.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                Text(value.changedSinceQuery
                     ? "This value is different from the one the query returned. The grid still shows the stored result."
                     : "Read from the database by the row's key. The grid still shows the stored result.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Show Stored Value", action: onShowStored).font(.caption)
            }
        } else {
            if let note = value.note { Text(note).font(.caption).foregroundStyle(.secondary) }
            if value.isPartial {
                if canLoadFull {
                    Button(isLoading ? "Loading…" : "Load Full Value", systemImage: "arrow.down.circle", action: onLoadFull)
                        .font(.caption).disabled(isLoading)
                        .help("Reads this one value from the database by the row's verified key.")
                } else {
                    Text("This result is not tied to a verified table and key, so the full value cannot be re-read.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if selected == .image, let image = IDEDatabaseValueFormats.image(value.cell) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Image stored in \(value.column.name)")
            }
        } else {
            let rendered = IDEDatabaseValueFormats.render(value.cell, as: selected)
            if let note = rendered.note { Text(note).font(.caption).foregroundStyle(.secondary) }
            ScrollView([.vertical]) {
                Text(rendered.text)
                    .font(IDEAppearance.Typography.monoSmall)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func copyValue() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(IDEDatabaseValueFormats.copyText(value.cell, as: selected), forType: .string)
    }
}
