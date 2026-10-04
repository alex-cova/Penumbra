import Foundation

/// A shell command split into the simple commands it runs. Not a shell parser: it knows quotes,
/// escapes and the separators, and marks anything it would have to guess about as opaque so that no
/// rule or safe list ever approves it.
public enum CommandSegments {
    public struct Parsed: Sendable, Equatable {
        /// The simple commands, trimmed, in order. Split on `&&`, `||`, `;`, `|`, `&` and newlines.
        public var segments: [String]
        /// A substitution (`$(…)`, backticks, `<(…)`), a subshell, a heredoc or a stray parenthesis:
        /// what runs is not what the text says.
        public var isOpaque: Bool
        /// Output redirected to something other than `/dev/null` or another descriptor.
        public var hasRedirection: Bool
    }

    public static func parse(_ command: String) -> Parsed {
        var segments: [String] = []
        var current = ""
        var isOpaque = false
        var hasRedirection = false
        var inSingle = false
        var inDouble = false
        let characters = Array(command)
        var index = 0

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { segments.append(trimmed) }
            current = ""
        }
        func peek(_ offset: Int) -> Character? {
            index + offset < characters.count ? characters[index + offset] : nil
        }

        while index < characters.count {
            let character = characters[index]
            if inSingle {
                if character == "'" { inSingle = false }
                current.append(character)
                index += 1
                continue
            }
            if character == "\\" {
                current.append(character)
                if let next = peek(1) { current.append(next) }
                index += 2
                continue
            }
            if inDouble {
                if character == "\"" { inDouble = false }
                if character == "`" || (character == "$" && peek(1) == "(") { isOpaque = true }
                current.append(character)
                index += 1
                continue
            }

            switch character {
            case "'":
                inSingle = true
                current.append(character)
            case "\"":
                inDouble = true
                current.append(character)
            case "`":
                isOpaque = true
                current.append(character)
            case "$" where peek(1) == "(":
                isOpaque = true
                current.append(character)
            case "(", ")":
                isOpaque = true
                current.append(character)
            case "<" where peek(1) == "<" || peek(1) == "(":
                isOpaque = true
                current.append(character)
            case ">":
                if peek(1) == "(" { isOpaque = true }
                if !isHarmlessRedirect(characters, from: index) { hasRedirection = true }
                current.append(character)
            case "&" where peek(1) == "&", "|" where peek(1) == "|":
                flush()
                index += 1
            case ";", "|", "\n", "\r":
                flush()
            case "&":
                // `2>&1` and `&>` belong to a redirection; a lone `&` backgrounds the command.
                let before = current.last
                if before == ">" || peek(1) == ">" { current.append(character) } else { flush() }
            default:
                current.append(character)
            }
            index += 1
        }
        if inSingle || inDouble { isOpaque = true }
        flush()
        return Parsed(segments: segments, isOpaque: isOpaque, hasRedirection: hasRedirection)
    }

    /// `>/dev/null`, `2>&1`, `>&2`: output goes nowhere new.
    private static func isHarmlessRedirect(_ characters: [Character], from index: Int) -> Bool {
        var cursor = index + 1
        if cursor < characters.count, characters[cursor] == ">" { cursor += 1 }
        if cursor < characters.count, characters[cursor] == "&" {
            return cursor + 1 < characters.count && characters[cursor + 1].isNumber
        }
        while cursor < characters.count, characters[cursor] == " " { cursor += 1 }
        return String(characters[cursor...]).hasPrefix("/dev/null")
    }

    /// The words of one simple command with quotes removed.
    public static func words(_ segment: String) -> [String] {
        var words: [String] = []
        var current = ""
        var started = false
        var inSingle = false
        var inDouble = false
        var escaped = false
        for character in segment {
            if escaped {
                current.append(character)
                escaped = false
            } else if inSingle {
                if character == "'" { inSingle = false } else { current.append(character) }
            } else if character == "\\" {
                escaped = true
                started = true
            } else if inDouble {
                if character == "\"" { inDouble = false } else { current.append(character) }
            } else if character == "'" {
                inSingle = true
                started = true
            } else if character == "\"" {
                inDouble = true
                started = true
            } else if character == " " || character == "\t" {
                if started { words.append(current) }
                current = ""
                started = false
            } else {
                current.append(character)
                started = true
            }
        }
        if started { words.append(current) }
        return words
    }
}

