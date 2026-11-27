import AppKit
import EditorIntelligence
import SwiftUI
import UniformTypeIdentifiers

struct IDEDatabaseChartBuilder: View {
    let source: IDEDatabaseVisualizationSource
    let query: IDEDatabaseChartQuery?
    let runQuery: ((String, IDEDatabaseConsoleBinding) -> Void)?
    let onRow: (Int) -> Void
    @AppStorage("umbra.database.chartSettings") private var saved = Data()
    @State private var settings: IDEDatabaseChartSettings?
    @State private var data: IDEDatabaseChartData?
    @State private var error: String?
    @State private var hover: IDEDatabaseChartData.Point?
    @State private var selected: IDEDatabaseChartData.Point?
    @State private var seriesFilter: String?
    @State private var showsSQL = false
    @State private var generatedSQL: String?

    private struct Preset: Codable {
        var columns: [String]
        var settings: IDEDatabaseChartSettings
    }

    private var presets: [Preset] {
        (try? JSONDecoder().decode([Preset].self, from: saved)) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
            if let settings, let binding = Binding($settings) {
                controls(binding)
                if let data {
                    let visible = data.points.filter { seriesFilter == nil || $0.series == seriesFilter }
                    if visible.isEmpty {
                        ContentUnavailableView("No Plottable Values", systemImage: "chart.xyaxis.line",
                                               description: Text("Change the columns or chart type."))
                    } else {
                        plot(settings, points: visible)
                            .padding(.horizontal, 4)
                    }
                    footer(settings, data: data, points: visible)
                } else if let error {
                    ContentUnavailableView("Chart Unavailable", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if let error {
                ContentUnavailableView("Chart Unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await recommend() }
        .task(id: settings) { await reload(settings) }
    }

    private func controls(_ settings: Binding<IDEDatabaseChartSettings>) -> some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            HStack {
                Picker("Chart Type", selection: settings.kind) {
                    ForEach(IDEDatabaseChartKind.allCases) { Text($0.rawValue).tag($0) }
                }
                columnPicker(settings.wrappedValue.kind == .histogram ? "Value" : "X Axis", selection: settings.x, empty: "Row Number")
                if settings.wrappedValue.kind != .histogram {
                    columnPicker("Measure", selection: settings.y, empty: "None")
                    Picker("Aggregation", selection: settings.aggregate) {
                        ForEach(IDEDatabaseChartAggregate.allCases) { aggregate in
                            Text(aggregate == .none && settings.wrappedValue.requiresAggregate ? "Sum (Required)" : aggregate.rawValue)
                                .tag(aggregate)
                        }
                    }
                }
            }
            if settings.wrappedValue.kind != .histogram {
                HStack {
                    if !settings.wrappedValue.kind.isSector {
                        columnPicker("Group", selection: settings.series, empty: "None")
                    }
                    Picker("Date Granularity", selection: settings.dateUnit) {
                        ForEach(IDEDatabaseChartDateUnit.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if let data, settings.wrappedValue.series != nil {
                        let labels = Array(Set(data.points.map(\.series))).sorted()
                        if labels.count > 1 {
                            Picker("Show Series", selection: $seriesFilter) {
                                Text("All").tag(nil as String?)
                                ForEach(labels, id: \.self) { Text($0).tag(Optional($0)) }
                            }
                            .onChange(of: seriesFilter) { hover = nil; selected = nil }
                        }
                    }
                    Spacer()
                }
            }
            Picker("Number Format", selection: settings.numberFormat) {
                ForEach(IDEDatabaseChartNumberFormat.allCases) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
        }
    }

    private func columnPicker(_ label: String, selection: Binding<Int?>, empty: String) -> some View {
        Picker(label, selection: selection) {
            Text(empty).tag(nil as Int?)
            ForEach(source.columns.indices, id: \.self) { index in Text(source.columns[index]).tag(Optional(index)) }
        }
        .lineLimit(1)
    }

    private func plot(_ settings: IDEDatabaseChartSettings, points: [IDEDatabaseChartData.Point], interactive: Bool = true)
        -> IDEDatabaseChartPlot {
        let aggregate = settings.effectiveAggregate
        return IDEDatabaseChartPlot(
            settings: settings, points: points,
            xTitle: name(settings.x) ?? "Row Number",
            yTitle: settings.kind == .histogram ? "Frequency" : (aggregate == .none ? name(settings.y) ?? "Value" : aggregate.rawValue),
            onHover: interactive ? { hover = $0 } : nil,
            onSelect: interactive ? { selected = $0 } : nil
        )
    }

    private func footer(
        _ settings: IDEDatabaseChartSettings, data: IDEDatabaseChartData, points: [IDEDatabaseChartData.Point]
    ) -> some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            HStack {
                Text(source.scope(sampleCount: data.sampledRows))
                    .foregroundStyle(.secondary)
                if settings.kind != .histogram, settings.effectiveAggregate != .none {
                    Text("Aggregated locally").foregroundStyle(.secondary)
                }
                if data.omittedRows > 0 {
                    Text("\(data.omittedRows.formatted()) rows without plottable values").foregroundStyle(.secondary)
                }
                if data.reduced { Text("\(data.points.count.formatted()) marks after reduction").foregroundStyle(.secondary) }
                Spacer()
                if let query, let runQuery, let sql = generatedSQL {
                    Button("Server SQL…") { showsSQL = true }
                        .popover(isPresented: $showsSQL) {
                            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
                                Text("Aggregate the original query on the server.").font(.headline)
                                ScrollView {
                                    Text(sql).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                HStack {
                                    Spacer()
                                    Button("Cancel", role: .cancel) { showsSQL = false }
                                    Button("Run in New Console") {
                                        showsSQL = false
                                        runQuery(sql, query.binding)
                                    }
                                }
                            }
                            .padding()
                            .frame(width: 470, height: 250)
                        }
                }
                if let point = hover ?? selected {
                    Text("\(point.x.label) · \(settings.numberFormat.label(point.y))").lineLimit(1)
                }
            }
            .font(.caption)
            HStack {
                if let selected {
                    Button(selected.rowCount == 1 ? "Show Row \(selected.sourceRow + 1)" : "Show First Row in Group") {
                        onRow(selected.sourceRow)
                    }
                }
                Spacer()
                Button("Save Chart Settings") {
                    let otherSchemas = presets.filter { $0.columns != source.columns }
                    let updated = [Preset(columns: source.columns, settings: settings)] + otherSchemas.prefix(15)
                    if let encoded = try? JSONEncoder().encode(updated) { saved = encoded }
                }
                Menu("Export Chart", systemImage: "square.and.arrow.up") {
                    Button("Copy PNG") { export(settings, points: points, format: .png, copy: true) }
                    Button("Save PNG…") { export(settings, points: points, format: .png, copy: false) }
                    Button("Save PDF…") { export(settings, points: points, format: .pdf, copy: false) }
                }
                .disabled(points.isEmpty)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private func name(_ index: Int?) -> String? {
        index.flatMap { source.columns.indices.contains($0) ? source.columns[$0] : nil }
    }

    private func recommend() async {
        guard settings == nil else { return }
        if let preset = presets.first(where: { $0.columns == source.columns }),
           [preset.settings.x, preset.settings.y, preset.settings.series].compactMap({ $0 }).allSatisfy(source.columns.indices.contains) {
            settings = preset.settings
            return
        }
        do {
            let recommended = try await IDEDatabaseChartSettings.recommended(for: source)
            if !Task.isCancelled { settings = recommended }
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func reload(_ settings: IDEDatabaseChartSettings?) async {
        guard let settings else { return }
        data = nil
        error = nil
        hover = nil
        selected = nil
        seriesFilter = nil
        showsSQL = false
        generatedSQL = nil
        let query = self.query
        let source = self.source
        do {
            let loaded = try await runDetached {
                let data = try await IDEDatabaseChartData.load(from: source, settings: settings)
                let sql = try? query?.sql(columns: source.columns, settings: settings)
                return (data, sql)
            }
            guard !Task.isCancelled, self.settings == settings else { return }
            data = loaded.0
            generatedSQL = loaded.1
        } catch {
            if !Task.isCancelled, self.settings == settings { self.error = error.localizedDescription }
        }
    }

    private func export(_ settings: IDEDatabaseChartSettings, points: [IDEDatabaseChartData.Point], format: UTType, copy: Bool) {
        let view = plot(settings, points: points, interactive: false)
            .padding(24).frame(width: 880, height: 520).background(.background)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let bytes: Data?
        if format == .png {
            bytes = renderer.cgImage.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
        } else {
            let output = NSMutableData()
            renderer.render { size, render in
                var box = CGRect(origin: .zero, size: size)
                guard let consumer = CGDataConsumer(data: output as CFMutableData),
                      let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
                context.beginPDFPage(nil)
                render(context)
                context.endPDFPage()
                context.closePDF()
            }
            bytes = output.length == 0 ? nil : output as Data
        }
        guard let bytes else { error = "Could not render the chart."; return }
        if copy {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(bytes, forType: .png)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format]
        panel.nameFieldStringValue = format == .png ? "query-chart.png" : "query-chart.pdf"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do { try await runDetached { try bytes.write(to: url, options: .atomic) } }
                catch { self.error = error.localizedDescription }
            }
        }
    }
}
