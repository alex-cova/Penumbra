import DatabaseKit
import EditorIntelligence
import SwiftUI

enum IDEDatabasePresentationMode: String, CaseIterable, Identifiable, Sendable {
    case table = "Table", records = "Records", transposed = "Transposed", tree = "Tree", text = "Text"
    var id: Self { self }

    var rowLimit: Int { self == .transposed ? 18 : 100 }
}

struct IDEDatabaseStoredPresentation: View {
    private struct Field: Identifiable, Sendable {
        let id: Int
        let name: String
        let value: String
        let children: [Field]?
    }

    let storage: IDEDatabaseResultStorage
    let mode: IDEDatabasePresentationMode
    let availableRows: Int
    let onRow: (Int) -> Void
    @State private var rows: [[Field]]?
    @State private var error: String?

    private static let columnLimit = 48

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let rows {
                Text("First \(rows.count.formatted()) of \(availableRows.formatted()) loaded rows · up to \(Self.columnLimit) columns")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(IDEAppearance.Spacing.sm)
                content(rows)
            } else if let error {
                ContentUnavailableView("Preview Unavailable", systemImage: "exclamationmark.circle", description: Text(error))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: Refresh(storage: storage, mode: mode, loaded: min(availableRows, mode.rowLimit))) {
            let count = min(availableRows, mode.rowLimit)
            let storage = storage
            let mode = mode
            do {
                let loaded = try await runDetached { try await Self.load(storage: storage, count: count, mode: mode) }
                guard !Task.isCancelled else { return }
                rows = loaded
                error = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    @ViewBuilder private func content(_ rows: [[Field]]) -> some View {
        switch mode {
        case .records:
            List {
                ForEach(rows.indices, id: \.self) { index in
                    Section {
                        ForEach(rows[index]) { field in
                            LabeledContent(field.name, value: field.value).textSelection(.enabled).lineLimit(3)
                        }
                    } header: {
                        Button("Row \(index + 1)", systemImage: "tablecells") { onRow(index) }.buttonStyle(.plain)
                    }
                }
            }
        case .tree:
            List {
                ForEach(rows.indices, id: \.self) { row in
                    DisclosureGroup("Row \(row + 1)") {
                        OutlineGroup(rows[row], children: \.children) { field in
                            LabeledContent(field.name, value: field.value).textSelection(.enabled).lineLimit(3)
                        }
                    }
                }
            }
        case .transposed:
            if let fields = rows.first {
                ScrollView([.horizontal, .vertical]) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow {
                            Text("Column").font(.headline)
                            ForEach(rows.indices, id: \.self) { row in
                                Button("Row \(row + 1)") { onRow(row) }.buttonStyle(.plain)
                            }
                        }
                        Divider()
                        ForEach(fields) { field in
                            GridRow {
                                Text(field.name).fontWeight(.medium)
                                ForEach(rows.indices, id: \.self) { row in
                                    Text(rows[row][field.id].value).lineLimit(2).frame(idealWidth: 120, alignment: .leading)
                                }
                            }
                        }
                    }
                    .font(.caption).textSelection(.enabled)
                    .padding(IDEAppearance.Spacing.sm)
                }
            }
        case .text:
            let header = rows.first?.map(\.name).joined(separator: "\t") ?? ""
            let body = rows.map { $0.map(\.value).joined(separator: "\t") }.joined(separator: "\n")
            ScrollView([.horizontal, .vertical]) {
                Text(header + "\n" + body).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .padding(IDEAppearance.Spacing.sm)
            }
        case .table:
            EmptyView()
        }
    }

    private static func load(
        storage: IDEDatabaseResultStorage, count: Int, mode: IDEDatabasePresentationMode
    ) async throws -> [[Field]] {
        let columns = await storage.store.snapshot.columns.prefix(columnLimit).map(\.name)
        let rows = try await storage.store.mapRows(in: 0..<count) { row in Array(row.prefix(columns.count)) }
        var remainingNodes = 1_200
        return rows.map { row in
            columns.enumerated().map { index, name in
                let value = row.indices.contains(index) ? row[index] : .missing
                if mode == .tree, remainingNodes > 0 {
                    let json: String?
                    switch value {
                    case .json(let text), .bson(_, let text): json = text
                    default: json = nil
                    }
                    if let json, json.utf8.prefix(8_193).count <= 8_192, let document = try? ExtendedJSON.parse(json) {
                        return node(id: index, name: name, value: document, depth: 0, remaining: &remainingNodes)
                    }
                }
                let label: String
                switch value.presence {
                case .null: label = "NULL"
                case .empty: label = "Empty string"
                case .missing: label = "Missing"
                case .unloaded: label = "Unloaded"
                default: label = String((value.displayText() ?? "").prefix(240))
                }
                return Field(id: index, name: name, value: label, children: nil)
            }
        }
    }

    private static func node(id: Int, name: String, value: BSONValue, depth: Int, remaining: inout Int) -> Field {
        remaining -= 1
        let items: [(String, BSONValue)]
        switch value {
        case .document(let document): items = document.fields.map { ($0.key, $0.value) }
        case .array(let values): items = values.enumerated().map { (String($0.offset), $0.element) }
        default: items = []
        }
        if !items.isEmpty, depth < 5, remaining > 0 {
            var fields: [Field] = []
            for (index, item) in items.prefix(60).enumerated() where remaining > 0 {
                fields.append(node(id: index, name: item.0, value: item.1, depth: depth + 1, remaining: &remaining))
            }
            return Field(id: id, name: name, value: "\(items.count.formatted()) items", children: fields)
        }
        return Field(id: id, name: name, value: String(ExtendedJSON.string(value, mode: .relaxed).prefix(240)), children: nil)
    }

    private struct Refresh: Equatable {
        let storage: IDEDatabaseResultStorage
        let mode: IDEDatabasePresentationMode
        let loaded: Int
    }
}
