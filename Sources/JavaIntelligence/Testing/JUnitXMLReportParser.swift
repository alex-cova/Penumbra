import Foundation

/// One `<testcase>` from a JUnit XML report.
public struct JavaTestResult: Sendable, Hashable {
    /// Binary class name from the report, e.g. `pkg.Outer$Inner`.
    public let className: String
    /// The method name without parameter types or an invocation suffix: `test(int)[1]` -> `test`.
    /// Empty when the report only names the invocation (`[1] arg`); a re-run filter then has to use
    /// the class alone.
    public let methodName: String
    /// The name exactly as the report has it (`test(int)[1]`, `[1] arg`, a `@DisplayName`).
    public let displayName: String
    public let status: JavaTestStatus
    public let durationSeconds: Double
    public let failureMessage: String?
    /// The exception class from `<failure type=…>` / `<error type=…>`.
    public let failureType: String?
    /// The text body of `<failure>` / `<error>`: the message line plus `at …` frames.
    public let stackTrace: String?
    /// The enclosing suite's `<system-out>` / `<system-err>` (shared by every case of that suite).
    public let systemOut: String
    public let systemErr: String

    public init(
        className: String,
        methodName: String,
        displayName: String,
        status: JavaTestStatus,
        durationSeconds: Double = 0,
        failureMessage: String? = nil,
        failureType: String? = nil,
        stackTrace: String? = nil,
        systemOut: String = "",
        systemErr: String = ""
    ) {
        self.className = className
        self.methodName = methodName
        self.displayName = displayName
        self.status = status
        self.durationSeconds = durationSeconds
        self.failureMessage = failureMessage
        self.failureType = failureType
        self.stackTrace = stackTrace
        self.systemOut = systemOut
        self.systemErr = systemErr
    }

    /// Whether this is one invocation of a parameterized/repeated test.
    public var isInvocation: Bool {
        displayName.hasPrefix("[") || displayName.hasSuffix("]")
    }

    /// The outermost class: `pkg.Outer` for `pkg.Outer$Inner`.
    public var outerClassName: String {
        className.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? className
    }
}

public enum JUnitXMLReportParser {
    /// Parses every `TEST-*.xml` under `directory` whose modification date is at or after `since`
    /// (so stale reports from an earlier run are ignored). Pass `nil` to take every file.
    public static func parse(directory: URL, since: Date?) -> [JavaTestResult] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        var results: [JavaTestResult] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where file.lastPathComponent.hasPrefix("TEST-") && file.pathExtension == "xml" {
            if let since {
                let modified = (try? file.resourceValues(forKeys: Set(keys)))?.contentModificationDate
                guard let modified, modified >= since else { continue }
            }
            if let data = try? Data(contentsOf: file) {
                results.append(contentsOf: parse(data: data))
            }
        }
        return results
    }

    public static func parse(data: Data) -> [JavaTestResult] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.parse()
        return delegate.results
    }

    /// `test(int)[1]` -> `test`; `[1] arg` -> ``; `plain()` -> `plain`.
    static func baseMethodName(_ name: String) -> String {
        if name.hasPrefix("[") { return "" }
        var base = Substring(name)
        if base.hasSuffix("]"), let open = base.lastIndex(of: "[") {
            base = base[..<open]
        }
        if let paren = base.firstIndex(of: "(") {
            base = base[..<paren]
        }
        return base.trimmingCharacters(in: .whitespaces)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        struct Pending {
            var className: String
            var name: String
            var time: Double
            var status: JavaTestStatus = .passed
            var message: String?
            var type: String?
            var trace: String?
        }

        var results: [JavaTestResult] = []
        private var suiteStart = 0
        private var suiteOut = ""
        private var suiteErr = ""
        private var suiteName = ""
        private var pending: Pending?
        private var text = ""
        private var inFailure = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            switch elementName {
            case "testsuite":
                suiteStart = results.count
                suiteOut = ""
                suiteErr = ""
                suiteName = attributeDict["name"] ?? ""
            case "testcase":
                pending = Pending(
                    className: attributeDict["classname"] ?? suiteName,
                    name: attributeDict["name"] ?? "",
                    time: Double(attributeDict["time"] ?? "") ?? 0
                )
            case "failure", "error":
                guard pending != nil else { break }
                pending?.status = elementName == "error" ? .errored : .failed
                pending?.message = attributeDict["message"]
                pending?.type = attributeDict["type"]
                inFailure = true
                text = ""
            case "skipped":
                pending?.status = .skipped
                pending?.message = attributeDict["message"]
            case "system-out", "system-err":
                text = ""
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            switch elementName {
            case "failure", "error":
                if inFailure {
                    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    pending?.trace = body.isEmpty ? nil : body
                    inFailure = false
                }
            case "system-out":
                // A testcase-level stream is folded into the suite's, in document order.
                suiteOut += text
            case "system-err":
                suiteErr += text
            case "testcase":
                if let p = pending {
                    results.append(JavaTestResult(
                        className: p.className,
                        methodName: JUnitXMLReportParser.baseMethodName(p.name),
                        displayName: p.name,
                        status: p.status,
                        durationSeconds: p.time,
                        failureMessage: p.message,
                        failureType: p.type,
                        stackTrace: p.trace
                    ))
                }
                pending = nil
            case "testsuite":
                let out = suiteOut.trimmingCharacters(in: .newlines)
                let err = suiteErr.trimmingCharacters(in: .newlines)
                for index in suiteStart..<results.count {
                    let r = results[index]
                    results[index] = JavaTestResult(
                        className: r.className, methodName: r.methodName, displayName: r.displayName,
                        status: r.status, durationSeconds: r.durationSeconds, failureMessage: r.failureMessage,
                        failureType: r.failureType, stackTrace: r.stackTrace, systemOut: out, systemErr: err
                    )
                }
            default:
                break
            }
        }
    }
}
