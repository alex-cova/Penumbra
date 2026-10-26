import Foundation

/// Whether agent commands may run under the workspace Seatbelt profile. Direct builds only: the
/// Mac App Store build is already confined by the App Sandbox (visible at runtime through
/// `APP_SANDBOX_CONTAINER_ID`), and `sandbox-exec` cannot nest inside it.
nonisolated enum IDEAgentSandbox {
    static let executable = "/usr/bin/sandbox-exec"

    static var isAppSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    static var hasSandboxExec: Bool {
        FileManager.default.isExecutableFile(atPath: executable)
    }

    /// The Settings toggle hides itself when this is false, including when a future macOS removes
    /// `sandbox-exec`.
    static var isAvailable: Bool { !isAppSandboxed && hasSandboxExec }
}

/// The Seatbelt `workspace` profile text for one project root, after Codex workspace-write and
/// Grok's `workspace`. Seatbelt keeps the LAST matching rule, so the specific denies go last:
/// reads are allowed everywhere except credential paths, writes are confined to the project root,
/// `TMPDIR`, `/tmp`, `~/.gradle` and `~/.m2`, and `.git` plus Umbra's own config are read-only.
/// Network is allowed unless `blockNetwork` is set.
nonisolated enum IDEAgentSandboxProfile {
    /// Credential-bearing basenames, mirroring `SecretFilePolicy.isLikelySecret` (which matches on
    /// the lowercased name).
    static let secretBasenamePattern =
        #"(?i)/(\.env(\.[^/]*)?|[^/]*\.env|\.netrc|\.npmrc|\.pgpass|id_rsa[^/]*|id_ed25519[^/]*|id_ecdsa[^/]*|id_dsa[^/]*|[^/]*\.(pem|key|p12|pfx|keystore|jks))$"#

    static func make(
        projectRoot: String, home: String = NSHomeDirectory(),
        tmpdir: String = NSTemporaryDirectory(), secretGlobs: [String] = [],
        blockNetwork: Bool = false
    ) -> String {
        let root = (projectRoot as NSString).standardizingPath
        let resolvedHome = (home as NSString).standardizingPath
        let resolvedTmp = (tmpdir as NSString).standardizingPath
        var lines = ["(version 1)", "(deny default)"]
        lines.append(#"(allow file-read* file-write* (literal "/dev/null") (literal "/dev/zero") (literal "/dev/random") (literal "/dev/urandom") (literal "/dev/tty"))"#)
        lines.append("(allow process-exec* process-fork)")
        lines.append("(allow signal)")
        lines.append("(allow sysctl-read)")
        lines.append(#"(allow file-read* (subpath "/"))"#)
        var writes = ["(allow file-write*"]
        writes += writeAlternatives(root).map { #"(subpath "\#(escape($0))")"# }
        writes += writeAlternatives(resolvedHome + "/.gradle").map { #"(subpath "\#(escape($0))")"# }
        writes += writeAlternatives(resolvedHome + "/.m2").map { #"(subpath "\#(escape($0))")"# }
        writes += ["/tmp", "/private/tmp", resolvedTmp].map { #"(subpath "\#(escape($0))")"# }
        writes += [")"]
        lines.append(writes.joined(separator: " "))
        lines.append(blockNetwork ? "(deny network*)" : "(allow network*)")
        lines.append(#"(deny file-read* file-write* (regex #"\#(credentialDirPattern(home: resolvedHome))"))"#)
        lines.append(#"(deny file-write* (regex #"^(\#(regexAlternatives(root)))/\.git(/|$)"))"#)
        lines.append(#"(deny file-write* (regex #"^(\#(regexAlternatives(resolvedHome)))/Library/Application Support/com\.umbra\.editor(/|$)"))"#)
        lines.append(#"(deny file-read* file-write* (regex #"\#(secretBasenamePattern)"))"#)
        for glob in secretGlobs.map({ $0.trimmingCharacters(in: .whitespaces) })
            where !glob.isEmpty && !glob.hasPrefix("#") {
            lines.append(#"(deny file-read* file-write* (regex #"\#(globRegex(glob))"))"#)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// True when the run failed because the sandbox denied it: nonzero exit plus a Seatbelt
    /// marker. The shell lowercases the system message (`zsh: operation not permitted`), so the
    /// match is case-insensitive.
    static func denialDetected(exitCode: Int32?, output: String) -> Bool {
        guard exitCode != nil && exitCode != 0 else { return false }
        let folded = output.lowercased()
        return folded.contains("operation not permitted") || folded.contains("deny(1)")
    }

    static func credentialDirPattern(home: String) -> String {
        let h = regexAlternatives((home as NSString).standardizingPath)
        return #"^(\#(h))/(\.ssh|\.aws|\.config/gh|Library/Keychains)(/|$)"#
    }

    /// Regex alternation over the symlink-tolerant forms of a path.
    static func regexAlternatives(_ path: String) -> String {
        writeAlternatives(path).map(regexEscape).joined(separator: "|")
    }

    /// `/tmp` and `/var` resolve under `/private`, where the sandbox sees them: match both forms.
    static func writeAlternatives(_ path: String) -> [String] {
        let standardized = (path as NSString).standardizingPath
        if standardized == "/tmp" || standardized.hasPrefix("/tmp/")
            || standardized == "/var" || standardized.hasPrefix("/var/") {
            return [standardized, "/private" + standardized]
        }
        return [standardized]
    }

    static func escape(_ literal: String) -> String {
        literal.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func regexEscape(_ literal: String) -> String {
        var result = ""
        for scalar in literal.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "/" {
                result.unicodeScalars.append(scalar)
            } else {
                result += "\\" + String(scalar)
            }
        }
        return result
    }

    /// Best-effort glob to regex over full paths: `**/` crosses folders, `*` stays in one.
    static func globRegex(_ glob: String) -> String {
        var pattern = ""
        var index = glob.startIndex
        while index < glob.endIndex {
            if glob[index...].hasPrefix("**/") {
                pattern += "(.*/)?"
                index = glob.index(index, offsetBy: 3)
            } else if glob[index] == "*" {
                // A `*` followed later by `/` still stays in its folder; `**` crosses it.
                let rest = glob[glob.index(after: index)...]
                if rest.hasPrefix("*") {
                    pattern += ".*"
                    index = glob.index(index, offsetBy: 2)
                } else {
                    pattern += "[^/]*"
                    index = glob.index(after: index)
                }
            } else if glob[index] == "?" {
                pattern += "[^/]"
                index = glob.index(after: index)
            } else {
                pattern += regexEscape(String(glob[index]))
                index = glob.index(after: index)
            }
        }
        if pattern.hasPrefix("/") { return "^" + pattern + "$" }
        return "(?i)/" + pattern + "$"
    }
}

/// One session's sandbox choice: the profile text plus first-use consent. Fresh per session, so a
/// mid-run toggle flip never affects the live run.
final class IDEAgentSandboxChoice: @unchecked Sendable {
    let profile: String
    private let lock = NSLock()
    private var consented: Bool

    init(profile: String, consented: Bool = false) {
        self.profile = profile
        self.consented = consented
    }

    var isConsented: Bool { lock.withLock { consented } }

    func grant() { lock.withLock { consented = true } }
}
