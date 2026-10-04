import Foundation

/// What the user is asked before a command-risk tool runs: the command, where it runs, why the
/// model wants it, and anything the user should weigh. Built by the tool; the session adds the call.
public struct ApprovalRequest: Sendable, Equatable, Identifiable {
    public var callID: String
    public var toolName: String
    public var title: String
    /// The text the user may edit before approving: a shell command, a Gradle command line.
    public var command: String
    public var workingDirectory: String?
    /// The model's own stated reason.
    public var reason: String?
    /// Patterns that deserve a second look (`sudo`, `git push --force`). A warning, not a block:
    /// approval is the control.
    public var warnings: [String]
    /// Other facts for the card, such as files with the user's own unsaved changes.
    public var notes: [String]
    /// The JSON argument that holds `command`, if the user may edit it before approving.
    public var editableArgument: String?
    /// For an edit awaiting approval: what it would change, as a unified diff.
    public var diff: String?

    public var id: String { callID }

    public init(
        title: String,
        command: String,
        workingDirectory: String? = nil,
        reason: String? = nil,
        warnings: [String] = [],
        notes: [String] = [],
        editableArgument: String? = nil,
        diff: String? = nil,
        callID: String = "",
        toolName: String = ""
    ) {
        self.callID = callID
        self.toolName = toolName
        self.title = title
        self.command = command
        self.workingDirectory = workingDirectory
        self.reason = reason
        self.warnings = warnings
        self.notes = notes
        self.editableArgument = editableArgument
        self.diff = diff
    }
}

public enum ApprovalDecision: Sendable, Equatable {
    case approve
    /// Run with the user's own version of the editable argument.
    case approveEditing(String)
    /// An optional note goes back to the model so it can adjust.
    case deny(note: String?)
}

/// How much the agent does on its own. Reads never ask. Commands always ask (see `ApprovalPolicy`).
public enum AutonomyMode: String, Sendable, Equatable, Codable, CaseIterable {
    /// Edits apply at once, checkpointed so a run can be reverted. The default.
    case autoApplyEdits
    /// Every edit shows its diff first and waits for Apply or Reject.
    case approveEachEdit
    /// The model is not given the tools that change files or run commands, so it can only look and propose.
    case planOnly

    /// Whether a tool of this risk is offered to the model.
    public func offers(_ risk: ToolRisk) -> Bool {
        switch self {
        case .planOnly: risk == .read
        case .autoApplyEdits, .approveEachEdit: true
        }
    }
}

/// What an edit tool would do, worked out without doing it.
public struct EditPreview: Sendable, Equatable {
    public var summary: String
    public var diff: String

    public init(summary: String, diff: String) {
        self.summary = summary
        self.diff = diff
    }
}

/// Whether command-risk tools ask first. Reads never ask, and edits ask only in `approveEachEdit`.
public enum ApprovalPolicy: Sendable, Equatable {
    case askForCommands
    /// For the eval harness and tests only: nothing is shown to a user.
    case approveAll
}

/// Patterns in a command worth a second look. Never a block: the user decides.
public enum CommandWarnings {
    private static let rules: [(pattern: String, message: String)] = [
        (#"(^|[;&|(]\s*|\s)sudo(\s|$)"#, "Runs with administrator rights (sudo)."),
        (#"\brm\s+(-[a-zA-Z]*[rR][a-zA-Z]*\s+)+(-[a-zA-Z]+\s+)*(/|~|\$HOME|\*|\.)(\s|$|/\*)"#, "Recursively deletes a broad location."),
        (#"\bgit\s+push\b.*(\s--force\b|\s-f\b|--force-with-lease)"#, "Force-pushes, which can overwrite remote history."),
        (#"\bgit\s+reset\s+--hard\b"#, "Discards uncommitted changes (git reset --hard)."),
        (#"\bgit\s+clean\b.*-[a-zA-Z]*f"#, "Deletes untracked files (git clean)."),
        (#"\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(sh|bash|zsh)\b"#, "Pipes a download straight into a shell."),
        (#"\bchmod\s+(-R\s+)?[0-7]*777\b"#, "Makes files writable by everyone (chmod 777)."),
        (#"\b(mkfs|diskutil\s+(erase|partition)|dd\s+if=)"#, "Can overwrite or erase a disk."),
        (#">\s*/dev/(sd|disk|rdisk)"#, "Writes straight to a disk device."),
        (#":\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:"#, "A fork bomb."),
    ]

    public static func warnings(for command: String) -> [String] {
        rules.compactMap { rule in
            command.range(of: rule.pattern, options: .regularExpression) != nil ? rule.message : nil
        }
    }
}

public enum OutputTruncation {
    /// Keeps the start and, more of, the end of long output: a build's verdict is at the bottom.
    /// Cuts on line boundaries when it can, and says how much it left out.
    public static func headAndTail(_ text: String, maxCharacters: Int, headShare: Double = 0.3) -> String {
        guard text.count > maxCharacters, maxCharacters > 40 else { return text }
        let headCount = Int(Double(maxCharacters) * headShare)
        let tailCount = maxCharacters - headCount

        var head = String(text.prefix(headCount))
        if let newline = head.lastIndex(of: "\n"), head.distance(from: newline, to: head.endIndex) < headCount / 2 {
            head = String(head[..<newline])
        }
        var tail = String(text.suffix(tailCount))
        if let newline = tail.firstIndex(of: "\n"), tail.distance(from: tail.startIndex, to: newline) < tailCount / 2 {
            tail = String(tail[tail.index(after: newline)...])
        }
        let omitted = text.count - head.count - tail.count
        return head + "\n[… \(omitted) characters omitted from the middle …]\n" + tail
    }
}
