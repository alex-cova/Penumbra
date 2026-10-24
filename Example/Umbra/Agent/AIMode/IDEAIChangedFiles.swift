import AgentKit
import Foundation

/// One file the selected chat's runs changed, across all of its runs.
struct IDEAIChangedFile: Identifiable, Equatable {
    var path: String
    /// The text before this chat touched the file (`nil`: the chat created it).
    var original: String?
    /// The "N files changed" cards that touched it, newest first.
    var entryIDs: [UUID]
    /// Every run that touched the file was reverted.
    var isReverted: Bool
    /// A revert left the file alone because it changed after the agent wrote it.
    var hasConflict: Bool

    var id: String { path }
    var isCreation: Bool { original == nil }
    var name: String { (path as NSString).lastPathComponent }
    var folder: String {
        let folder = (path as NSString).deletingLastPathComponent
        return folder == "." ? "" : folder
    }
}

/// What the Changes tab lists, worked out from the transcript alone.
enum IDEAIChangedFiles {
    /// One row per path, the file touched most recently first. The original is the one the earliest run
    /// that was not reverted recorded, so the row compares "before this chat" with "now"; a file whose
    /// runs were all reverted keeps the earliest original and is marked reverted.
    static func summarize(_ entries: [IDEAgentEntry]) -> [IDEAIChangedFile] {
        struct Touch {
            var entryIndex: Int
            var entry: IDEAgentEntry
            var change: IDEAgentFileChange
        }
        var touches: [String: [Touch]] = [:]
        var order: [String] = []
        for (index, entry) in entries.enumerated() where entry.kind == .changes {
            for change in entry.fileChanges {
                if touches[change.path] == nil { order.append(change.path) }
                touches[change.path, default: []].append(Touch(entryIndex: index, entry: entry, change: change))
            }
        }
        let rows: [(lastIndex: Int, position: Int, file: IDEAIChangedFile)] = order.enumerated().compactMap { position, path in
            guard let all = touches[path], let last = all.last else { return nil }
            let live = all.filter { !$0.entry.isReverted }
            let basis = live.first ?? all[0]
            let file = IDEAIChangedFile(
                path: path,
                original: basis.change.original,
                entryIDs: all.reversed().map(\.entry.id),
                isReverted: live.isEmpty,
                hasConflict: all.contains { $0.entry.conflicts.contains { $0.path == path } })
            return (last.entryIndex, position, file)
        }
        // Files one run touched together keep the order that run listed them in.
        return rows.sorted { ($0.lastIndex, $1.position) > ($1.lastIndex, $0.position) }.map(\.file)
    }

    /// Files the running turn has already written, before its "files changed" card exists (cards are
    /// added when a run ends). Read from finished `edit_file` / `write_file` calls after the last user
    /// message, leaving out paths a card already lists.
    static func pendingPaths(in entries: [IDEAgentEntry], isRunning: Bool) -> [String] {
        guard isRunning else { return [] }
        let start = entries.lastIndex { $0.kind == .user }.map { $0 + 1 } ?? 0
        let listed = Set(entries[start...].filter { $0.kind == .changes }.flatMap { $0.fileChanges.map(\.path) })
        var seen = listed
        var paths: [String] = []
        for entry in entries[start...] {
            guard case .toolCall(let name) = entry.kind, name == "edit_file" || name == "write_file",
                  let output = entry.output, !output.isError,
                  let path = (try? JSONValue(parsing: entry.text))?.objectValue?["path"]?.stringValue,
                  seen.insert(path).inserted
            else { continue }
            paths.append(path)
        }
        return paths
    }
}

/// A unified diff for the Changes tab: hunks with a few lines of context, in the form
/// `IDEAgentDiffView` tints.
struct IDEAIUnifiedDiff: Equatable {
    var text: String
    var added: Int
    var removed: Int

    var isEmpty: Bool { added == 0 && removed == 0 }

    /// Output stops after this many lines, so one huge rewrite can't make the row heavy.
    static let maximumOutputLines = 2_000

    /// `original == nil` is a created file (everything added); `current == nil` is a file that is gone
    /// (everything removed). A final line break that was only added or removed is not a change.
    /// Pure and synchronous: callers run it off the main actor.
    static func make(original: String?, current: String?, context: Int = 3) -> IDEAIUnifiedDiff {
        let left = IDEDiffText(original ?? "")
        let right = IDEDiffText(current ?? "")
        let leftCount = lineCount(left), rightCount = lineCount(right)
        let chunks: [(left: Range<Int>, right: Range<Int>)] = IDEDiffComputer
            .lineChunks(left: left, right: right, maximumMiddle: IDEDiffComputer.maximumInlineLength)
            .compactMap { chunk in
                let l = chunk.left.clamped(to: 0 ..< leftCount)
                let r = chunk.right.clamped(to: 0 ..< rightCount)
                return l.isEmpty && r.isEmpty ? nil : (l, r)
            }
        guard !chunks.isEmpty else { return IDEAIUnifiedDiff(text: "", added: 0, removed: 0) }

        // Chunks closer than two contexts share a hunk.
        var groups: [[(left: Range<Int>, right: Range<Int>)]] = []
        for chunk in chunks {
            if let previous = groups.last?.last, chunk.left.lowerBound - previous.left.upperBound <= 2 * context {
                groups[groups.count - 1].append(chunk)
            } else {
                groups.append([chunk])
            }
        }

        var lines: [String] = []
        var isTruncated = false
        for group in groups {
            guard let first = group.first, let last = group.last else { continue }
            let leftStart = max(0, first.left.lowerBound - context)
            let rightStart = leftStart + (first.right.lowerBound - first.left.lowerBound)
            let leftEnd = min(leftCount, last.left.upperBound + context)
            let rightEnd = last.right.upperBound + (leftEnd - last.left.upperBound)
            var body: [String] = []
            var position = leftStart
            for chunk in group {
                for index in position ..< chunk.left.lowerBound { body.append(" " + left.line(index)) }
                for index in chunk.left { body.append("-" + left.line(index)) }
                for index in chunk.right { body.append("+" + right.line(index)) }
                position = chunk.left.upperBound
            }
            for index in position ..< leftEnd { body.append(" " + left.line(index)) }
            let hunk = ["@@ -\(header(leftStart ..< leftEnd)) +\(header(rightStart ..< rightEnd)) @@"] + body
            if lines.count + hunk.count > maximumOutputLines {
                // A first hunk that is too long on its own is cut rather than dropped, so the row shows something.
                if lines.isEmpty { lines.append(contentsOf: hunk.prefix(maximumOutputLines)) }
                isTruncated = true
                break
            }
            lines.append(contentsOf: hunk)
        }
        if isTruncated { lines.append("… diff truncated; open it in the editor to see all of it") }
        return IDEAIUnifiedDiff(
            text: lines.joined(separator: "\n"),
            added: chunks.reduce(0) { $0 + $1.right.count },
            removed: chunks.reduce(0) { $0 + $1.left.count })
    }

    /// Lines as a reader counts them: none for an empty text, and the empty last line a final line
    /// break leaves is not one.
    private static func lineCount(_ text: IDEDiffText) -> Int {
        if text.string.isEmpty { return 0 }
        return text.lines.last?.length == 0 ? text.lineCount - 1 : text.lineCount
    }

    /// `start,count`; an empty range names the line before it, as git does.
    private static func header(_ range: Range<Int>) -> String {
        "\(range.isEmpty ? range.lowerBound : range.lowerBound + 1),\(range.count)"
    }
}
