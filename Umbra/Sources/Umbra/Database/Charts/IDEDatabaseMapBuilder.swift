import EditorIntelligence
import MapKit
import SwiftUI

struct IDEDatabaseMapBuilder: View {
    fileprivate enum Mode: String, CaseIterable, Identifiable {
        case coordinates = "Latitude and Longitude", geometry = "Geometry Column"
        var id: Self { self }
    }

    let source: IDEDatabaseVisualizationSource
    let onRow: (Int) -> Void
    @State private var mode: Mode
    @State private var latitude: Int?
    @State private var longitude: Int?
    @State private var geometry: Int?
    @State private var srid: Int?
    @State private var showsBasemap = false
    @State private var data: IDEDatabaseMapData?
    @State private var error: String?
    @State private var row: Int?
    @State private var position: MapCameraPosition = .automatic

    init(source: IDEDatabaseVisualizationSource, onRow: @escaping (Int) -> Void) {
        self.source = source
        self.onRow = onRow
        let lat = source.columns.firstIndex { ["latitude", "lat"].contains($0.lowercased()) }
        let lon = source.columns.firstIndex { ["longitude", "lon", "lng", "long"].contains($0.lowercased()) }
        let geo = source.columns.firstIndex { ["geojson", "st_asgeojson", "geometry", "geom", "location"].contains($0.lowercased()) }
        _latitude = State(initialValue: lat)
        _longitude = State(initialValue: lon)
        _geometry = State(initialValue: geo)
        _srid = State(initialValue: source.columns.firstIndex { ["srid", "st_srid"].contains($0.lowercased()) })
        _mode = State(initialValue: geo != nil && (lat == nil || lon == nil) ? .geometry : .coordinates)
    }

