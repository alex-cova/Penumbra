import Foundation
import SwiftIntelligence
import XCTest

/// Locates `Tests/PenumbraTests/Fixtures/XcodeTests` in the test bundle.
enum XcodeFixtures {
    static func url(_ name: String) -> URL {
        guard let resourceURL = Bundle.module.resourceURL else { fatalError("no resourceURL") }
        for candidate in [
            resourceURL.appendingPathComponent("XcodeTests/\(name)"),
            resourceURL.appendingPathComponent("Fixtures/XcodeTests/\(name)"),
        ] where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        fatalError("Could not locate XcodeTests/\(name) in \(resourceURL)")
    }
}

/// `xcodebuild test` builders and `xcresulttool` result parsing: all literal, no toolchain.
final class XcodeTestCommandTests: XCTestCase {
    func testTestArgumentsSelectTheSchemeAndOnlyTheSelectedTests() {
        XCTAssertEqual(XcodeTestCommand.testArguments(scheme: "MyApp"), ["test", "-scheme", "MyApp"])
        XCTAssertEqual(
            XcodeTestCommand.testArguments(
                project: URL(fileURLWithPath: "/tmp/MyApp.xcodeproj"),
                scheme: "MyApp",
                destination: "platform=macOS",
                derivedDataPath: URL(fileURLWithPath: "/tmp/cache/DerivedData"),
                resultBundlePath: URL(fileURLWithPath: "/tmp/cache/1.xcresult"),
                tests: ["MyAppTests/MyAppTests", "MyAppTests/Other/testExample"],
                coverage: true
            ),
            ["test",
             "-project", "/tmp/MyApp.xcodeproj",
             "-scheme", "MyApp",
             "-destination", "platform=macOS",
             "-derivedDataPath", "/tmp/cache/DerivedData",
             "-resultBundlePath", "/tmp/cache/1.xcresult",
             "-enableCodeCoverage", "YES",
             "-only-testing", "MyAppTests/MyAppTests",
             "-only-testing", "MyAppTests/Other/testExample"]
        )
    }

    func testSchemesListsWhatListKnows() throws {
        // Real `xcodebuild -list -json` from the app template (`XcodeTests/XcodeList.json`,
        // refreshed by the `XCLIST_FIXTURES=1` flow test run).
        let output = try Data(contentsOf: XcodeFixtures.url("XcodeList.json"))
        XCTAssertEqual(XcodeTestCommand.schemes(from: output), ["FlowApp", "FlowAppTests"])
        XCTAssertEqual(XcodeTestCommand.schemes(from: Data("not json".utf8)), [])
    }

    func testBuildArgumentsBuildReleaseIntoTheCache() {
        XCTAssertEqual(
            XcodeTestCommand.buildArguments(
                project: URL(fileURLWithPath: "/tmp/MyApp.xcodeproj"),
                scheme: "MyApp",
                derivedDataPath: URL(fileURLWithPath: "/tmp/cache/DerivedData")
            ),
            ["build",
             "-project", "/tmp/MyApp.xcodeproj",
             "-scheme", "MyApp",
             "-configuration", "Release",
             "-derivedDataPath", "/tmp/cache/DerivedData",
             "build"]
        )
    }

    func testShowBuildSettingsFindsTheProductExecutable() throws {
        XCTAssertEqual(
            XcodeTestCommand.showBuildSettingsArguments(
                project: URL(fileURLWithPath: "/tmp/MyApp.xcodeproj"), scheme: "MyApp"),
            ["-project", "/tmp/MyApp.xcodeproj", "-scheme", "MyApp", "-configuration", "Release",
             "-showBuildSettings", "-json"]
        )
        // Real `-showBuildSettings -json` from the app template (`XcodeTests/ShowBuildSettings.json`,
        // refreshed by the `XCSHOWBUILDSETTINGS_FIXTURES=1` coverage flow test run; the home
        // directory is sanitized, so only the suffix is asserted).
        let output = try Data(contentsOf: XcodeFixtures.url("ShowBuildSettings.json"))
        let executable = try XCTUnwrap(XcodeTestCommand.executableURL(from: output))
        XCTAssertTrue(
            executable.path.hasSuffix("ProbeApp.app/Contents/MacOS/ProbeApp"), executable.path)
        XCTAssertNil(XcodeTestCommand.executableURL(from: Data("[]".utf8)))
        // A run's joined output keeps stderr around the JSON; the array is still found,
        // even when the warnings carry their own brackets.
        let noisy = Data("note: [line]\n".utf8) + output
            + Data("2026-10-28 xcodebuild[38576:4360450] CoreSimulator is out of date\n".utf8)
        XCTAssertEqual(XcodeTestCommand.executableURL(from: noisy), executable)
    }

