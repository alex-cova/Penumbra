import Foundation

public struct GitRebaseStep: Sendable, Equatable, Identifiable {
    public enum Action: String, Sendable, CaseIterable {
        case pick
        /// Keep the commit and change its message.
        case reword
        /// Stop after applying it so the user can amend it (continue from the banner).
        case edit
        /// Meld into the commit above, joining the two messages (or using `message`).
        case squash
        /// Meld into the commit above and drop this message.
        case fixup
        case drop
    }

    public var action: Action
    public let hash: String
    public let subject: String
    /// The final message of the commit this step ends up in, for a `reword`, or for the `pick`,
    /// `reword` or `edit` step that heads a group of `squash`/`fixup` steps. Nil keeps git's own.
    public var message: String?

    public var id: String { hash }

    public init(action: Action = .pick, hash: String, subject: String, message: String? = nil) {
        self.action = action
        self.hash = hash
        self.subject = subject
        self.message = message
    }
}

/// An interactive rebase worked out ahead of time: the commits oldest first with an action each.
/// `todoText` is the file git would have opened in an editor, so no editor is needed.
public struct GitRebasePlan: Sendable, Equatable {
    public var steps: [GitRebaseStep]

    public init(steps: [GitRebaseStep]) {
        self.steps = steps
    }

    /// Why the plan cannot run, or nil when it can.
    public func validationProblem() -> String? {
        let kept = steps.filter { $0.action != .drop }
        if steps.isEmpty { return "There are no commits to rebase." }
        if kept.isEmpty { return "Dropping every commit would leave nothing to rebase." }
        if let first = kept.first, first.action == .squash || first.action == .fixup {
            return "The first commit cannot be squashed or fixed up: there is nothing above it to join."
        }
        if Set(steps.map(\.hash)).count != steps.count { return "A commit appears twice in the plan." }
        if steps.contains(where: { ($0.action == .reword) && ($0.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "A reworded commit needs a message."
        }
        return nil
    }

    /// Whether git has anything to do: every step is a plain pick in the original order.
    public func changesNothing(originalOrder: [String]) -> Bool {
        steps.map(\.hash) == originalOrder && steps.allSatisfy { $0.action == .pick }
    }

    /// The todo list. A step whose final message is known is followed by an `exec` that sets it:
    /// after the commit itself for a pick/reword/edit with no squashes under it, else after the last
    /// squash or fixup of its group. `messagePath` names the file holding step `index`'s message.
    public func todoText(messagePath: (Int) -> String) -> String {
        var lines: [String] = []
        var index = 0
        while index < steps.count {
            let head = steps[index]
            var groupEnd = index
            if head.action != .drop, head.action != .squash, head.action != .fixup {
                while groupEnd + 1 < steps.count, steps[groupEnd + 1].action == .squash || steps[groupEnd + 1].action == .fixup {
                    groupEnd += 1
                }
            }
            for position in index ... groupEnd {
                let step = steps[position]
                lines.append("\(step.action == .reword ? "pick" : step.action.rawValue) \(step.hash) \(Self.oneLine(step.subject))")
                // `edit` stops here, so its message is set by `exec` only when nothing is squashed in.
                if step.action == .edit, position == groupEnd, head.message != nil, position == index {
                    lines.append(Self.amend(messagePath(index)))
                }
            }
            if head.message != nil, head.action != .drop, head.action != .edit || groupEnd > index {
                lines.append(Self.amend(messagePath(index)))
            }
            index = groupEnd + 1
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The indices whose messages are written to files.
    public var messageIndices: [Int] {
        steps.indices.filter { steps[$0].message != nil && steps[$0].action != .drop && steps[$0].action != .squash && steps[$0].action != .fixup }
    }

    private static func amend(_ path: String) -> String {
        "exec git commit --amend --no-verify --allow-empty --cleanup=strip -F \(shellQuoted(path))"
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A todo line ends at the first line break; a subject has none, but a pasted one might.
    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }
}

/// The plans a log context menu builds: each starts from the plain picks of `base..HEAD`.
extension GitRebasePlan {
    /// `hash` keeps its place and gets a new message.
    public func rewording(_ hash: String, to message: String) -> GitRebasePlan {
        var copy = self
        guard let index = copy.steps.firstIndex(where: { $0.hash == hash }) else { return self }
        copy.steps[index].action = .reword
        copy.steps[index].message = message
        return copy
    }

    public func dropping(_ hashes: Set<String>) -> GitRebasePlan {
        var copy = self
        for index in copy.steps.indices where hashes.contains(copy.steps[index].hash) {
            copy.steps[index].action = .drop
        }
        return copy
    }

    /// Melds `hashes` into the oldest of them: the others move up under it and become squashes. The
    /// commits between them that are not selected stay after the group, in their order. `message`
    /// is the group's final message; nil keeps git's combined one.
    public func squashing(_ hashes: Set<String>, message: String?) -> GitRebasePlan {
        guard let headIndex = steps.firstIndex(where: { hashes.contains($0.hash) }) else { return self }
        var result = Array(steps[..<headIndex])
        var head = steps[headIndex]
        head.action = .pick
        head.message = message
        result.append(head)
        for step in steps[(headIndex + 1)...] where hashes.contains(step.hash) {
            var squashed = step
            squashed.action = .squash
            squashed.message = nil
            result.append(squashed)
        }
        result += steps[(headIndex + 1)...].filter { !hashes.contains($0.hash) }
        return GitRebasePlan(steps: result)
    }

    /// Melds `hash` into the commit just before it in the plan, keeping that commit's message, and
    /// moves it right under that commit when something sits between them.
    public func fixingUp(_ hash: String, into parent: String) -> GitRebasePlan {
        guard let parentIndex = steps.firstIndex(where: { $0.hash == parent }),
              let index = steps.firstIndex(where: { $0.hash == hash }), index > parentIndex else { return self }
        var result = steps
        var moved = result.remove(at: index)
        moved.action = .fixup
        moved.message = nil
        result.insert(moved, at: parentIndex + 1)
        return GitRebasePlan(steps: result)
    }
}
