import Foundation
import SubprocessKit

/// One progress report from a long git command (`fetch`, `push`, `clone`, `pull`).
public struct GitProgress: Sendable, Equatable {
    /// What git is doing: `Receiving objects`, `Resolving deltas`, `Compressing objects`…
    public var phase: String
    /// 0...1, or nil for a line that carries no percentage (`From host:repo`, `Cloning into 'x'…`).
    public var fraction: Double?
    /// The line as git wrote it, without the `remote: ` prefix.
    public var text: String

    public init(phase: String, fraction: Double?, text: String) {
        self.phase = phase
        self.fraction = fraction
        self.text = text
    }
}

public typealias GitProgressHandler = @Sendable (GitProgress) -> Void

/// Turns git's stderr (progress lines end in `\r`, other lines in `\n`) into `GitProgress` values.
/// It is a value type fed chunk by chunk, so a line split across two reads is joined.
public struct GitProgressParser: Sendable {
    private var decoder = UTF8ChunkDecoder()
    private var line = ""

    public init() {}

    public mutating func feed(_ data: Data) -> [GitProgress] {
        consume(decoder.feed(data))
    }

    /// The unterminated last line, once the stream has ended.
    public mutating func finish() -> [GitProgress] {
        var out = consume(decoder.finish())
        if let progress = Self.parseLine(line) { out.append(progress) }
        line = ""
        return out
    }

    private mutating func consume(_ text: String) -> [GitProgress] {
        var out: [GitProgress] = []
        for character in text {
            // `\r\n` is two terminators in a row; the empty line between them parses to nothing.
            if character == "\r" || character == "\n" {
                if let progress = Self.parseLine(line) { out.append(progress) }
                line = ""
            } else {
                line.append(character)
            }
        }
        return out
    }

    /// `Receiving objects:  45% (450/1000), 1.2 MiB | 3.4 MiB/s` → phase `Receiving objects`, 0.45.
    /// A line with no percentage is kept as a message with a nil fraction.
    public static func parseLine(_ raw: String) -> GitProgress? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("remote:") { text = String(text.dropFirst("remote:".count)).trimmingCharacters(in: .whitespaces) }
        guard !text.isEmpty else { return nil }
        if let colon = text.firstIndex(of: ":") {
            let phase = text[..<colon].trimmingCharacters(in: .whitespaces)
            let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let digits = rest.prefix(while: \.isNumber)
            if !digits.isEmpty, rest.dropFirst(digits.count).first == "%", let value = Double(digits) {
                return GitProgress(phase: phase, fraction: min(max(value / 100, 0), 1), text: text)
            }
        }
        return GitProgress(phase: text, fraction: nil, text: text)
    }
}

/// What one git command did, for the Git console.
public struct GitCommandRecord: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let date: Date
    /// The arguments after `git`, without the `-c core.quotepath=off` every run carries.
    public let arguments: [String]
    public let directory: URL
    public let exitStatus: Int32
    public let stderr: String
    /// The start of standard output, for a command that changes something (cut at 4 KB).
    public let output: String
    public let duration: TimeInterval

    public init(
        id: UUID = UUID(), date: Date = Date(), arguments: [String], directory: URL,
        exitStatus: Int32, stderr: String, output: String, duration: TimeInterval
    ) {
        self.id = id
        self.date = date
        self.arguments = arguments
        self.directory = directory
        self.exitStatus = exitStatus
        self.stderr = stderr
        self.output = output
        self.duration = duration
    }

    public var succeeded: Bool { exitStatus == 0 }

    /// Queries go through `--no-optional-locks`; everything else may change the repository.
    public var isReadOnly: Bool { arguments.first == "--no-optional-locks" }

    /// `git commit -m 'a message'`, quoted so it can be pasted into a shell.
    public var commandLine: String {
        let shown = isReadOnly ? Array(arguments.dropFirst()) : arguments
        return (["git"] + shown.map(Self.quote)).joined(separator: " ")
    }

    private static func quote(_ argument: String) -> String {
        let safe = argument.allSatisfy { $0.isLetter || $0.isNumber || "-_./=:@%+,".contains($0) }
        guard !safe || argument.isEmpty else { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Told about every command a runner finishes. It is called from a background context.
public protocol GitCommandObserving: Sendable {
    func gitCommandFinished(_ record: GitCommandRecord)
}

/// The environment network commands run with, so a host can plug in a credential helper.
public struct GitNetworkEnvironment: Sendable, Equatable {
    public var variables: [String: String]
    /// Adds `-o BatchMode=yes` to the user's own ssh command (`GIT_SSH_COMMAND`, else
    /// `core.sshCommand`, else `ssh`) so a prompt nobody can answer fails instead of waiting. The
    /// user's command is kept, not replaced.
    public var failsInsteadOfPrompting: Bool

    public init(variables: [String: String] = [:], failsInsteadOfPrompting: Bool = false) {
        self.variables = variables
        self.failsInsteadOfPrompting = failsInsteadOfPrompting
    }

    /// No prompt can be answered: HTTPS and ssh fail at once. The default until a host supplies a
    /// credential helper.
    public static let batchMode = GitNetworkEnvironment(
        variables: ["GIT_TERMINAL_PROMPT": "0"],
        failsInsteadOfPrompting: true
    )
}
