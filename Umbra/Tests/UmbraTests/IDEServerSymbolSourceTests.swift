import EditorIntelligence
import EditorIntelligenceLSP
import Penumbra
import XCTest
@testable import Umbra

@MainActor
final class IDEServerSymbolSourceTests: XCTestCase {
    private func symbol(
        _ name: String, kind: String = "struct", uri: String?, line: Int = 0, character: Int = 0, container: String? = nil
    ) -> LSPOutlineSymbol {
        let position = EditorIntelligence.LSPPosition(line: line, character: character)
        return LSPOutlineSymbol(
            name: name, kind: kind, detail: container, uri: uri,
            range: EditorIntelligence.LSPRange(start: position, end: position)
        )
    }

    /// The native source stands in: it answers with one row called `native`.
    private final class NativeStub: SearchEverywhereProvider, @unchecked Sendable {
        let sectionTitle = "Symbols"
        private let lock = NSLock()
        private var queries: [String] = []
        var received: [String] { lock.withLock { queries } }

        func items(matching query: String, limit: Int) async -> [PaletteItem] {
            lock.withLock { queries.append(query) }
            return [PaletteItem(id: "native", title: "native", sectionTitle: sectionTitle, action: {})]
        }
    }

    func testTheServersOrderIsKeptAndWhatNamesNoFileIsDropped() {
        let outline = [
            symbol("Box", uri: "file:///proj/Sources/Box.swift", line: 3, character: 14, container: "Lib"),
            symbol("generated", uri: "sourcekit-lsp://swift-macro-expansion/x.swift"),
            symbol("nowhere", uri: nil),
            symbol("boxed()", kind: "method", uri: "file:///proj/Sources/Box.swift", line: 5, character: 16, container: "Box"),
            symbol("makeBox()", kind: "function", uri: "file:///proj/Sources/Make.swift"),
        ]
        let symbols = IDEServerSymbolSource.symbols(from: outline, limit: 10)
        XCTAssertEqual(symbols.map(\.name), ["Box", "boxed()", "makeBox()"])
        XCTAssertEqual(symbols.first?.line, 3)
        XCTAssertEqual(symbols.first?.character, 14)
        XCTAssertEqual(symbols.first?.container, "Lib")
        XCTAssertEqual(symbols.first?.url.path, "/proj/Sources/Box.swift")
        XCTAssertEqual(IDEServerSymbolSource.symbols(from: outline, limit: 2).map(\.name), ["Box", "boxed()"])
        XCTAssertTrue(IDEServerSymbolSource.symbols(from: outline, limit: 0).isEmpty)
    }

    func testEveryKindOfSymbolHasARow() {
        for (kind, title) in [
            ("class", "Class"), ("struct", "Struct"), ("interface", "Protocol"), ("enum", "Enum"),
            ("enumMember", "Case"), ("typeParameter", "Type"), ("function", "Function"), ("method", "Member"),
            ("constructor", "Member"), ("property", "Property"), ("variable", "Property"), ("module", "Module"),
        ] {
            XCTAssertEqual(IDEServerSymbolSource.presentation(ofKind: kind).title, title, kind)
        }
        XCTAssertEqual(IDEServerSymbolSource.presentation(ofKind: "somethingNew").title, "Symbol")
    }

    func testWithoutAServerTheNativeSourceAnswers() async {
        let native = NativeStub()
        let source = IDEServerSymbolSource(connection: LSPConnectionBox(), fallback: native) { _, _, _, _ in }
        let rows = await source.items(matching: "Box", limit: 10)
        XCTAssertEqual(rows.map(\.title), ["native"])
        XCTAssertEqual(native.received, ["Box"])
    }

    func testAnEmptyQueryNeverAsksTheServer() async {
        let native = NativeStub()
        let source = IDEServerSymbolSource(connection: LSPConnectionBox(), fallback: native) { _, _, _, _ in }
        _ = await source.items(matching: "   ", limit: 10)
        XCTAssertEqual(native.received, ["   "], "the native source gets the query as it was typed")
    }

    /// A real `sourcekit-lsp` answers `workspace/symbol` for the project once it has indexed it, and the
    /// rows are the server's, not the native source's. Skips without a toolchain.
    func testARealServerAnswersTheSymbolsSectionOnceItHasIndexed() async throws {
        let definition = IDESourceKitServer.definition()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-symbols-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = IDEServerDiscoveryContext(root: root, environment: ProcessInfo.processInfo.environment)
        guard await definition.discover(context) != nil else { throw XCTSkip("No sourcekit-lsp on this machine") }

        let sources = root.appendingPathComponent("Sources/Lib", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"Lib\", targets: [.target(name: \"Lib\")])\n"
            .write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "public struct Box {\n    public func boxed() -> Int { 1 }\n}\n"
            .write(to: sources.appendingPathComponent("Box.swift"), atomically: true, encoding: .utf8)

        let box = LSPConnectionBox()
        let host = IDELanguageServerHost(trustDirectory: root.appendingPathComponent("trust", isDirectory: true))
        host.trust(definition, root: root)
        await host.start(definition, connection: box, root: root)
        defer { host.stop() }

        let native = NativeStub()
        let source = IDEServerSymbolSource(connection: box, fallback: native) { _, _, _, _ in }
        var rows: [PaletteItem] = []
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            rows = await source.items(matching: "box", limit: 10)
            if rows.contains(where: { $0.title != "native" }) { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertTrue(rows.map(\.title).contains("Box"), "the server's rows: \(rows.map(\.title))")
        XCTAssertFalse(rows.map(\.title).contains("native"), "the server answered, so the native source did not")
        XCTAssertEqual(rows.first(where: { $0.title == "Box" })?.trailing, "Struct")
    }
}
