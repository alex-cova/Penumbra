import Foundation

/// The `xcodebuild test` commands behind Run Tests for an Xcode project, and the `xcresulttool`
/// reading of their result bundles. Pure: nothing here starts a process.
///
/// Tests run on the Mac with no `-destination`: the template targets are logic-test bundles with no
/// host app. Selection is `-only-testing:<target>[/<class>[/<method>]]`, and every run writes a
/// result bundle (`-resultBundlePath`) that `xcresulttool get test-results tests` turns into the
/// shared `JavaTestRunResult` shape the Test Results tab reads.
public enum XcodeTestCommand {
    /// `xcodebuild test -project <project> -scheme <scheme> -destination <destination>
    /// -derivedDataPath <cache> -resultBundlePath <cache>/<n>.xcresult [-enableCodeCoverage YES]
    /// [-only-testing <target>[/<class>[/<method>]]]…`, as the plan fixed it. Nothing is written
    /// into the project: the build and the bundle both live in the cache.
    public static func testArguments(
        project: URL? = nil, scheme: String, destination: String? = nil,
        derivedDataPath: URL? = nil, resultBundlePath: URL? = nil,
        tests: [String] = [], coverage: Bool = false
    ) -> [String] {
        var arguments = ["test"]
        if let project { arguments += ["-project", project.path] }
        arguments += ["-scheme", scheme]
        if let destination { arguments += ["-destination", destination] }
        if let derivedDataPath { arguments += ["-derivedDataPath", derivedDataPath.path] }
        if let resultBundlePath { arguments += ["-resultBundlePath", resultBundlePath.path] }
        if coverage { arguments += ["-enableCodeCoverage", "YES"] }
        for test in tests { arguments += ["-only-testing", test] }
        return arguments
    }

    /// The schemes `xcodebuild -list -json` knows, in its order.
    public static func schemes(from output: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              let project = json["project"] as? [String: Any],
              let schemes = project["schemes"] as? [String] else { return [] }
        return schemes
    }

    /// `xcodebuild build -project <project> -scheme <scheme> -configuration <configuration>
    /// -derivedDataPath <cache> build`: a Release build into the cache, for Profile.
    public static func buildArguments(
        project: URL? = nil, scheme: String, configuration: String = "Release",
        derivedDataPath: URL? = nil
    ) -> [String] {
        var arguments = ["build"]
        if let project { arguments += ["-project", project.path] }
        arguments += ["-scheme", scheme, "-configuration", configuration]
        if let derivedDataPath { arguments += ["-derivedDataPath", derivedDataPath.path] }
        arguments += ["build"]
        return arguments
    }

    /// `xcodebuild -project <project> -scheme <scheme> -showBuildSettings -json`: where the last
    /// build left the product, for Profile.
    public static func showBuildSettingsArguments(project: URL? = nil, scheme: String) -> [String] {
        var arguments: [String] = []
        if let project { arguments += ["-project", project.path] }
        arguments += ["-scheme", scheme, "-showBuildSettings", "-json"]
        return arguments
    }

    /// The product executable from `-showBuildSettings -json`: `TARGET_BUILD_DIR` plus
    /// `EXECUTABLE_PATH` of the first setting that names both, else nil.
    public static func executableURL(from output: Data) -> URL? {
        guard let settings = try? JSONDecoder().decode([BuildSettings].self, from: output) else { return nil }
        for entry in settings {
            guard let directory = entry.buildSettings["TARGET_BUILD_DIR"],
                  let executable = entry.buildSettings["EXECUTABLE_PATH"],
                  !directory.isEmpty, !executable.isEmpty else { continue }
            return URL(fileURLWithPath: directory).appendingPathComponent(executable)
        }
        return nil
    }

    private struct BuildSettings: Decodable {
        var buildSettings: [String: String]
    }

    /// The `-only-testing` selector for a target, class, or method.
    public static func onlyTesting(target: String, class testClass: String? = nil, method: String? = nil) -> String {
        var selector = target
        if let testClass { selector += "/\(testClass)" }
        if let method { selector += "/\(method)" }
        return selector
    }

    /// `xcrun xcresulttool get test-results tests --path <bundle>`.
    public static func testResultArguments(resultBundlePath: URL) -> [String] {
        ["xcresulttool", "get", "test-results", "tests", "--path", resultBundlePath.path]
    }

    // MARK: - Results

    /// One test method's outcome, in the shared Test Results shape.
    public struct TestRun: Sendable, Equatable {
        public enum Status: Sendable, Equatable {
            case passed
            case failed
            case skipped
        }

        public var name: String
        public var className: String
        /// The test target that ran it (the xcresult `Target` node): the first `-only-testing`
        /// component when rerunning just this run.
        public var target: String
        public var status: Status
        public var duration: TimeInterval
        public var message: String?

