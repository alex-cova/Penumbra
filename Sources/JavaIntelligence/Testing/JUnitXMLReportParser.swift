import Foundation

/// Outcome of one test case parsed from Gradle's JUnit Platform / Surefire XML reports.
public struct JavaTestCaseResult: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable, Equatable {
        case passed
        case failed
        case skipped
        case aborted
    }

    public let className: String
    public let name: String
    public let status: Status
    public let duration: TimeInterval
    public let message: String?
    public let stackTrace: String?
    public let sourceFile: URL?
    public let line: Int?

    public init(
        className: String,
        name: String,
        status: Status,
        duration: TimeInterval = 0,
        message: String? = nil,
        stackTrace: String? = nil,
        sourceFile: URL? = nil,
        line: Int? = nil
    ) {
        self.className = className
        self.name = name
        self.status = status
        self.duration = duration
        self.message = message
        self.stackTrace = stackTrace
        self.sourceFile = sourceFile
        self.line = line
    }

    public var id: String { "\(className).\(name)" }
}

/// Aggregated result of one Gradle test task run.
public struct JavaTestRunResult: Sendable, Equatable {
    public let cases: [JavaTestCaseResult]
    public let passedCount: Int
    public let failedCount: Int
    public let skippedCount: Int
    public let duration: TimeInterval

    public init(cases: [JavaTestCaseResult]) {
        self.cases = cases
        passedCount = cases.filter { $0.status == .passed }.count
        failedCount = cases.filter { $0.status == .failed || $0.status == .aborted }.count
        skippedCount = cases.filter { $0.status == .skipped }.count
        duration = cases.reduce(0) { $0 + $1.duration }
    }
}

/// Parses JUnit Platform / Surefire `TEST-*.xml` files Gradle writes under `build/test-results/`.
public enum JUnitXMLReportParser {
    public static func parseReports(
        in directories: [URL],
        projectRoot: URL,
        sourceLookup: (String) -> URL? = { _ in nil }
    ) -> JavaTestRunResult {
        var cases: [JavaTestCaseResult] = []
        for directory in directories {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ) else { continue }
            for file in files where file.lastPathComponent.hasPrefix("TEST-") && file.pathExtension == "xml" {
                guard let data = try? Data(contentsOf: file),
                      let xml = String(data: data, encoding: .utf8) else { continue }
                cases.append(contentsOf: parseXML(xml, projectRoot: projectRoot, sourceLookup: sourceLookup))
            }
        }
        if cases.isEmpty {
            return JavaTestRunResult(cases: [])
        }
        return JavaTestRunResult(cases: cases.sorted { lhs, rhs in
            if lhs.className == rhs.className { return lhs.name < rhs.name }
            return lhs.className < rhs.className
        })
    }

    /// Fallback when XML is missing: Gradle's plain summary only.
    public static func parseGradleSummary(_ output: String) -> JavaTestRunResult {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var failed = 0
        var passed = 0
        var skipped = 0
        for line in lines {
            if let match = line.firstMatch(of: /(\d+) tests completed, (\d+) failed/) {
                passed = max(0, Int(match.1)! - Int(match.2)!)
                failed = Int(match.2)!
            }
            if let match = line.firstMatch(of: /(\d+) tests completed, (\d+) skipped, (\d+) failed/) {
                passed = max(0, Int(match.1)! - Int(match.2)! - Int(match.3)!)
                skipped = Int(match.2)!
                failed = Int(match.3)!
            }
        }
        guard passed + failed + skipped > 0 else { return JavaTestRunResult(cases: []) }
        var cases: [JavaTestCaseResult] = []
        for _ in 0..<passed {
            cases.append(JavaTestCaseResult(className: "Tests", name: "passed", status: .passed))
        }
        for index in 0..<failed {
            cases.append(JavaTestCaseResult(className: "Tests", name: "failed \(index + 1)", status: .failed))
        }
        for _ in 0..<skipped {
            cases.append(JavaTestCaseResult(className: "Tests", name: "skipped", status: .skipped))
        }
        return JavaTestRunResult(cases: cases)
    }

    private static func parseXML(
        _ xml: String,
        projectRoot: URL,
        sourceLookup: (String) -> URL?
    ) -> [JavaTestCaseResult] {
        guard let suite = XMLTestSuite(data: Data(xml.utf8)) else { return [] }
        return suite.testCases.map { testCase in
            let location = JavaTestStackTraceParser.location(
                in: testCase.stackTrace ?? testCase.message,
                projectRoot: projectRoot,
                className: testCase.className,
                sourceLookup: sourceLookup
            )
            return JavaTestCaseResult(
                className: testCase.className,
                name: testCase.name,
                status: testCase.status,
                duration: testCase.time,
                message: testCase.message,
                stackTrace: testCase.stackTrace,
                sourceFile: location?.file,
                line: location?.line
            )
        }
    }
}

