import Foundation
import JavaIntelligence

/// One test case in the Test Results tab. Gradle and SwiftPM both land here; Java's parser result
/// converts through ``init(_:)``.
struct IDETestCaseResult: Identifiable, Sendable, Equatable {
    enum Status: String, Sendable, Equatable {
        case passed
        case failed
        case skipped
        case aborted
    }

    var className: String
    var name: String
    var status: Status
    var duration: TimeInterval
    var message: String?
    var stackTrace: String?
    var sourceFile: URL?
    var line: Int?
    var output: String?

    var id: String { "\(className).\(name)" }

    init(
        className: String,
        name: String,
        status: Status,
        duration: TimeInterval = 0,
        message: String? = nil,
        stackTrace: String? = nil,
        sourceFile: URL? = nil,
        line: Int? = nil,
        output: String? = nil
    ) {
        self.className = className
        self.name = name
        self.status = status
        self.duration = duration
        self.message = message
        self.stackTrace = stackTrace
        self.sourceFile = sourceFile
        self.line = line
        self.output = output
    }

    init(_ java: JavaTestCaseResult) {
        let status: Status
        switch java.status {
        case .passed: status = .passed
        case .failed: status = .failed
        case .skipped: status = .skipped
        case .aborted: status = .aborted
        }
        self.init(
            className: java.className, name: java.name, status: status, duration: java.duration,
            message: java.message, stackTrace: java.stackTrace, sourceFile: java.sourceFile,
            line: java.line, output: java.output
        )
    }
}
