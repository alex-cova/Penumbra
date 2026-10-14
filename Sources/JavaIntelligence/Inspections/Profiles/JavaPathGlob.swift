import Foundation

/// Glob matching for inspection scopes and file masks: `*` stays inside one path component,
/// `**` crosses directories (`**/` also matches no directory at all), `?` is one character.
/// A pattern without a `/` is matched against the file name alone, so `*Test.java` finds a
/// test in any folder.
public enum JavaPathGlob {
    private static let cache = Cache()

    public static func matches(pattern: String, path: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let regex = cache.regex(for: trimmed) else { return false }
        let subject = trimmed.contains("/") ? path : (path as NSString).lastPathComponent
        return regex.firstMatch(in: subject, range: NSRange(location: 0, length: (subject as NSString).length)) != nil
    }

    /// Whether `path` passes comma-separated masks. A mask starting with `!` excludes. With no
    /// include mask everything is included.
    public static func passes(masks: String, path: String) -> Bool {
        let entries = masks.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !entries.isEmpty else { return true }
        var included = entries.contains { !$0.hasPrefix("!") } ? false : true
        for entry in entries {
            if entry.hasPrefix("!") {
                if matches(pattern: String(entry.dropFirst()), path: path) { return false }
            } else if matches(pattern: entry, path: path) {
                included = true
            }
        }
        return included
    }

    static func regexPattern(for glob: String) -> String {
        var result = "^"
        let characters = Array(glob)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "*":
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    if index + 2 < characters.count, characters[index + 2] == "/" {
                        result += "(?:.*/)?"
                        index += 3
                    } else {
                        result += ".*"
                        index += 2
                    }
                    continue
                }
                result += "[^/]*"
            case "?":
                result += "[^/]"
            default:
                result += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }
        return result + "$"
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: NSRegularExpression] = [:]

        func regex(for glob: String) -> NSRegularExpression? {
            lock.lock()
            defer { lock.unlock() }
            if let cached = storage[glob] { return cached }
            guard let regex = try? NSRegularExpression(pattern: JavaPathGlob.regexPattern(for: glob)) else { return nil }
            if storage.count > 256 { storage.removeAll() }
            storage[glob] = regex
            return regex
        }
    }
}
