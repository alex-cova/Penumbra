import Foundation

/// File sizes for the adapter UI, written as numbers ("0 bytes", never "Zero KB").
enum IDEACPByteFormat {
    static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }
}
