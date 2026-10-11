import Foundation
import HexKit

/// Hex editor preferences for this Mac. They live in their own defaults suite, so they are not part
/// of the shared preferences snapshot (`IDEPreferences.snapshot()` / `restore(from:)`).
@MainActor
final class IDEHexSettings {
    static let shared = IDEHexSettings()

    static let suiteName = "com.umbra.editor.hex"

    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: Self.suiteName) ?? .standard
        registerDefaults()
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Key.openBinary: true,
            Key.sniffUnknown: true,
            Key.bytesPerRow: "auto",
            Key.groupSize: 8,
            Key.offsetBase: HexOffsetBase.hexadecimal.rawValue,
            Key.uppercase: true,
            Key.colorByClass: true,
            Key.encoding: HexPaneEncoding.windows1252.rawValue,
            Key.copyStyle: HexCopyStyle.hex.rawValue,
            Key.inspector: true,
            Key.littleEndian: true,
            Key.threshold: 256 * 1024 * 1024,
        ])
    }

    var openBinaryAsHex: Bool {
        get { defaults.object(forKey: Key.openBinary) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.openBinary) }
    }

    var sniffUnknownFiles: Bool {
        get { defaults.object(forKey: Key.sniffUnknown) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.sniffUnknown) }
    }

    var forceTextExtensions: [String] {
        get { list(Key.forceText) }
        set { defaults.set(normalize(newValue), forKey: Key.forceText) }
    }

    var forceHexExtensions: [String] {
        get { list(Key.forceHex) }
        set { defaults.set(normalize(newValue), forKey: Key.forceHex) }
    }

    /// `"auto"` or one of 8, 16, 24, 32, 48, 64.
    var bytesPerRowSetting: String {
        get { defaults.string(forKey: Key.bytesPerRow) ?? "auto" }
        set { defaults.set(newValue, forKey: Key.bytesPerRow) }
    }

    var groupSize: Int {
        get {
            let value = defaults.integer(forKey: Key.groupSize)
            return [1, 2, 4, 8].contains(value) ? value : 8
        }
        set { defaults.set(newValue, forKey: Key.groupSize) }
    }

    var offsetBase: HexOffsetBase {
        get { HexOffsetBase(rawValue: defaults.string(forKey: Key.offsetBase) ?? "") ?? .hexadecimal }
        set { defaults.set(newValue.rawValue, forKey: Key.offsetBase) }
    }

    var uppercaseDigits: Bool {
        get { defaults.object(forKey: Key.uppercase) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.uppercase) }
    }

    var colorBytesByClass: Bool {
        get { defaults.object(forKey: Key.colorByClass) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.colorByClass) }
    }

    var textEncoding: HexPaneEncoding {
        get { HexPaneEncoding(rawValue: defaults.string(forKey: Key.encoding) ?? "") ?? .windows1252 }
        set { defaults.set(newValue.rawValue, forKey: Key.encoding) }
    }

    var copyStyle: HexCopyStyle {
        get { HexCopyStyle(rawValue: defaults.string(forKey: Key.copyStyle) ?? "") ?? .hex }
        set { defaults.set(newValue.rawValue, forKey: Key.copyStyle) }
    }

    var inspectorVisible: Bool {
        get { defaults.object(forKey: Key.inspector) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.inspector) }
    }

    var littleEndianFirst: Bool {
        get { defaults.object(forKey: Key.littleEndian) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.littleEndian) }
    }

    /// Files larger than this open read-only until Make Editable is confirmed. Default 256 MB.
    var largeFileEditThreshold: Int64 {
        get {
            if let number = defaults.object(forKey: Key.threshold) as? NSNumber {
                return number.int64Value
            }
            return 256 * 1024 * 1024
        }
        set { defaults.set(newValue, forKey: Key.threshold) }
    }

    func isSniffBannerDismissed(for path: String) -> Bool {
        dismissed().contains(path)
    }

    func dismissSniffBanner(for path: String) {
        var paths = dismissed()
        paths.insert(path)
        defaults.set(Array(paths), forKey: Key.dismissed)
    }

    func forgetSniffBanner(for path: String) {
        var paths = dismissed()
        paths.remove(path)
        defaults.set(Array(paths), forKey: Key.dismissed)
    }

    private func list(_ key: String) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    private func dismissed() -> Set<String> {
        Set(defaults.stringArray(forKey: Key.dismissed) ?? [])
    }

    private func normalize(_ extensions: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in extensions {
            let cleaned = item.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            guard !cleaned.isEmpty, seen.insert(cleaned).inserted else { continue }
            result.append(cleaned)
        }
        return result
    }

    private enum Key {
        static let openBinary = "openBinaryAsHex"
        static let sniffUnknown = "sniffUnknown"
        static let forceText = "forceTextExtensions"
        static let forceHex = "forceHexExtensions"
        static let bytesPerRow = "bytesPerRow"
        static let groupSize = "groupSize"
        static let offsetBase = "offsetBase"
        static let uppercase = "uppercaseDigits"
        static let colorByClass = "colorBytesByClass"
        static let encoding = "textEncoding"
        static let copyStyle = "copyStyle"
        static let inspector = "inspectorVisible"
        static let littleEndian = "littleEndianFirst"
        static let threshold = "largeFileEditThreshold"
        static let dismissed = "dismissedSniffBanners"
    }
}