/// Minimal DOM-free parser for Surefire XML (`testsuite` / `testcase` elements).
private struct XMLTestSuite {
    struct Case {
        let className: String
        let name: String
        let time: TimeInterval
        let status: JavaTestCaseResult.Status
        let message: String?
        let stackTrace: String?
    }

    let testCases: [Case]

    init?(data: Data) {
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse(), let suite = delegate.suite else { return nil }
        self.testCases = suite
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var suite: [Case]?
        private var cases: [Case] = []
        private var currentClass = ""
        private var currentName = ""
        private var currentTime: TimeInterval = 0
        private var failureMessage: String?
        private var failureBody: String?
        private var skippedMessage: String?
        private var elementStack: [String] = []

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            elementStack.append(elementName)
            switch elementName {
            case "testcase":
                currentClass = attributeDict["classname"] ?? attributeDict["class"] ?? ""
                currentName = attributeDict["name"] ?? ""
                currentTime = TimeInterval(attributeDict["time"] ?? "0") ?? 0
                failureMessage = nil
                failureBody = nil
                skippedMessage = nil
            case "failure", "error":
                failureMessage = attributeDict["message"]
            case "skipped":
                skippedMessage = attributeDict["message"]
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard let top = elementStack.last else { return }
            switch top {
            case "failure", "error":
                failureBody = (failureBody ?? "") + string
            default:
                break
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            if elementName == "testcase" {
                let status: JavaTestCaseResult.Status
                let message: String?
                let stack: String?
                if failureBody != nil || failureMessage != nil {
                    status = .failed
                    message = failureMessage
                    stack = failureBody
                } else if skippedMessage != nil {
                    status = .skipped
                    message = skippedMessage
                    stack = nil
                } else {
                    status = .passed
                    message = nil
                    stack = nil
                }
                cases.append(Case(
                    className: currentClass,
                    name: currentName,
                    time: currentTime,
                    status: status,
                    message: message,
                    stackTrace: stack
                ))
            }
            _ = elementStack.popLast()
        }

        func parserDidEndDocument(_ parser: XMLParser) {
            suite = cases
        }
    }
}

/// Maps assertion stack traces back to a project source line.
enum JavaTestStackTraceParser {
    struct Location {
        let file: URL
        let line: Int
    }

    static func location(
        in text: String?,
        projectRoot: URL,
        className: String,
        sourceLookup: (String) -> URL?
    ) -> Location? {
        guard let text else { return nil }
        let pattern = #/^\s*at\s+([\w.$]+)\(([\w.$]+\.java):(\d+)\)/#
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let match = line.firstMatch(of: pattern) else { continue }
            let fileName = String(match.2)
            guard let lineNumber = Int(match.3) else { continue }
            if let fromLookup = sourceLookup(className) {
                return Location(file: fromLookup, line: lineNumber)
            }
            if let found = findSource(named: fileName, under: projectRoot) {
                return Location(file: found, line: lineNumber)
            }
        }
        return nil
    }

    private static func findSource(named fileName: String, under root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == fileName {
            return url
        }
        return nil
    }
}
