import Darwin
import Foundation

public struct GradleTestEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case executionStarted, executionFinished, taskStarted, taskFinished
        case suiteStarted, suiteFinished, testStarted, testFinished, output, cancelled, infrastructureError
    }

    public enum Outcome: String, Codable, Sendable {
        case running, passed, failed, skipped, cancelled, aborted, unknown
    }

    public struct Failure: Codable, Equatable, Sendable {
        public let type: String
        public let message: String?
        public let stackTrace: String?
        public let expected: String?
        public let actual: String?
    }

    public struct Output: Codable, Equatable, Sendable {
        public let offset: UInt64
        public let length: UInt64
        public let stream: String
    }

    public let version: Int
    public let sessionID: UUID
    public let sequence: UInt64
    public let timestamp: Int64
    public let kind: Kind
    public let build: String
    public let module: String?
    public let task: String?
    public let nodeID: String?
    public let parentID: String?
    public let name: String?
    public let className: String?
    public let methodName: String?
    public let outcome: Outcome?
    public let durationMs: Int64?
    public let failure: Failure?
    public let output: Output?
    public let report: String?
    public let disposition: String?
}


// Use the same filesystem identity as Gradle's canonical root. Resolve existing ancestors
// when a report directory has not been created yet.
public enum GradleBuildIdentity {
    public static func canonicalPath(_ url: URL) -> String {
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        while true {
            if let resolved = realpath(ancestor.path, nil) {
                defer { free(resolved) }
                return suffix.reversed().reduce(String(cString: resolved)) { path, component in
                    (path as NSString).appendingPathComponent(component)
                }
            }
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { return url.standardizedFileURL.path }
            suffix.append(ancestor.lastPathComponent)
            ancestor = parent
        }
    }
}
