import XCTest
@testable import JavaIntelligence

final class JDKLocatorTests: XCTestCase {
    private func makeFakeJDK(at directory: URL, version: String, implementor: String = "Test Vendor") throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("lib"), withIntermediateDirectories: true)
        let release = """
        JAVA_VERSION="\(version)"
        IMPLEMENTOR="\(implementor)"
        MODULES="java.base"
        """
        try release.write(to: directory.appendingPathComponent("release"), atomically: true, encoding: .utf8)
    }

    func testReleaseFileParserExtractsModernVersion() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeFakeJDK(at: dir, version: "24.0.2")
        let installation = try XCTUnwrap(ReleaseFileParser.parse(dir))
        XCTAssertEqual(installation.featureVersion, 24)
        XCTAssertEqual(installation.versionString, "24.0.2")
        XCTAssertEqual(installation.vendor, "Test Vendor")
    }

    func testReleaseFileParserExtractsLegacyVersion() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeFakeJDK(at: dir, version: "1.8.0_392")
        let installation = try XCTUnwrap(ReleaseFileParser.parse(dir))
        XCTAssertEqual(installation.featureVersion, 8)
    }

    func testReleaseFileParserReturnsNilWithoutReleaseFile() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertNil(ReleaseFileParser.parse(dir))
    }

    func testFeatureVersionParsingEdgeCases() {
        XCTAssertEqual(ReleaseFileParser.featureVersion(from: "17"), 17)
        XCTAssertEqual(ReleaseFileParser.featureVersion(from: "11.0.20+8"), 11)
        XCTAssertEqual(ReleaseFileParser.featureVersion(from: "1.8.0_392"), 8)
        XCTAssertNil(ReleaseFileParser.featureVersion(from: "not-a-version"))
    }

    func testDiscoverAllFindsJDKsUnderCandidateDirectory() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let vmDir = base.appendingPathComponent("Library/Java/JavaVirtualMachines")
        try makeFakeJDK(at: vmDir.appendingPathComponent("temurin-21.jdk/Contents/Home"), version: "21.0.1")
        try makeFakeJDK(at: vmDir.appendingPathComponent("temurin-17.jdk/Contents/Home"), version: "17.0.9")

        // JDKLocator's fixed search paths are relative to the real home directory, so exercise the
        // underlying parser + directory walk directly rather than trying to redirect `~`.
        let homes = try FileManager.default.contentsOfDirectory(at: vmDir, includingPropertiesForKeys: nil)
        let installations = homes.compactMap { ReleaseFileParser.parse($0.appendingPathComponent("Contents/Home")) }
        XCTAssertEqual(Set(installations.map(\.featureVersion)), [21, 17])
    }

    func testPickPrefersClosestVersionAtOrAboveMinimum() {
        let installations = [8, 11, 17, 21, 24].map { synthetic(featureVersion: $0) }
        let picked = JDKLocator.pick(from: installations, minimumFeatureVersion: 17)
        XCTAssertEqual(picked?.featureVersion, 17)
    }

    func testPickFallsBackToNewestWhenNoneMeetsMinimum() {
        let installations = [8, 11, 17].map { synthetic(featureVersion: $0) }
        let picked = JDKLocator.pick(from: installations, minimumFeatureVersion: 21)
        XCTAssertEqual(picked?.featureVersion, 17)
    }

    func testPickReturnsNewestWithNoMinimum() {
        let installations = [8, 11, 21, 17].map { synthetic(featureVersion: $0) }
        let picked = JDKLocator.pick(from: installations, minimumFeatureVersion: nil)
        XCTAssertEqual(picked?.featureVersion, 21)
    }

    func testPickReturnsNilForEmptyList() {
        XCTAssertNil(JDKLocator.pick(from: [], minimumFeatureVersion: nil))
        XCTAssertNil(JDKLocator.pick(from: [], minimumFeatureVersion: 17))
    }

    private func synthetic(featureVersion: Int) -> JDKInstallation {
        JDKInstallation(
            home: URL(fileURLWithPath: "/fake/jdk-\(featureVersion)"),
            featureVersion: featureVersion,
            versionString: "\(featureVersion).0.0",
            vendor: "Test"
        )
    }

    func testSelectHonorsExplicitOverride() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeFakeJDK(at: dir, version: "24.0.2")
        let locator = JDKLocator(environment: [:], processRunner: FakeProcessRunner(output: [:]))
        let selected = try XCTUnwrap(locator.select(preferring: dir))
        XCTAssertEqual(selected.featureVersion, 24)
    }

    func testDiscoverAllReadsJavaHomeEnvironmentVariable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeFakeJDK(at: dir, version: "24.0.2")
        let locator = JDKLocator(environment: ["JAVA_HOME": dir.path], processRunner: FakeProcessRunner(output: [:]))
        let all = locator.discoverAll()
        XCTAssertTrue(all.contains { $0.home.resolvingSymlinksInPath() == dir.resolvingSymlinksInPath() })
    }

    // MARK: - Real installed JDK (opt-in)

    func testRealMachineJDKIsDiscoverable() throws {
        guard let found = TestJDK.discovered else {
            throw XCTSkip("No JDK found on this machine")
        }
        let installation = try XCTUnwrap(ReleaseFileParser.parse(found.home))
        XCTAssertGreaterThanOrEqual(installation.featureVersion, 8)
        XCTAssertTrue(installation.hasCtSym || installation.hasJmods, "expected either ct.sym or jmods")
    }

    /// Same regression as `GradleCommandRunnerTests.testSystemLauncherClosesChildStandardInput`.
    /// `SystemProcessRunner` has no timeout of its own, so this waits on a background thread and
    /// fails the test if `cat` is still blocked after a few seconds.
    func testSystemProcessRunnerClosesChildStandardInput() {
        let finished = expectation(description: "cat exits")
        let box = ResultBox()
        DispatchQueue.global().async {
            let start = Date()
            do {
                let output = try SystemProcessRunner().run(executable: "/bin/cat", arguments: [])
                box.store(.success((output, Date().timeIntervalSince(start))))
            } catch {
                box.store(.failure(error))
            }
            finished.fulfill()
        }
        let result = XCTWaiter.wait(for: [finished], timeout: 5)
        XCTAssertEqual(result, .completed, "cat should see immediate EOF on a closed stdin, not block on an inherited terminal")
        guard result == .completed else { return }
        switch box.value {
        case .success(let (output, elapsed)):
            XCTAssertEqual(output, "")
            XCTAssertLessThan(elapsed, 5)
        case .failure(let error):
            XCTFail("unexpected error: \(error)")
        case nil:
            XCTFail("cat finished without a result")
        }
    }
}

/// Cross-thread handoff for the stdin regression. The runner blocks, so the result is written
/// from a background queue and read only after the expectation is fulfilled.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<(String, TimeInterval), Error>?

    func store(_ result: Result<(String, TimeInterval), Error>) {
        lock.lock()
        stored = result
        lock.unlock()
    }

    var value: Result<(String, TimeInterval), Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private struct FakeProcessRunner: ProcessRunning {
    let output: [String: String]
    func run(executable: String, arguments: [String], currentDirectory: URL?, environment: [String: String]?) throws -> String {
        output[executable] ?? ""
    }
}
