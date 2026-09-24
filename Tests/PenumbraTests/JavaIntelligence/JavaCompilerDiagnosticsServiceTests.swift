import XCTest
import EditorIntelligence
@testable import JavaIntelligence

/// A launcher that never starts a process: it reads the buffer `javac` was told to compile and
/// answers from a closure, so tests control the compiler's output and timing.
private actor FakeJavacLauncher: GradleProcessLaunching {
    typealias Responder = @Sendable (_ bufferPath: String, _ bufferText: String, _ call: Int) async throws -> GradleCommandResult

    private let responder: Responder
    private(set) var launchCount = 0
    private(set) var arguments: [[String]] = []

    init(_ responder: @escaping Responder) { self.responder = responder }

    func launch(_ command: GradleCommand, timeout: Duration, output: GradleOutputHandler?) async throws -> GradleCommandResult {
        launchCount += 1
        let call = launchCount
        arguments.append(command.arguments)
        let path = command.arguments.last ?? ""
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return try await responder(path, text, call)
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(URL, [Diagnostic])] = []
    func append(_ url: URL, _ diagnostics: [Diagnostic]) { lock.lock(); stored.append((url, diagnostics)); lock.unlock() }
    var results: [(URL, [Diagnostic])] { lock.lock(); defer { lock.unlock() }; return stored }
}

final class JavaCompilerDiagnosticsServiceTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    private func makeConfiguration(kind: JavacProjectKind = .plainFolder) throws -> JavaCompilerDiagnosticsService.Configuration {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("javac-svc-\(UUID().uuidString)")
        directories.append(root)
        let home = root.appendingPathComponent("jdk")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let javac = home.appendingPathComponent("bin/javac")
        try "#!/bin/sh\n".write(to: javac, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: javac.path)
        return .init(
            kind: kind,
            jdk: JDKInstallation(home: home, featureVersion: 21, versionString: "21.0.1", vendor: nil),
            projectRoot: root,
            workDirectory: root.appendingPathComponent("work")
        )
    }

    private func makeDocument(text: String, version: Int = 0, url: URL = URL(fileURLWithPath: "/proj/Foo.java"), language: String = "java") -> Document {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(
            id: DocumentID(), url: url, displayName: url.lastPathComponent,
            contentSnapshot: TextSnapshot(version: version, text: text),
            selection: Selection(range: EditorIntelligence.TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: language
        )
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: @escaping () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }

    func testMapsCompilerOutputToDiagnosticRanges() async throws {
        let text = "class Foo {\n    Strin x;\n}\n"
        let launcher = FakeJavacLauncher { path, _, _ in
            .init(exitCode: 1, stdout: "", stderr: """
            \(path):2: error: cannot find symbol
                Strin x;
                ^
              symbol:   class Strin
              location: class Foo
            1 error
            """)
        }
        let service = JavaCompilerDiagnosticsService(launcher: launcher, idleDelay: .milliseconds(10))
        let box = ResultBox()
        await service.setResultHandler { box.append($0, $1) }
        await service.configure(try makeConfiguration())

        await service.compileNow(makeDocument(text: text))
        try await waitUntil { !box.results.isEmpty }

        let diagnostics = try XCTUnwrap(box.results.first?.1)
        XCTAssertEqual(diagnostics.count, 1)
        let diagnostic = diagnostics[0]
        XCTAssertEqual(diagnostic.severity, .error)
        XCTAssertEqual(diagnostic.source, "javac")
        XCTAssertTrue(diagnostic.message.hasPrefix("cannot find symbol"))
        XCTAssertEqual(diagnostic.range.start.line, 1)
        XCTAssertEqual(diagnostic.range.start.column, 4)
        let range = NSRange(location: diagnostic.range.start.utf16Offset, length: diagnostic.range.end.utf16Offset - diagnostic.range.start.utf16Offset)
        XCTAssertEqual((text as NSString).substring(with: range), "Strin")
    }

    func testCompilesTheEditorsTextNotTheFileOnDisk() async throws {
        let launcher = FakeJavacLauncher { _, bufferText, _ in
            XCTAssertEqual(bufferText, "class Unsaved {}")
            return .init(exitCode: 0, stdout: "", stderr: "")
        }
        let service = JavaCompilerDiagnosticsService(launcher: launcher)
        await service.configure(try makeConfiguration())
        await service.compileNow(makeDocument(text: "class Unsaved {}"))
        try await waitUntil { await launcher.launchCount == 1 }
    }

    func testUnchangedTextIsServedFromCacheWithoutRecompiling() async throws {
        let launcher = FakeJavacLauncher { path, _, _ in
            .init(exitCode: 1, stdout: "", stderr: "\(path):1: error: boom\nclass Foo {}\n^\n1 error\n")
        }
        let service = JavaCompilerDiagnosticsService(launcher: launcher, idleDelay: .milliseconds(10))
        let box = ResultBox()
        await service.setResultHandler { box.append($0, $1) }
        await service.configure(try makeConfiguration())
        let document = makeDocument(text: "class Foo {}")

        await service.compileNow(document)
        try await waitUntil { !box.results.isEmpty }

        let served = await service.diagnostics(for: document)
        XCTAssertEqual(served.map(\.message), ["boom"])
        await service.compileNow(document)
        try await Task.sleep(nanoseconds: 100_000_000)
        let launches = await launcher.launchCount
        XCTAssertEqual(launches, 1)
    }

    func testForcedCompileRerunsForUnchangedText() async throws {
        let launcher = FakeJavacLauncher { _, _, _ in .init(exitCode: 0, stdout: "", stderr: "") }
        let service = JavaCompilerDiagnosticsService(launcher: launcher)
        let box = ResultBox()
        await service.setResultHandler { box.append($0, $1) }
        await service.configure(try makeConfiguration())
        let document = makeDocument(text: "class Foo {}")

        await service.compileNow(document)
        try await waitUntil { box.results.count == 1 }
        await service.compileNow(document, force: true)
        try await waitUntil { box.results.count == 2 }
        let launches = await launcher.launchCount
        XCTAssertEqual(launches, 2)
    }

    func testDiagnosticsForEditedTextReturnsPreviousResultAndSchedulesCompile() async throws {
        let launcher = FakeJavacLauncher { path, text, _ in
            let message = text.contains("second") ? "second problem" : "first problem"
            return .init(exitCode: 1, stdout: "", stderr: "\(path):1: error: \(message)\nx\n^\n1 error\n")
        }
        let service = JavaCompilerDiagnosticsService(launcher: launcher, idleDelay: .milliseconds(10))
        let box = ResultBox()
        await service.setResultHandler { box.append($0, $1) }
        await service.configure(try makeConfiguration())

        await service.compileNow(makeDocument(text: "class Foo { /* first */ }"))
        try await waitUntil { box.results.count == 1 }

        let edited = makeDocument(text: "class Foo { /* second */ }", version: 1)
        let immediate = await service.diagnostics(for: edited)
        XCTAssertEqual(immediate.map(\.message), ["first problem"], "stale result stays until the new compile lands")
        try await waitUntil { box.results.count == 2 }
        XCTAssertEqual(box.results[1].1.map(\.message), ["second problem"])
    }

    func testSupersededCompileIsCancelledAndNeverDelivered() async throws {
        let launcher = FakeJavacLauncher { path, text, _ in
            if text.contains("slow") {
                try await Task.sleep(for: .seconds(10)) // throws when the service cancels it
            }
            return .init(exitCode: 1, stdout: "", stderr: "\(path):1: error: fresh\nx\n^\n1 error\n")
        }
        let service = JavaCompilerDiagnosticsService(launcher: launcher, idleDelay: .milliseconds(30))
        let box = ResultBox()
        await service.setResultHandler { box.append($0, $1) }
        await service.configure(try makeConfiguration())

        _ = await service.diagnostics(for: makeDocument(text: "class Foo { /* slow */ }", version: 0))
        try await waitUntil { await launcher.launchCount == 1 }
        _ = await service.diagnostics(for: makeDocument(text: "class Foo { /* fast */ }", version: 1))
        try await waitUntil { !box.results.isEmpty }
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(box.results.count, 1)
        XCTAssertEqual(box.results[0].1.map(\.message), ["fresh"])
    }

    func testResetDropsInFlightResults() async throws {
        let launcher = FakeJavacLauncher { _, _, _ in
            try await Task.sleep(for: .milliseconds(150))
            return .init(exitCode: 0, stdout: "", stderr: "")
        }
        let service = JavaCompilerDiagnosticsService(launcher: launcher)
        let box = ResultBox()
        await service.setResultHandler { box.append($0, $1) }
        await service.configure(try makeConfiguration())

        await service.compileNow(makeDocument(text: "class Foo {}"))
        try await waitUntil { await launcher.launchCount == 1 }
        await service.reset()
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertTrue(box.results.isEmpty)
        let enabled = await service.isEnabled
        XCTAssertFalse(enabled)
    }

    func testUnconfiguredServiceNeverLaunches() async throws {
        let launcher = FakeJavacLauncher { _, _, _ in .init(exitCode: 0, stdout: "", stderr: "") }
        let service = JavaCompilerDiagnosticsService(launcher: launcher, idleDelay: .milliseconds(5))

        await service.compileNow(makeDocument(text: "class Foo {}"))
        let served = await service.diagnostics(for: makeDocument(text: "class Foo {}"))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(served.isEmpty)
        let unconfiguredLaunches = await launcher.launchCount
        XCTAssertEqual(unconfiguredLaunches, 0)

        await service.configure(try makeConfiguration())
        await service.configure(nil)
        await service.compileNow(makeDocument(text: "class Foo {}"))
        try await Task.sleep(nanoseconds: 100_000_000)
        let disabledLaunches = await launcher.launchCount
        XCTAssertEqual(disabledLaunches, 0)
    }

    func testNonJavaDocumentsAreIgnored() async throws {
        let launcher = FakeJavacLauncher { _, _, _ in .init(exitCode: 0, stdout: "", stderr: "") }
        let service = JavaCompilerDiagnosticsService(launcher: launcher)
        await service.configure(try makeConfiguration())
        await service.compileNow(makeDocument(text: "fn main() {}", url: URL(fileURLWithPath: "/proj/main.rs"), language: "rust"))
        try await Task.sleep(nanoseconds: 100_000_000)
        let launches = await launcher.launchCount
        XCTAssertEqual(launches, 0)
    }

    func testFailedInvocationKeepsThePreviousResult() async throws {
        let launcher = FakeJavacLauncher { path, text, _ in
            if text.contains("crash") { return .init(exitCode: 3, stdout: "", stderr: "internal error") }
            return .init(exitCode: 1, stdout: "", stderr: "\(path):1: error: real\nx\n^\n1 error\n")
        }
        let service = JavaCompilerDiagnosticsService(launcher: launcher, idleDelay: .milliseconds(10))
        let box = ResultBox()
        await service.setResultHandler { box.append($0, $1) }
        await service.configure(try makeConfiguration())

        await service.compileNow(makeDocument(text: "class Foo {}"))
        try await waitUntil { box.results.count == 1 }
        await service.compileNow(makeDocument(text: "class Foo { /* crash */ }", version: 1))
        try await waitUntil { await launcher.launchCount == 2 }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(box.results.count, 1, "a crashed javac must not be reported as a clean file")
    }

    func testMessagesAboutOtherFilesAreDropped() {
        let compiled = URL(fileURLWithPath: "/work/src/Foo.java")
        let messages = [
            JavacMessage(file: "/work/src/Foo.java", line: 1, column: 0, severity: .error, message: "mine"),
            JavacMessage(file: "/proj/Other.java", line: 1, column: 0, severity: .error, message: "theirs"),
            JavacMessage(file: nil, line: 0, column: nil, severity: .warning, message: "[options] noise"),
            JavacMessage(file: nil, line: 0, column: nil, severity: .error, message: "release not supported"),
        ]
        let diagnostics = JavaCompilerDiagnosticsService.diagnostics(from: messages, compiledFile: compiled, text: "class Foo {}")
        XCTAssertEqual(diagnostics.map(\.message), ["mine", "release not supported"])
    }

    func testCategoryPrefixBecomesCode() {
        let compiled = URL(fileURLWithPath: "/work/src/Foo.java")
        let messages = [JavacMessage(file: compiled.path, line: 1, column: 0, severity: .warning, message: "[deprecation] old() is deprecated")]
        let diagnostic = JavaCompilerDiagnosticsService.diagnostics(from: messages, compiledFile: compiled, text: "old();").first
        XCTAssertEqual(diagnostic?.code, "deprecation")
        XCTAssertEqual(diagnostic?.message, "old() is deprecated")
        XCTAssertEqual(diagnostic?.severity, .warning)
    }

    func testRangeMappingAtEndOfLineAndWithoutColumn() {
        let table = LineTable("int x = 1\n    foo();\r\nend")
        // Column at the end of line 0 ("';' expected") steps back onto the last character.
        XCTAssertEqual(table.range(line: 0, column: 9).start, 8)
        XCTAssertEqual(table.range(line: 0, column: 9).end, 9)
        // No column: the line without its indentation, and CRLF isn't part of it.
        let line1 = table.range(line: 1, column: nil)
        XCTAssertEqual(line1.start, 14)
        XCTAssertEqual(line1.end, 20)
        // A line beyond the end clamps to the last line.
        XCTAssertEqual(table.position(atOffset: table.range(line: 99, column: 0).start).line, 2)
    }
}