    private var input: IDEDatabaseMapData.Input? {
        switch mode {
        case .coordinates:
            guard let latitude, let longitude, latitude != longitude else { return nil }
            return .coordinates(latitude: latitude, longitude: longitude)
        case .geometry: return geometry.map { .geometry($0, srid: srid) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
            HStack {
                Picker("Map Input", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                switch mode {
                case .coordinates:
                    columnPicker("Latitude", $latitude)
                    columnPicker("Longitude", $longitude)
                case .geometry:
                    columnPicker("Geometry", $geometry)
                        .help("WKT and WKB use longitude first. For MySQL WKB, request axis-order=long-lat.")
                    columnPicker("SRID", $srid)
                        .help("Select the ST_SRID result column for SQL spatial data.")
                }
                Spacer()
            }
            HStack {
                Toggle("Show Apple Maps Basemap", isOn: $showsBasemap)
                Text("The basemap requests Apple Maps tiles for the viewport.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error {
                ContentUnavailableView("Map Unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if input == nil {
                ContentUnavailableView("Choose Map Columns", systemImage: "map",
                                       description: Text("Use WGS84 coordinates, GeoJSON, or WKT/WKB with SRID 4326."))
            } else if let data {
                if data.features.isEmpty {
                    ContentUnavailableView("No Mappable Values", systemImage: "map",
                                           description: Text("Check the columns and coordinate system."))
                } else if showsBasemap {
                    onlineMap(data.features)
                } else if let projection = IDEDatabaseMapProjection(features: data.features) {
                    IDEDatabaseOfflineMap(features: data.features, projection: projection, selectedRow: $row)
                }
                status(data)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: input) { await reload(input) }
    }

    private func columnPicker(_ label: String, _ selection: Binding<Int?>) -> some View {
        Picker(label, selection: selection) {
            Text("Choose Column").tag(nil as Int?)
            ForEach(source.columns.indices, id: \.self) { index in Text(source.columns[index]).tag(Optional(index)) }
        }
        .lineLimit(1)
    }

    private func status(_ data: IDEDatabaseMapData) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.scope(sampleCount: data.sampledRows) + " · WGS84")
                if data.invalidRows > 0 { Text("\(data.invalidRows.formatted()) invalid or empty geometries") }
                if data.unsupportedRows > 0 { Text("\(data.unsupportedRows.formatted()) rows use an unknown or unsupported CRS. Expected SRID 4326.") }
                if data.omittedForSize > 0 { Text("\(data.omittedForSize.formatted()) geometries exceeded the display limit") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            if let row { Button("Show Row \(row + 1)") { onRow(row) } }
        }
    }

    private func onlineMap(_ features: [IDEDatabaseMapData.Feature]) -> some View {
        Map(position: $position) {
            ForEach(features) { feature in
                switch feature.shape {
                case .points(let points):
                    ForEach(points.indices, id: \.self) { index in
                        Annotation("Row \(feature.row + 1)", coordinate: points[index].mapCoordinate) {
                            Button {
                                row = feature.row
                            } label: {
                                Image(systemName: "circle.fill")
                                    .foregroundStyle(row == feature.row ? .orange : Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Select result row \(feature.row + 1)")
                        }
                        .annotationTitles(.hidden)
                    }
                case .line(let points):
                    MapPolyline(coordinates: points.map(\.mapCoordinate)).stroke(Color.accentColor, lineWidth: 2)
                case .polygon(let rings):
                    if let exterior = rings.first {
                        let holes = rings.dropFirst().map { ring in
                            MKPolygon(coordinates: ring.map(\.mapCoordinate), count: ring.count)
                        }
                        MapPolygon(MKPolygon(coordinates: exterior.map(\.mapCoordinate), count: exterior.count, interiorPolygons: holes))
                            .foregroundStyle(Color.accentColor.opacity(0.28))
                            .stroke(Color.accentColor, lineWidth: 1)
                    }
                }
            }
        }
        .clipShape(.rect(cornerRadius: 6))
    }

    private func reload(_ input: IDEDatabaseMapData.Input?) async {
        data = nil
        error = nil
        row = nil
        guard let input else { return }
        do {
            let loaded = try await runDetached { try await IDEDatabaseMapData.load(from: source, input: input) }
            guard !Task.isCancelled, self.input == input else { return }
            data = loaded
            if let projection = IDEDatabaseMapProjection(features: loaded.features) { position = .region(projection.region) }
        } catch {
            if !Task.isCancelled, self.input == input { self.error = error.localizedDescription }
        }
    }
}

private extension IDEDatabaseMapCoordinate {
    var mapCoordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

struct IDEDatabaseMapProjection {
    private let seam: Double
    private let midLatitude: Double
    private let midLongitude: Double
    private let latitudeSpan: Double
    private let longitudeSpan: Double

    init?(features: [IDEDatabaseMapData.Feature]) {
        let coordinates = features.flatMap { $0.shape.coordinates }
        guard let minLat = coordinates.map(\.latitude).min(), let maxLat = coordinates.map(\.latitude).max() else { return nil }
        let longitudes = coordinates.map(\.longitude).sorted()
        guard let first = longitudes.first, let last = longitudes.last else { return nil }
        var largest = first + 360 - last
        var start = first
        for (left, right) in zip(longitudes, longitudes.dropFirst()) where right - left > largest {
            largest = right - left
            start = right
        }
        seam = start
        let maximum = start + 360 - largest
        midLongitude = (start + maximum) / 2
        midLatitude = (minLat + maxLat) / 2
        latitudeSpan = max(0.04, maxLat - minLat)
        longitudeSpan = max(0.04, maximum - start)
    }

    var region: MKCoordinateRegion {
        let longitude = midLongitude > 180 ? midLongitude - 360 : midLongitude
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: midLatitude, longitude: longitude),
            span: MKCoordinateSpan(latitudeDelta: min(180, latitudeSpan * 1.2), longitudeDelta: min(360, longitudeSpan * 1.2))
        )
    }

    func point(_ coordinate: IDEDatabaseMapCoordinate, in size: CGSize) -> CGPoint {
        let longitude = coordinate.longitude < seam ? coordinate.longitude + 360 : coordinate.longitude
        let cosLatitude = max(0.15, cos(midLatitude * .pi / 180))
        let scale = min(max(1, size.width - 36) / (longitudeSpan * cosLatitude),
                        max(1, size.height - 36) / latitudeSpan)
        return CGPoint(x: size.width / 2 + (longitude - midLongitude) * scale * cosLatitude,
                       y: size.height / 2 - (coordinate.latitude - midLatitude) * scale)
    }
}

private struct IDEDatabaseOfflineMap: View {
    let features: [IDEDatabaseMapData.Feature]
    let projection: IDEDatabaseMapProjection
    @Binding var selectedRow: Int?

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                for feature in features {
                    let color = feature.row == selectedRow ? Color.orange : IDEAppearance.ColorToken.accent
                    switch feature.shape {
                    case .points(let coordinates):
                        for coordinate in coordinates {
                            let point = projection.point(coordinate, in: size)
                            context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)), with: .color(color))
                        }
                    case .line(let coordinates):
                        var path = Path()
                        path.addLines(coordinates.map { projection.point($0, in: size) })
                        context.stroke(path, with: .color(color), lineWidth: 2)
                    case .polygon(let rings):
                        var path = Path()
                        for ring in rings {
                            path.addLines(ring.map { projection.point($0, in: size) })
                            path.closeSubpath()
                        }
                        context.fill(path, with: .color(color.opacity(0.25)), style: FillStyle(eoFill: true))
                        context.stroke(path, with: .color(color), lineWidth: 1)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { event in
                var nearest: (row: Int, distance: Double)?
                for feature in features {
                    for coordinate in feature.shape.coordinates {
                        let point = projection.point(coordinate, in: geometry.size)
                        let distance = hypot(point.x - event.location.x, point.y - event.location.y)
                        if distance <= 18, distance < (nearest?.distance ?? .infinity) {
                            nearest = (feature.row, distance)
                        }
                    }
                }
                selectedRow = nearest?.row
            })
            .accessibilityLabel("Offline map")
            .accessibilityValue("\(features.count.formatted()) features")
        }
        .background(IDEAppearance.ColorToken.editor)
        .clipShape(.rect(cornerRadius: 6))
    }
}