    func testOnlyTestingBuildsTargetClassAndMethodSelectors() {
        XCTAssertEqual(XcodeTestCommand.onlyTesting(target: "MyAppTests"), "MyAppTests")
        XCTAssertEqual(XcodeTestCommand.onlyTesting(target: "MyAppTests", class: "MyAppTests"), "MyAppTests/MyAppTests")
        XCTAssertEqual(
            XcodeTestCommand.onlyTesting(target: "MyAppTests", class: "MyAppTests", method: "testExample"),
            "MyAppTests/MyAppTests/testExample"
        )
    }

    func testTestResultArgumentsReadTheBundle() {
        XCTAssertEqual(
            XcodeTestCommand.testResultArguments(resultBundlePath: URL(fileURLWithPath: "/tmp/r.xcresult")),
            ["xcresulttool", "get", "test-results", "tests", "--path", "/tmp/r.xcresult"]
        )
    }

    func testRunResultsFlattensTheTargetSuiteCaseTree() throws {
        // Regenerated from a real `xcodebuild test` of the app template
        // (`IDEXcodeTestFlowTests` with `TEST_FIXTURES=1`).
        let runs = try XcodeTestCommand.runResults(from: Data(contentsOf: XcodeFixtures.url("TestResults.json")))
        XCTAssertEqual(runs.map(\.className), ["FlowAppTests", "FlowAppTests"])
        XCTAssertEqual(runs.map(\.name), ["testExample()", "testPerformanceExample()"])
        XCTAssertEqual(runs.map(\.status), [.passed, .passed])
        XCTAssertEqual(runs.map(\.target), ["FlowAppTests", "FlowAppTests"])
        XCTAssertEqual(runs.count, 2)
    }

    func testRunResultsWalksThroughUnknownIntermediateLevels() throws {
        let document = """
        {"testNodes": [{"nodeType": "Target", "name": "T", "children": [
          {"nodeType": "Test Plan", "name": "Plan", "children": [
            {"nodeType": "Test Suite", "name": "T.C", "children": [
              {"nodeType": "Test Case", "name": "testM()", "result": "Passed", "duration": 1.5}
            ]}
          ]}
        ]}]}
        """.data(using: .utf8)!
        let runs = try XcodeTestCommand.runResults(from: document)
        XCTAssertEqual(runs.map { "\($0.className).\($0.name)" }, ["C.testM()"])
        XCTAssertEqual(runs.first?.duration ?? -1, 1.5, accuracy: 0.001)
    }

    func testRunResultsHandlesNumericDurationsAndSkips() throws {
        let document = """
        {"testNodes": [{"nodeType": "Target", "name": "T", "children": [
          {"nodeType": "Test Suite", "name": "C", "children": [
            {"nodeType": "Test Case", "name": "testS()", "result": "Skipped", "duration": "0.00s"},
            {"nodeType": "Test Case", "name": "testE()", "result": "Expected Failure"},
            {"nodeType": "Test Case", "name": "testF()", "result": "Failed", "duration": "0.05s",
             "failureSummaries": [{"message": "XCTAssertEqual failed", "fileName": "F.swift", "lineNumber": 8}]}
          ]}
        ]}]}
        """.data(using: .utf8)!
        let runs = try XcodeTestCommand.runResults(from: document)
        XCTAssertEqual(runs.map(\.status), [.passed, .failed, .skipped])
        XCTAssertEqual(runs.map(\.target), ["T", "T", "T"])
        let failed = try XCTUnwrap(runs.first { $0.status == .failed })
        XCTAssertTrue(failed.message?.contains("XCTAssertEqual failed") ?? false, failed.message ?? "no message")
    }
}
