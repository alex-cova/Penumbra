import Foundation
import ImageIO

/// Human-readable camera settings pulled from an image's ImageIO metadata dictionary
/// (`CGImageSourceCopyPropertiesAtIndex`). Every field is optional; missing keys just drop out of
/// the rendered line. Pure string formatting so it is testable without a real image.
nonisolated struct PhotoExifSummary: Equatable, Sendable {
    var iso: String?
    var aperture: String?
    var shutter: String?
    var focalLength: String?

    static let empty = PhotoExifSummary()

    var isEmpty: Bool { self == .empty }

    /// e.g. `ISO 400 · f/2.8 · 1/250 · 35mm`.
    var line: String {
        [iso, aperture, shutter, focalLength]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    init(iso: String? = nil, aperture: String? = nil, shutter: String? = nil, focalLength: String? = nil) {
        self.iso = iso
        self.aperture = aperture
        self.shutter = shutter
        self.focalLength = focalLength
    }

    init(metadata: [String: Any]?) {
        guard let exif = metadata?[kCGImagePropertyExifDictionary as String] as? [String: Any] else {
            return
        }

        if let isoValue = Self.firstNumber(exif[kCGImagePropertyExifISOSpeedRatings as String]) {
            iso = "ISO \(Int(isoValue))"
        }
        if let fNumber = Self.number(exif[kCGImagePropertyExifFNumber as String]) {
            aperture = "f/\(Self.trim(fNumber))"
        }
        if let exposure = Self.number(exif[kCGImagePropertyExifExposureTime as String]) {
            shutter = Self.shutterString(exposure)
        }
        if let focal = Self.number(exif[kCGImagePropertyExifFocalLength as String]) {
            focalLength = "\(Int(focal.rounded()))mm"
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
        if let array = value as? [Any], let first = array.first {
            return number(first)
        }
        return number(value)
    }

    private static func shutterString(_ seconds: Double) -> String {
        guard seconds > 0 else { return "" }
        if seconds >= 1 {
            return "\(trim(seconds))s"
        }
        return "1/\(Int((1 / seconds).rounded()))"
    }

    private static func trim(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%.1f", value)
    }
}
