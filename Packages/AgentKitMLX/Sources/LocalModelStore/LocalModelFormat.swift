import Foundation

/// Display strings for the Local Models panes, kept out of the views so they can be tested.
public enum LocalModelFormat {
    public static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// 4_022_468_096 → "4.0B", 135_000_000 → "135M".
    public static func parameters(_ count: Int64) -> String {
        switch count {
        case 1_000_000_000...: String(format: "%.1fB", Double(count) / 1_000_000_000)
        case 1_000_000...: String(format: "%.0fM", Double(count) / 1_000_000)
        default: "\(count)"
        }
    }

    /// 19_750 → "19.8K".
    public static func compactCount(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    /// Whole seconds under a minute, then minutes: 0.4 → "<1s", 4.2 → "4s", 65 → "1m 5s".
    public static func elapsed(_ seconds: TimeInterval) -> String {
        guard seconds >= 1 else { return "<1s" }
        let total = Int(seconds.rounded())
        return total < 60 ? "\(total)s" : "\(total / 60)m \(total % 60)s"
    }

    public static func shortName(_ repositoryID: String) -> String {
        repositoryID.split(separator: "/").last.map(String.init) ?? repositoryID
    }

    public static func owner(_ repositoryID: String) -> String {
        repositoryID.split(separator: "/").first.map(String.init) ?? ""
    }
}
