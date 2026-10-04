import Foundation

/// Glob matching over project-relative paths: `*` and `?` stay inside a folder, `**` crosses
/// folders, `{a,b}` alternates. A pattern with no `/` matches the file name at any depth, so
/// `*.java` finds every Java file.
public struct GlobPattern: Sendable {
    private let regex: NSRegularExpression

    public init(_ pattern: String) throws {
        let trimmed = pattern.hasPrefix("./") ? String(pattern.dropFirst(2)) : pattern
        var source = "^"
        if !trimmed.contains("/") { source += "(?:.*/)?" }

        var braceDepth = 0
        let characters = Array(trimmed)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "*":
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    // `**/` also matches nothing, so `src/**/A.java` finds `src/A.java`.
                    if index + 2 < characters.count, characters[index + 2] == "/" {
                        source += "(?:.*/)?"
                        index += 2
                    } else {
                        source += ".*"
                        index += 1
                    }
                } else {
                    source += "[^/]*"
                }
            case "?": source += "[^/]"
            case "{": braceDepth += 1; source += "(?:"
            case "}":
                guard braceDepth > 0 else { throw AgentWorkspaceError.invalidPattern("unbalanced } in \(pattern)") }
                braceDepth -= 1
                source += ")"
            case ",": source += braceDepth > 0 ? "|" : ","
            default: source += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }
        guard braceDepth == 0 else { throw AgentWorkspaceError.invalidPattern("unbalanced { in \(pattern)") }
        source += "$"
        do {
            regex = try NSRegularExpression(pattern: source)
        } catch {
            throw AgentWorkspaceError.invalidPattern(pattern)
        }
    }

    public func matches(_ path: String) -> Bool {
        regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }
}