        public init(name: String, className: String, target: String = "", status: Status, duration: TimeInterval = 0, message: String? = nil) {
            self.name = name
            self.className = className
            self.target = target
            self.status = status
            self.duration = duration
            self.message = message
        }
    }

    /// Test runs from `xcresulttool get test-results tests` JSON: the target → suite → case tree,
    /// flattened, intermediate levels of any other kind walked through.
    public static func runResults(from output: Data) throws -> [TestRun] {
        let document = try JSONDecoder().decode(TestResultsDocument.self, from: output)
        var runs: [TestRun] = []
        for node in document.testNodes ?? [] {
            collect(node, target: fallbackName(of: node), suite: nil, runs: &runs)
        }
        return runs.sorted {
            if $0.className == $1.className { return $0.name < $1.name }
            return $0.className < $1.className
        }
    }

    private static func collect(_ node: TestNode, target: String?, suite: String?, runs: inout [TestRun]) {
        let kind = node.nodeType ?? ""
        if kind == "Test Case" {
            guard let name = node.name else { return }
            runs.append(TestRun(
                name: name,
                className: suite ?? target ?? "",
                target: target ?? "",
                status: status(of: node),
                duration: node.seconds ?? 0,
                message: message(of: node)
            ))
            return
        }
        let childSuite: String?
        if kind == "Test Suite", let name = node.name {
            childSuite = className(ofSuite: name)
        } else {
            childSuite = suite
        }
        let childTarget = isTargetLevel(kind) ? (node.name ?? target) : target
        for child in node.children ?? [] {
            collect(child, target: childTarget, suite: childSuite, runs: &runs)
        }
    }

    /// The level carrying the test target: `xcresulttool` reports bundles (`Unit test bundle`,
    /// `UI test bundle`); `Target` stays accepted for older shapes.
    private static func isTargetLevel(_ kind: String) -> Bool {
        kind == "Target" || kind == "Unit test bundle" || kind == "UI test bundle"
    }

    private static func fallbackName(of node: TestNode) -> String? {
        node.nodeType.map(isTargetLevel) ?? false ? node.name : nil
    }

    /// `Module.Class` and `Class` both mean the class: Swift names never contain dots.
    private static func className(ofSuite suite: String) -> String {
        suite.split(separator: ".").last.map(String.init) ?? suite
    }

    private static func status(of node: TestNode) -> TestRun.Status {
        switch node.result {
        case "Passed", "Expected Failure": return .passed
        case "Skipped": return .skipped
        default: return .failed
        }
    }

    private static func message(of node: TestNode) -> String? {
        if let message = node.failureMessage, !message.isEmpty { return message }
        if let message = node.message, !message.isEmpty { return message }
        return node.failureSummaries?.compactMap { $0.message }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: - JSON

    private struct TestResultsDocument: Decodable {
        var testNodes: [TestNode]?
    }

    private struct TestNode: Decodable {
        var nodeType: String?
        var name: String?
        var result: String?
        var children: [TestNode]?
        var failureMessage: String?
        var message: String?
        var failureSummaries: [FailureSummary]?

        /// Either seconds as a number or a string like `"1.234s"`.
        var seconds: TimeInterval?

        private enum CodingKeys: String, CodingKey {
            case nodeType, name, result, children, failureMessage, message, failureSummaries
            case duration, durationInSeconds
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            nodeType = try container.decodeIfPresent(String.self, forKey: .nodeType)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            result = try container.decodeIfPresent(String.self, forKey: .result)
            children = try container.decodeIfPresent([TestNode].self, forKey: .children)
            failureMessage = try container.decodeIfPresent(String.self, forKey: .failureMessage)
            message = try container.decodeIfPresent(String.self, forKey: .message)
            failureSummaries = try container.decodeIfPresent([FailureSummary].self, forKey: .failureSummaries)
            let precise: Double?? = try? container.decodeIfPresent(Double.self, forKey: .durationInSeconds)
            let text: String?? = try? container.decodeIfPresent(String.self, forKey: .duration)
            let plain: Double?? = try? container.decodeIfPresent(Double.self, forKey: .duration)
            if let seconds = precise ?? nil {
                self.seconds = seconds
            } else if let duration = text ?? nil {
                self.seconds = Self.seconds(fromDuration: duration)
            } else if let duration = plain ?? nil {
                self.seconds = duration
            } else {
                seconds = nil
            }
        }

        private static func seconds(fromDuration duration: String) -> TimeInterval? {
            let trimmed = duration.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("s"), let value = Double(trimmed.dropLast()) { return value }
            return Double(trimmed)
        }
    }

    private struct FailureSummary: Decodable {
        var message: String?
    }
}
