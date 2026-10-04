import Foundation

/// A unified diff between two texts, for showing an edit before it is applied. Line based, with the
/// common start and end trimmed first so a small change in a big file stays cheap.
public enum UnifiedDiff {
    public static let contextLines = 3
    /// Beyond this many comparisons the middle is shown as one replaced block instead of aligned.
    static let maxComparisons = 4_000_000

    public static func make(path: String, old: String?, new: String) -> String {
        let oldLines = old.map(lines) ?? []
        let newLines = lines(new)
        let header = old == nil ? "--- /dev/null\n+++ b/\(path)\n" : "--- a/\(path)\n+++ b/\(path)\n"
        guard oldLines != newLines else { return header }

        // Edit script: each entry is one line of the old text, the new text, or both.
        var script: [Op] = []
        var prefix = 0
        while prefix < oldLines.count, prefix < newLines.count, oldLines[prefix] == newLines[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < oldLines.count - prefix, suffix < newLines.count - prefix,
              oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] { suffix += 1 }

        script += oldLines[..<prefix].map { .keep($0) }
        script += align(Array(oldLines[prefix..<(oldLines.count - suffix)]), Array(newLines[prefix..<(newLines.count - suffix)]))
        script += oldLines[(oldLines.count - suffix)...].map { .keep($0) }
        return header + hunks(script)
    }

    private enum Op: Equatable {
        case keep(String)
        case remove(String)
        case add(String)
    }

    private static func lines(_ text: String) -> [String] {
        var result = text.components(separatedBy: "\n")
        if result.last == "" { result.removeLast() }
        return result.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    /// Longest common subsequence of the differing middles.
    private static func align(_ old: [String], _ new: [String]) -> [Op] {
        if old.isEmpty { return new.map { .add($0) } }
        if new.isEmpty { return old.map { .remove($0) } }
        guard old.count * new.count <= maxComparisons else { return old.map { .remove($0) } + new.map { .add($0) } }

        var table = [[Int32]](repeating: [Int32](repeating: 0, count: new.count + 1), count: old.count + 1)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [Op] = []
        var i = 0, j = 0
        while i < old.count, j < new.count {
            if old[i] == new[j] {
                result.append(.keep(old[i])); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                result.append(.remove(old[i])); i += 1
            } else {
                result.append(.add(new[j])); j += 1
            }
        }
        while i < old.count { result.append(.remove(old[i])); i += 1 }
        while j < new.count { result.append(.add(new[j])); j += 1 }
        return result
    }

    private static func hunks(_ script: [Op]) -> String {
        let changed = script.indices.filter { script[$0] != .keep(text(script[$0])) }
        guard !changed.isEmpty else { return "" }

        // Group changes whose context would overlap into one hunk.
        var groups: [(start: Int, end: Int)] = []
        for index in changed {
            let lower = max(0, index - contextLines), upper = min(script.count - 1, index + contextLines)
            if let last = groups.last, lower <= last.end + 1 {
                groups[groups.count - 1].end = max(last.end, upper)
            } else {
                groups.append((lower, upper))
            }
        }

        var output = ""
        for group in groups {
            let slice = script[group.start...group.end]
            let oldBefore = script[..<group.start].filter { if case .add = $0 { false } else { true } }.count
            let newBefore = script[..<group.start].filter { if case .remove = $0 { false } else { true } }.count
            let oldCount = slice.filter { if case .add = $0 { false } else { true } }.count
            let newCount = slice.filter { if case .remove = $0 { false } else { true } }.count
            output += "@@ -\(oldCount == 0 ? oldBefore : oldBefore + 1),\(oldCount) +\(newCount == 0 ? newBefore : newBefore + 1),\(newCount) @@\n"
            for op in slice {
                switch op {
                case .keep(let line): output += " \(line)\n"
                case .remove(let line): output += "-\(line)\n"
                case .add(let line): output += "+\(line)\n"
                }
            }
        }
        return output
    }

    private static func text(_ op: Op) -> String {
        switch op {
        case .keep(let line), .remove(let line), .add(let line): line
        }
    }
}
