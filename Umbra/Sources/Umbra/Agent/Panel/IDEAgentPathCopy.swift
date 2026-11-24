import AppKit
import SwiftUI

/// Copying a project-relative path the agent changed: the Changes tab's Copy Path, the copy button on a
/// "files changed" row and on an edit's approval card all write the same text.
enum IDEAgentPathCopy {
    /// Puts `path` on `pasteboard` as plain text. False when the pasteboard refused it.
    @discardableResult
    static func copy(_ path: String, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(path, forType: .string)
    }

    /// The file an edit's unified diff is about (`+++ b/path`, else `--- a/path` for a removal).
    static func path(fromUnifiedDiff diff: String) -> String? {
        var removed: String?
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false).prefix(4) {
            if line.hasPrefix("+++ "), let path = strip(line.dropFirst(4), prefix: "b/") { return path }
            if line.hasPrefix("--- "), let path = strip(line.dropFirst(4), prefix: "a/") { removed = path }
        }
        return removed
    }

    private static func strip(_ text: Substring, prefix: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value != "/dev/null" else { return nil }
        return value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
    }
}

/// A small copy icon that turns into a checkmark for a moment once the path is on the pasteboard.
struct IDEAgentCopyPathButton: View {
    let path: String
    /// Told when the pasteboard refused the path (the panel shows an error toast).
    var onFailure: () -> Void = {}

    @State private var copied = false

    var body: some View {
        Button("Copy Path", systemImage: copied ? "checkmark" : "doc.on.doc") {
            if IDEAgentPathCopy.copy(path) {
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } else {
                onFailure()
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(IDEAppearance.Typography.caption)
        .foregroundStyle(copied ? IDEAppearance.ColorToken.gitAdded : IDEAppearance.ColorToken.muted)
        .frame(width: IDEAppearance.Spacing.iconButton, height: IDEAppearance.Spacing.iconButton)
        .contentShape(Rectangle())
        .help(copied ? "Copied" : "Copy \(path)")
        .accessibilityLabel(copied ? "Path copied" : "Copy path \(path)")
    }
}

extension IDEAgentToast {
    /// What the copy buttons show when the pasteboard refused the path.
    static func copyFailed(_ path: String) -> IDEAgentToast {
        IDEAgentToast(title: "Couldn't copy the path", detail: path, kind: .error)
    }
}
