import Foundation

/// The path globs used by LSP document selectors.
struct LSPDocumentGlob: Sendable {
    private struct Alternative: Sendable {
        let segments: [String]
        let matchesFilename: Bool
    }

    private let alternatives: [Alternative]

    init?(_ pattern: String) {
        guard !pattern.isEmpty, pattern.utf8.count <= 4096, !pattern.utf8.contains(0) else { return nil }
        var pending = [pattern]
        var alternatives: [Alternative] = []
        while let candidate = pending.popLast() {
            if let group = Self.firstAlternation(in: candidate) {
                guard pending.count + alternatives.count + group.choices.count <= 64 else { return nil }
                for choice in group.choices {
                    pending.append(String(candidate[..<group.range.lowerBound]) + choice + candidate[group.range.upperBound...])
                }
            } else {
                let segments = candidate.split(separator: "/").map(String.init)
                if !segments.isEmpty {
                    alternatives.append(Alternative(segments: segments, matchesFilename: !candidate.contains("/")))
                }
            }
        }
        guard !alternatives.isEmpty else { return nil }
        self.alternatives = alternatives
    }

    func matches(path: String) -> Bool {
        guard !path.utf8.contains(0) else { return false }
        let segments = path.split(separator: "/").map(String.init)
        guard let name = segments.last else { return false }
        return alternatives.contains { pattern in
            if pattern.matchesFilename { return fnmatch(pattern.segments[0], name, FNM_PATHNAME) == 0 }
            var reachable = Array(repeating: false, count: segments.count + 1)
            reachable[0] = true
            for segment in pattern.segments {
                if segment == "**" {
                    // From each reachable prefix, zero or more additional path segments match.
                    for end in 1...segments.count where reachable[end - 1] { reachable[end] = true }
                } else {
                    for end in (1...segments.count).reversed() {
                        reachable[end] = reachable[end - 1] && fnmatch(segment, segments[end - 1], FNM_PATHNAME) == 0
                    }
                    reachable[0] = false
                }
            }
            return reachable[segments.count]
        }
    }

    private static func firstAlternation(in pattern: String) -> (range: Range<String.Index>, choices: [Substring])? {
        var opening: String.Index?
        var start = pattern.startIndex
        var choices: [Substring] = []
        var depth = 0
        var escaped = false
        var inClass = false
        for index in pattern.indices {
            let character = pattern[index]
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "[" { inClass = true }
            if character == "]" { inClass = false }
            if inClass { continue }
            switch character {
            case "{":
                if depth == 0 {
                    opening = index
                    start = pattern.index(after: index)
                }
                depth += 1
            case "," where depth == 1:
                choices.append(pattern[start..<index])
                start = pattern.index(after: index)
            case "}" where depth > 0:
                depth -= 1
                if depth == 0, let opening {
                    choices.append(pattern[start..<index])
                    return (opening..<pattern.index(after: index), choices)
                }
            default:
                break
            }
        }
        return nil
    }
}
