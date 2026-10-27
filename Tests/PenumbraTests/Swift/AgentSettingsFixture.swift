import Foundation

/// `IDEAgentSettingsView.swift` as it stood when Swift highlighting and Reformat Code misbehaved on
/// it: SwiftUI builders, `$binding` names, multi-line ternaries, and a `▸` (3 UTF-8 bytes, one UTF-16
/// unit) in a comment. A copy, so the tests do not follow the app's churn.
enum AgentSettingsFixture {
    static let source = load("AgentSettingsView.swift.txt")
    /// The committed text the working-tree edit started from: the moved block is still at the end.
    static let headSource = load("AgentSettingsView.head.swift.txt")

    private static func load(_ name: String) -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SwiftViews/\(name)")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("missing fixture \(url.path)")
        }
        return text
    }
}
