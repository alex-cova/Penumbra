import Foundation

/// A file mask for project search and replace: a comma- or space-separated list such as
/// `*.java, !*Test.java, src/**`.
///
/// - `*` matches within one path component, `**` (only as a whole component) across directories,
///   `?` one character. Matching is case-insensitive, like macOS volumes by default.
/// - A pattern without `/` matches file names (`*.java`); one with `/` matches the path relative
///   to the search root (`src/**`, `**/gen/*.java`). A trailing `/` names a directory anywhere
///   (`build/`).
/// - A leading `!` excludes. An exclusion always wins over an inclusion, wherever it is written,
///   and it applies to a directory's contents too (`!build` or `!build/**` drops everything
///   under `build`).
/// - An empty mask matches every file. A mask with an invalid pattern matches nothing rather than
///   everything, and reports the pattern in ``invalidPatterns``.
public struct FileMask: Sendable, Equatable {
    private struct Rule: @unchecked Sendable, Equatable {
        let isExclusion: Bool
        /// Matches a file or directory name rather than a root-relative path.
        let isNameOnly: Bool
        let regex: NSRegularExpression

        static func == (lhs: Rule, rhs: Rule) -> Bool {
            lhs.isExclusion == rhs.isExclusion && lhs.isNameOnly == rhs.isNameOnly
                && lhs.regex.pattern == rhs.regex.pattern
        }
    }

    public let text: String
    public private(set) var invalidPatterns: [String] = []
    private var rules: [Rule] = []
    private var includes: [Rule] { rules.filter { !$0.isExclusion } }
    private var excludes: [Rule] { rules.filter(\.isExclusion) }

    public init(_ text: String) {
        self.text = text
        for token in text.split(whereSeparator: { $0 == "," || $0.isWhitespace }) {
            var pattern = String(token)
            let isExclusion = pattern.hasPrefix("!")
            if isExclusion { pattern.removeFirst() }
            guard !pattern.isEmpty, let rule = Self.rule(for: pattern, isExclusion: isExclusion) else {
                invalidPatterns.append(String(token))
                continue
            }
            rules.append(rule)
        }
    }

    /// True when no pattern was written; every file matches.
    public var isEmpty: Bool { rules.isEmpty && invalidPatterns.isEmpty }
    public var isValid: Bool { invalidPatterns.isEmpty }

    /// Whether the file at `relativePath` (relative to the search root, `/`-separated) is in scope.
    public func matches(relativePath: String) -> Bool {
        guard isValid else { return false }
        if isExcluded(relativePath: relativePath) { return false }
        let includes = self.includes
        if includes.isEmpty { return true }
        let name = relativePath.split(separator: "/").last.map(String.init) ?? relativePath
        return includes.contains { Self.matches($0, path: relativePath, name: name) }
    }

    /// Whether `relativePath`, or any directory above it, is excluded. A directory that is
    /// excluded can be skipped without being read.
    public func isExcluded(relativePath: String) -> Bool {
        let excludes = self.excludes
        if excludes.isEmpty { return false }
        let components = relativePath.split(separator: "/").map(String.init)
        var prefix = ""
        for component in components {
            prefix = prefix.isEmpty ? component : prefix + "/" + component
            if excludes.contains(where: { Self.matches($0, path: prefix, name: component) }) { return true }
        }
        return false
    }

    // MARK: - Parsing

    private static func rule(for pattern: String, isExclusion: Bool) -> Rule? {
        var pattern = pattern
        // `build/` means a directory of that name at any depth.
        if pattern.hasSuffix("/"), !pattern.dropLast().contains("/") {
            pattern = "**/" + pattern + "**"
        } else if pattern.hasSuffix("/") {
            pattern += "**"
        }
        if pattern.hasPrefix("/") { pattern.removeFirst() }
        guard !pattern.isEmpty else { return nil }
        let segments = pattern.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // `**` is a globstar only as a whole path segment; `a**b` is ambiguous.
        for segment in segments where segment.contains("**") && segment != "**" { return nil }
        guard !segments.contains(where: \.isEmpty) else { return nil }
        let isNameOnly = segments.count == 1
        guard let regex = try? NSRegularExpression(pattern: expression(for: segments), options: [.caseInsensitive]) else { return nil }
        return Rule(isExclusion: isExclusion, isNameOnly: isNameOnly, regex: regex)
    }

    private static func expression(for segments: [String]) -> String {
        var result = "^"
        for (index, segment) in segments.enumerated() {
            let isLast = index == segments.count - 1
            if segment == "**" {
                if !isLast {
                    // Any number of directories, including none.
                    result += "(?:[^/]+/)*"
                } else if index == 0 {
                    result += ".*"
                } else {
                    // `dir/**` is the directory itself and everything below it.
                    result.removeLast()
                    result += "(?:/.*)?"
                }
                continue
            }
            for character in segment {
                switch character {
                case "*": result += "[^/]*"
                case "?": result += "[^/]"
                default: result += NSRegularExpression.escapedPattern(for: String(character))
                }
            }
            if !isLast { result += "/" }
        }
        result += "$"
        return result
    }

    private static func matches(_ rule: Rule, path: String, name: String) -> Bool {
        let subject = rule.isNameOnly ? name : path
        return rule.regex.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil
    }
}