/// Commands that only read, and are safe to run without asking in Auto mode. Strict on purpose: an
/// argument that could reach outside the project or a credential file, a variable, or a flag that
/// makes the command run something or write something sends the command back to the user.
public enum SafeCommands {
    private static let readers: Set<String> = [
        "ls", "pwd", "cat", "head", "tail", "wc", "rg", "grep", "which", "echo", "date", "basename", "dirname", "cd",
        "diff", "file",
    ]
    /// Commands whose non-flag words name files; the others take text or nothing.
    private static let fileReaders: Set<String> = ["ls", "cat", "head", "tail", "wc", "rg", "grep", "cd", "diff", "file"]
    private static let gitReaders: Set<String> = [
        "status", "diff", "log", "show", "blame", "rev-parse", "ls-files", "shortlog", "describe", "grep",
    ]
    private static let gitBranchFlags: Set<String> = ["-a", "-r", "-v", "-vv", "--list", "--show-current", "--all", "--remotes"]
    private static let findWriters: Set<String> = ["-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprint0", "-fprintf", "-fls"]

    public static func isSafe(_ segment: String, secretPatterns: [GlobPattern] = []) -> Bool {
        let words = CommandSegments.words(segment)
        guard let command = words.first, !command.contains("/"), !command.contains("=") else { return false }
        let arguments = Array(words.dropFirst())
        // A variable or glob-less expansion can name anything; a substitution is already opaque.
        guard !words.contains(where: { $0.contains("$") }) else { return false }

        switch command {
        case "find":
            guard !arguments.contains(where: findWriters.contains) else { return false }
            return arguments.allSatisfy { $0.hasPrefix("-") || $0 == "(" || $0 == ")" || $0 == "!" || isProjectPath($0, secretPatterns) }
        case "git":
            return isSafeGit(arguments, secretPatterns)
        case _ where readers.contains(command):
            // `rg --pre cmd` runs cmd on every file.
            guard !arguments.contains(where: { $0.hasPrefix("--pre") }) else { return false }
            guard fileReaders.contains(command) else { return true }
            return arguments.allSatisfy { $0.hasPrefix("-") || isProjectPath($0, secretPatterns) }
        default:
            return false
        }
    }

    private static func isSafeGit(_ arguments: [String], _ secretPatterns: [GlobPattern]) -> Bool {
        guard let sub = arguments.first, !sub.hasPrefix("-") else { return false }
        let rest = Array(arguments.dropFirst())
        switch sub {
        case "branch":
            return rest.allSatisfy(gitBranchFlags.contains)
        case "remote":
            return rest.isEmpty || rest == ["-v"]
        case _ where gitReaders.contains(sub):
            // `--output` writes a file; `--ext-diff` and `--textconv` run configured programs.
            guard !rest.contains(where: { $0.hasPrefix("--output") || $0 == "--ext-diff" || $0 == "--textconv" }) else { return false }
            return rest.allSatisfy { $0.hasPrefix("-") || isProjectPath($0, secretPatterns) }
        default:
            return false
        }
    }

    /// Not absolute, not home-relative, no `..` component, and not a likely credential file.
    static func isProjectPath(_ word: String, _ secretPatterns: [GlobPattern]) -> Bool {
        guard !word.hasPrefix("/"), !word.hasPrefix("~") else { return false }
        guard !word.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { return false }
        return !SecretFilePolicy.isLikelySecret(word, extra: secretPatterns)
    }
}
