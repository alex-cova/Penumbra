import Foundation

/// Outcome of one test or suite.
public enum JavaTestStatus: String, Sendable, Hashable, Codable {
    case passed
    case failed
    /// The test threw outside an assertion (JUnit XML `<error>`); marker events report it as `failed`.
    case errored
    case skipped
}

/// One structured event printed by ``GradleTestEventsScript``.
public enum JavaTestEvent: Sendable, Hashable {
    case suiteStarted(taskPath: String, className: String)
    case suiteFinished(taskPath: String, className: String, status: JavaTestStatus, durationMs: Int)
    case testStarted(taskPath: String, className: String, methodName: String)
    case testFinished(taskPath: String, className: String, methodName: String, status: JavaTestStatus, durationMs: Int)

    public var taskPath: String {
        switch self {
        case .suiteStarted(let t, _), .suiteFinished(let t, _, _, _),
             .testStarted(let t, _, _), .testFinished(let t, _, _, _, _):
            return t
        }
    }
}

public enum GradleTestEventParser {
    /// Parses one output line. Returns `nil` for anything that is not a marker line. The marker may
    /// be preceded by other text (interleaved output from a forked process on the same line).
    public static func parse(line: String) -> JavaTestEvent? {
        guard let range = line.range(of: GradleTestEventsScript.markerPrefix) else { return nil }
        let payload = line[range.upperBound...]
        let fields = payload.split(separator: "|", omittingEmptySubsequences: false).map { unescape(String($0)) }
        // event|task|class|method|result|duration
        guard fields.count >= 5 else { return nil }
        let task = fields[1]
        let className = fields[2]
        let method = fields[3]
        let result = fields[4]
        let duration = fields.count > 5 ? Int(fields[5].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 : 0
        switch fields[0] {
        case "suiteStart":
            return .suiteStarted(taskPath: task, className: className)
        case "suiteEnd":
            guard let status = status(result) else { return nil }
            return .suiteFinished(taskPath: task, className: className, status: status, durationMs: duration)
        case "testStart":
            return .testStarted(taskPath: task, className: className, methodName: method)
        case "testEnd":
            guard let status = status(result) else { return nil }
            return .testFinished(taskPath: task, className: className, methodName: method, status: status, durationMs: duration)
        default:
            return nil
        }
    }

    private static func status(_ raw: String) -> JavaTestStatus? {
        switch raw.trimmingCharacters(in: .whitespaces) {
        case "PASSED": return .passed
        case "FAILED": return .failed
        case "SKIPPED": return .skipped
        default: return nil
        }
    }

    /// Reverses the script's escaping: `\\`, `\p` (pipe), `\n`, `\r`.
    static func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var result = ""
        var iterator = text.makeIterator()
        while let ch = iterator.next() {
            guard ch == "\\" else { result.append(ch); continue }
            guard let next = iterator.next() else { result.append(ch); break }
            switch next {
            case "\\": result.append("\\")
            case "p": result.append("|")
            case "n": result.append("\n")
            case "r": result.append("\r")
            default: result.append(ch); result.append(next)
            }
        }
        return result
    }
}
