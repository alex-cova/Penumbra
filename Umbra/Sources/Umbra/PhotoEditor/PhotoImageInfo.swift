import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Human-readable metadata for the open photo, grouped for the inspector's Info module. Built the
/// same way as `PhotoExifSummary` — from a plain `[String: Any]` ImageIO dictionary plus a few
/// facts the session already knows — so it stays `Sendable` and unit-testable without a real image.
nonisolated struct PhotoImageInfo: Equatable, Sendable {
    struct Entry: Equatable, Sendable, Identifiable {
        var label: String
        var value: String
        var id: String { label }
    }

    struct Section: Equatable, Sendable, Identifiable {
        var title: String
        var entries: [Entry]
        var id: String { title }
    }

    var file: [Entry] = []
    var image: [Entry] = []
    var camera: [Entry] = []
    var location: [Entry] = []
    /// The whole ImageIO dictionary, flattened and sorted, for the "All metadata" disclosure.
    var allEntries: [Entry] = []

    static let empty = PhotoImageInfo()
    var isEmpty: Bool { self == .empty }

    /// Non-empty named sections, in display order.
    var sections: [Section] {
        [
            Section(title: "File", entries: file),
            Section(title: "Image", entries: image),
            Section(title: "Camera", entries: camera),
            Section(title: "Location", entries: location),
        ].filter { !$0.entries.isEmpty }
    }

    /// One flat block of "Label\tValue" lines for copy-all.
    var plainText: String {
        var lines: [String] = []
        for section in sections {
            lines.append("[\(section.title)]")
            lines.append(contentsOf: section.entries.map { "\($0.label): \($0.value)" })
            lines.append("")
        }
        if !allEntries.isEmpty {
            lines.append("[All metadata]")
            lines.append(contentsOf: allEntries.map { "\($0.label): \($0.value)" })
        }
        return lines.joined(separator: "\n")
    }

    init() {}

    init(
        fileURL: URL?,
        fileSize: Int64?,
        metadata: [String: Any]?,
        pixelSize: CGSize,
        isRAW: Bool
    ) {
        file = Self.fileEntries(fileURL: fileURL, fileSize: fileSize, isRAW: isRAW)
        image = Self.imageEntries(metadata: metadata, pixelSize: pixelSize)
        camera = Self.cameraEntries(metadata: metadata)
        location = Self.locationEntries(metadata: metadata)
        allEntries = Self.flatten(metadata ?? [:])
    }

    // MARK: - File

    private static func fileEntries(fileURL: URL?, fileSize: Int64?, isRAW: Bool) -> [Entry] {
        var entries: [Entry] = []
        if let fileURL {
            entries.append(Entry(label: "Name", value: fileURL.lastPathComponent))
            let folder = fileURL.deletingLastPathComponent().path(percentEncoded: false)
            let abbreviated = (folder as NSString).abbreviatingWithTildeInPath
            if !abbreviated.isEmpty { entries.append(Entry(label: "Folder", value: abbreviated)) }

            let ext = fileURL.pathExtension
            if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
                let kind = type.localizedDescription ?? ext.uppercased()
                entries.append(Entry(label: "Kind", value: isRAW ? "\(kind) · RAW" : kind))
                if let mime = type.preferredMIMEType {
                    entries.append(Entry(label: "Type", value: mime))
                }
            } else if !ext.isEmpty {
                entries.append(Entry(label: "Kind", value: isRAW ? "\(ext.uppercased()) · RAW" : ext.uppercased()))
            }
        }
        if let fileSize, fileSize > 0 {
            entries.append(Entry(
                label: "Size on disk",
                value: ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
            ))
        }
        return entries
    }

    // MARK: - Image

    private static func imageEntries(metadata: [String: Any]?, pixelSize: CGSize) -> [Entry] {
        var entries: [Entry] = []
        let width = int(metadata?[kCGImagePropertyPixelWidth as String]) ?? Int(pixelSize.width.rounded())
        let height = int(metadata?[kCGImagePropertyPixelHeight as String]) ?? Int(pixelSize.height.rounded())
        if width > 0, height > 0 {
            entries.append(Entry(label: "Dimensions", value: "\(width) × \(height) px"))
            let mp = Double(width * height) / 1_000_000
            entries.append(Entry(label: "Megapixels", value: String(format: "%.1f MP", mp)))
            if let ratio = aspectRatioString(width: width, height: height) {
                entries.append(Entry(label: "Aspect ratio", value: ratio))
            }
        }

        if let dpiW = number(metadata?[kCGImagePropertyDPIWidth as String]) {
            let dpiH = number(metadata?[kCGImagePropertyDPIHeight as String]) ?? dpiW
            let value = abs(dpiW - dpiH) < 0.5
                ? "\(Int(dpiW.rounded())) dpi"
                : "\(Int(dpiW.rounded())) × \(Int(dpiH.rounded())) dpi"
            entries.append(Entry(label: "Resolution", value: value))
        }

        if let orientation = int(metadata?[kCGImagePropertyOrientation as String]),
           let text = orientationText(orientation) {
            entries.append(Entry(label: "Orientation", value: text))
        }
        if let model = string(metadata?[kCGImagePropertyColorModel as String]) {
            entries.append(Entry(label: "Color model", value: model))
        }
        if let depth = int(metadata?[kCGImagePropertyDepth as String]) {
            entries.append(Entry(label: "Bit depth", value: "\(depth) bits/channel"))
        }
        if let profile = string(metadata?[kCGImagePropertyProfileName as String]) {
            entries.append(Entry(label: "Color profile", value: profile))
        }
        if let hasAlpha = bool(metadata?[kCGImagePropertyHasAlpha as String]) {
            entries.append(Entry(label: "Alpha", value: hasAlpha ? "Yes" : "No"))
        }
        return entries
    }

    // MARK: - Camera

    private static func cameraEntries(metadata: [String: Any]?) -> [Entry] {
        let tiff = metadata?[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let exif = metadata?[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let aux = metadata?[kCGImagePropertyExifAuxDictionary as String] as? [String: Any]
        var entries: [Entry] = []

        if let make = string(tiff?[kCGImagePropertyTIFFMake as String]) {
            entries.append(Entry(label: "Make", value: make))
        }
        if let model = string(tiff?[kCGImagePropertyTIFFModel as String]) {
            entries.append(Entry(label: "Model", value: model))
        }
        let lens = string(exif?[kCGImagePropertyExifLensModel as String])
            ?? string(aux?["LensModel"])
        if let lens { entries.append(Entry(label: "Lens", value: lens)) }
        if let software = string(tiff?[kCGImagePropertyTIFFSoftware as String]) {
            entries.append(Entry(label: "Software", value: software))
        }
        if let date = string(exif?[kCGImagePropertyExifDateTimeOriginal as String])
            ?? string(tiff?[kCGImagePropertyTIFFDateTime as String]) {
            entries.append(Entry(label: "Captured", value: prettyDate(date)))
        }

        if let exposure = number(exif?[kCGImagePropertyExifExposureTime as String]) {
            entries.append(Entry(label: "Shutter", value: shutterString(exposure)))
        }
        if let fNumber = number(exif?[kCGImagePropertyExifFNumber as String]) {
            entries.append(Entry(label: "Aperture", value: "f/\(trimmed(fNumber))"))
        }
        if let iso = firstNumber(exif?[kCGImagePropertyExifISOSpeedRatings as String]) {
            entries.append(Entry(label: "ISO", value: "\(Int(iso))"))
        }
        if let focal = number(exif?[kCGImagePropertyExifFocalLength as String]) {
            entries.append(Entry(label: "Focal length", value: "\(Int(focal.rounded())) mm"))
        }
        if let equiv = number(exif?[kCGImagePropertyExifFocalLenIn35mmFilm as String]), equiv > 0 {
            entries.append(Entry(label: "35 mm equivalent", value: "\(Int(equiv.rounded())) mm"))
        }
        if let bias = number(exif?[kCGImagePropertyExifExposureBiasValue as String]), bias != 0 {
            entries.append(Entry(label: "Exposure bias", value: String(format: "%+.1f EV", bias)))
        }
        if let flash = int(exif?[kCGImagePropertyExifFlash as String]) {
            entries.append(Entry(label: "Flash", value: (flash & 0x1) == 1 ? "Fired" : "Did not fire"))
        }
        if let metering = int(exif?[kCGImagePropertyExifMeteringMode as String]),
           let text = meteringText(metering) {
            entries.append(Entry(label: "Metering", value: text))
        }
        if let wb = int(exif?[kCGImagePropertyExifWhiteBalance as String]) {
            entries.append(Entry(label: "White balance", value: wb == 0 ? "Auto" : "Manual"))
        }
        return entries
    }

    // MARK: - Location

    private static func locationEntries(metadata: [String: Any]?) -> [Entry] {
        guard let gps = metadata?[kCGImagePropertyGPSDictionary as String] as? [String: Any] else {
            return []
        }
        var entries: [Entry] = []
        if let lat = number(gps[kCGImagePropertyGPSLatitude as String]),
           let lon = number(gps[kCGImagePropertyGPSLongitude as String]) {
            let latRef = string(gps[kCGImagePropertyGPSLatitudeRef as String]) ?? "N"
            let lonRef = string(gps[kCGImagePropertyGPSLongitudeRef as String]) ?? "E"
            entries.append(Entry(
                label: "Coordinates",
                value: String(format: "%.6f° %@, %.6f° %@", lat, latRef, lon, lonRef)
            ))
        }
        if let altitude = number(gps[kCGImagePropertyGPSAltitude as String]) {
            let ref = int(gps[kCGImagePropertyGPSAltitudeRef as String]) ?? 0
            let sign = ref == 1 ? "-" : ""
            entries.append(Entry(label: "Altitude", value: "\(sign)\(Int(altitude.rounded())) m"))
        }
        if let direction = number(gps[kCGImagePropertyGPSImgDirection as String]) {
            entries.append(Entry(label: "Direction", value: "\(Int(direction.rounded()))°"))
        }
        return entries
    }

    // MARK: - Flatten

    private static func flatten(_ dictionary: [String: Any], prefix: String = "") -> [Entry] {
        var entries: [Entry] = []
        for (rawKey, value) in dictionary {
            let key = rawKey.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
            let label = prefix.isEmpty ? key : "\(prefix) · \(key)"
            if let nested = value as? [String: Any] {
                entries.append(contentsOf: flatten(nested, prefix: label))
            } else {
                entries.append(Entry(label: label, value: describe(value)))
            }
        }
        return entries.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private static func describe(_ value: Any) -> String {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return numberString(number.doubleValue)
        case let array as [Any]:
            return array.map(describe).joined(separator: ", ")
        case let data as Data:
            return "\(data.count) bytes"
        default:
            return String(describing: value)
        }
    }

    // MARK: - Parsing helpers

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: d
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    private static func firstNumber(_ value: Any?) -> Double? {
        if let array = value as? [Any], let first = array.first { return number(first) }
        return number(value)
    }

    private static func int(_ value: Any?) -> Int? {
        if let d = number(value) { return Int(d) }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String:
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let n as NSNumber:
            return n.stringValue
        default:
            return nil
        }
    }

    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let b as Bool: b
        case let n as NSNumber: n.boolValue
        default: nil
        }
    }

    private static func numberString(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
    }

    private static func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    private static func shutterString(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        if seconds >= 1 { return "\(trimmed(seconds)) s" }
        return "1/\(Int((1 / seconds).rounded())) s"
    }

    private static func aspectRatioString(width: Int, height: Int) -> String? {
        guard width > 0, height > 0 else { return nil }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let divisor = gcd(width, height)
        let w = width / divisor
        let h = height / divisor
        let decimal = String(format: "%.2f", Double(width) / Double(height))
        if w <= 40, h <= 40 { return "\(w):\(h)  (\(decimal))" }
        return decimal
    }

    private static func orientationText(_ value: Int) -> String? {
        switch value {
        case 1: "Normal"
        case 2: "Mirrored horizontally"
        case 3: "Rotated 180°"
        case 4: "Mirrored vertically"
        case 5: "Mirrored & rotated 90° CCW"
        case 6: "Rotated 90° CW"
        case 7: "Mirrored & rotated 90° CW"
        case 8: "Rotated 90° CCW"
        default: nil
        }
    }

    private static func meteringText(_ value: Int) -> String? {
        switch value {
        case 1: "Average"
        case 2: "Center-weighted"
        case 3: "Spot"
        case 4: "Multi-spot"
        case 5: "Pattern"
        case 6: "Partial"
        default: nil
        }
    }

    /// `2024:01:02 15:04:05` → `2024-01-02 15:04:05`.
    private static func prettyDate(_ raw: String) -> String {
        let parts = raw.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return raw }
        return "\(parts[0].replacingOccurrences(of: ":", with: "-")) \(parts[1])"
    }
}
