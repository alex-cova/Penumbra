import SubprocessKit
import XCTest
@testable import JavaIntelligence

/// Runs a real JVM with the JaCoCo agent and with Flight Recorder, then reads what they wrote.
/// Skipped without a JDK, without `jfr`, or (coverage) without the jars `fetch.sh` downloads.
final class JavaInstrumentationRealJDKTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("instr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func requireJDK() throws -> JDKInstallation {
        guard let found = TestJDK.discovered, let jdk = ReleaseFileParser.parse(found.home), jdk.javac != nil else {
            throw XCTSkip("No JDK with javac")
        }
        return jdk
    }

    private func run(_ executable: URL, _ arguments: [String], in workingDirectory: URL? = nil) async throws -> SubprocessResult {
        var request = SubprocessRequest(executable: executable.path, arguments: arguments)
        request.workingDirectory = workingDirectory
        request.timeout = .seconds(120)
        return try await SubprocessRunner.run(request)
    }

    private func compile(_ source: String, className: String, package: String, jdk: JDKInstallation) async throws -> URL {
        let sources = directory.appendingPathComponent("src/\(package)", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let file = sources.appendingPathComponent("\(className).java")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let classes = directory.appendingPathComponent("classes", isDirectory: true)
        try FileManager.default.createDirectory(at: classes, withIntermediateDirectories: true)
        let result = try await run(try XCTUnwrap(jdk.javac), ["-g", "-d", classes.path, file.path])
        XCTAssertTrue(result.exit.succeeded, result.stderr.text)
        return classes
    }

    private var toolchain: JavaCoverageToolchain? {
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Example/Umbra/Tools/JaCoCo/build")
        return try? JavaCoverageToolchain.locate(in: [dev])
    }

    func testCoverageOfAPlainMainEndToEnd() async throws {
        let jdk = try requireJDK()
        let toolchain = try XCTUnwrap(toolchain, "run Example/Umbra/Tools/JaCoCo/fetch.sh") as JavaCoverageToolchain
        if let reason = JavaCoverageToolchain.unsupportedLanguageLevel(jdk.featureVersion) { throw XCTSkip(reason) }
        let classes = try await compile("""
        package app;
        public class Calc {
            public static int classify(int n) {
                if (n < 0) {
                    return -1;
                }
                return 1;
            }
            public static int unused() {
                return 42;
            }
            public static void main(String[] args) {
                System.out.println(classify(5));
            }
        }
        """, className: "Calc", package: "app", jdk: jdk)

        let execution = directory.appendingPathComponent("run/main.exec")
        try FileManager.default.createDirectory(at: execution.deletingLastPathComponent(), withIntermediateDirectories: true)
        let agent = try XCTUnwrap(JavaCoverageCommand.agentArgument(
            agentJar: toolchain.agentJar, execFile: execution,
            includes: JavaCoverageCommand.includes(packages: ["app"])
        ))
        let java = jdk.home.appendingPathComponent("bin/java")
        let program = try await run(java, [agent, "-cp", classes.path, "app.Calc"])
        XCTAssertTrue(program.exit.succeeded, program.stderr.text)

        let sourceRoot = directory.appendingPathComponent("src")
        let report = try await JavaCoverageReportRunner.report(
            java: java, toolchain: toolchain, executionFiles: [execution], classDirectories: [classes],
            xmlOutput: directory.appendingPathComponent("run/report.xml"), name: "calc"
        ) { path in
            sourceRoot.appendingPathComponent(path)
        }
        let file = try XCTUnwrap(report.sourceFiles.first { $0.name == "Calc.java" })
        XCTAssertEqual(file.url?.lastPathComponent, "Calc.java")
        XCTAssertEqual(file.status(atLine: 4), .partial, "`if (n < 0)` took one branch of two")
        XCTAssertEqual(file.status(atLine: 5), .missed)
        XCTAssertEqual(file.status(atLine: 7), .covered)
        XCTAssertEqual(file.status(atLine: 10), .missed, "an unused method is in --classfiles, so it shows at 0 %")
        XCTAssertEqual(report.packages.map(\.name), ["app"])
    }

    func testReportWithoutExecutionDataSaysSo() async throws {
        let jdk = try requireJDK()
        let toolchain = try XCTUnwrap(toolchain, "run Example/Umbra/Tools/JaCoCo/fetch.sh") as JavaCoverageToolchain
        let classes = directory.appendingPathComponent("classes", isDirectory: true)
        try FileManager.default.createDirectory(at: classes, withIntermediateDirectories: true)
        do {
            _ = try await JavaCoverageReportRunner.report(
                java: jdk.home.appendingPathComponent("bin/java"), toolchain: toolchain,
                executionFiles: [directory.appendingPathComponent("missing.exec")], classDirectories: [classes],
                xmlOutput: directory.appendingPathComponent("r.xml")
            )
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? JavaCoverageReportError, .noExecutionData)
        }
    }

    func testProfileOfACPUBoundProgramEndToEnd() async throws {
        let jdk = try requireJDK()
        guard let jfr = jdk.jfr else { throw XCTSkip("This JDK has no jfr tool") }
        let classes = try await compile("""
        package app;
        public class Spin {
            static int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
            public static void main(String[] args) {
                long end = System.nanoTime() + 1_200_000_000L;
                while (System.nanoTime() < end) { fib(22); }
            }
        }
        """, className: "Spin", package: "app", jdk: jdk)
        let recording = directory.appendingPathComponent("run/recording.jfr")
        try FileManager.default.createDirectory(at: recording.deletingLastPathComponent(), withIntermediateDirectories: true)
        let option = try XCTUnwrap(JavaFlightRecorder.vmArgument(file: recording.path))
        let program = try await run(jdk.home.appendingPathComponent("bin/java"), [option, "-cp", classes.path, "app.Spin"])
        XCTAssertTrue(program.exit.succeeded, program.stderr.text)
        XCTAssertTrue(JavaFlightRecordingDetector.isRecording(at: recording))

        let summary = try await JavaRecordingImporter.summary(jfr: jfr, recording: recording)
        XCTAssertGreaterThan(summary.executionSamples, 10)

        let profile = try await JavaRecordingImporter.importProfile(jfr: jfr, recordings: [recording])
        XCTAssertEqual(profile.cpuSamples, summary.executionSamples)
        let hot = profile.cpu.hotMethods(symbols: profile.symbols, limit: 1)
        let top = try XCTUnwrap(hot.first)
        XCTAssertEqual(profile.symbols.qualifiedName(ofMethod: top.method), "app.Spin.fib")
        XCTAssertGreaterThan(Double(top.selfCount) / Double(profile.cpuSamples), 0.8)
        XCTAssertEqual(profile.truncatedSamples, 0, "stack depth 128 holds a 22-deep recursion")
    }

    func testCorruptRecordingReportsTheToolsOwnError() async throws {
        let jdk = try requireJDK()
        guard let jfr = jdk.jfr else { throw XCTSkip("This JDK has no jfr tool") }
        let bogus = directory.appendingPathComponent("bogus.jfr")
        try Data([0x46, 0x4C, 0x52, 0x00, 0x01, 0x02, 0x03]).write(to: bogus)
        do {
            _ = try await JavaRecordingImporter.importProfile(jfr: jfr, recordings: [bogus])
            XCTFail("expected an error")
        } catch let error as JavaRecordingImportError {
            guard case .toolFailed(let message) = error else { return XCTFail("\(error)") }
            XCTAssertFalse(message.isEmpty)
        }
    }
}
