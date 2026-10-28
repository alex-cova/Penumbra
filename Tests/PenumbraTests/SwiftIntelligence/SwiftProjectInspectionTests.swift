import Foundation
import SwiftIntelligence
import XCTest

/// `unused-declaration`, the Swift inspection that needs the rest of the project: a name written nowhere else.
final class SwiftProjectInspectionTests: XCTestCase {
    private struct Lookup: SwiftProjectNameLookup {
        var files: [String: Set<URL>] = [:]
        func filesMentioning(_ name: String) async -> Set<URL> { files[name] ?? [] }
    }

    private let file = URL(fileURLWithPath: "/proj/Sources/App/A.swift")
    private let other = URL(fileURLWithPath: "/proj/Sources/App/B.swift")

    private func unused(
        _ text: String, url: URL? = nil, isTest: Bool = false, lookup: Lookup = Lookup(), publicApiUsed: Bool = true
    ) async -> [String] {
        var options = SwiftInspectionOptions().only([.unusedDeclaration])
        options.treatsPublicApiAsUsed = publicApiUsed
        let analysis = await SwiftInspectionPipeline.analyze(
            text: text, options: options, url: url ?? file, isTest: isTest, lookup: lookup, cache: SwiftSyntaxParseCache(capacity: 1)
        )
        return analysis.findings.map { String(decoding: Array(text.utf8)[$0.bytes], as: UTF8.self) }
    }

    func testANameWrittenNowhereElseIsUnused() async {
        let text = "func orphan() {}\\nstruct Lonely {}\\nlet constant = 1\\nenum Mode { case a }\\nstruct Sphere {\\n    var value = 1\\n    func helper() {}\\n}\\n"
            .replacingOccurrences(of: "\\n", with: "\n")
        let names = await unused(text)
        XCTAssertEqual(names, ["orphan", "Lonely", "constant", "Mode", "Sphere", "value", "helper"])
    }

    func testANameWrittenInAnotherFileOrTwiceHereIsUsed() async {
        let text = "func shared() {}\nfunc local() {}\nfunc caller() { local() }\n"
        var lookup = Lookup()
        lookup.files["shared"] = [file, other]
        lookup.files["local"] = [file]
        lookup.files["caller"] = [file]
        let names = await unused(text, lookup: lookup)
        XCTAssertEqual(names, ["caller"], "`shared` is written in B.swift, `local` is called here")
        // Only this file mentioning it is the same as nobody else doing so.
        var onlyHere = Lookup()
        onlyHere.files["shared"] = [file]
        let again = await unused("func shared() {}\n", lookup: onlyHere)
        XCTAssertEqual(again, ["shared"])
    }

    func testWhatTheRuntimeOrAnotherModuleMayReachIsLeftAlone() async {
        for text in [
            "public func api() {}\n",
            "open class Base {}\n",
            "@objc func tapped() {}\n",
            "@main struct App {}\n",
            "@Observable final class Model { var value = 1 }\n",
            "class D: B {\n    override func f() {}\n}\n",
            "protocol P {\n    func requirement()\n}\n",
            "struct V: View {\n    var body: some View { Text(\"\") }\n}\n",
            "struct S {\n    private func hidden() {}\n}\n",
            "public func f() {\n    func local() {}\n    let inner = 1\n}\n",
            "enum E { case lonelyCase }\n",
            "struct S: Codable {\n    enum CodingKeys: String, CodingKey { case a }\n    var a = 1\n}\n",
            "@MainActor @propertyWrapper struct W { var wrappedValue = 0 }\n",
            "final class P: NSObject, XMLParserDelegate {\n    func parserDidEndDocument(_ parser: XMLParser) {}\n}\n",
            "extension T: NSPopoverDelegate {\n    func popoverWillClose(_ n: Notification) {}\n}\n",
            "struct ByteCount: Numeric {\n    typealias Magnitude = UInt\n}\n",
            "struct Box: Codable {\n    var width: Double\n    var height: Double\n}\n",
            "public struct Uniforms {\n    var scale: Float\n    var pad4: Float\n}\n",
            "public struct Pt {\n    var x: Double\n    var y: Double\n}\n",
        ] {
            let found = await unused(text)
            // Types and members the text itself names are fine to be reported; none of the leftovers may be.
            XCTAssertFalse(found.contains { ["api", "Base", "tapped", "App", "value", "f", "requirement", "body", "hidden", "local", "inner", "lonelyCase", "CodingKeys", "wrappedValue", "parserDidEndDocument", "popoverWillClose", "Magnitude", "width", "height", "pad4", "x", "y"].contains($0) }, "\(text) -> \(found)")
        }
        let publicNames = await unused("public func api() {}\n", publicApiUsed: false)
        XCTAssertEqual(publicNames, ["api"], "unless asked to look at public API too")
    }

    func testTestsAndMainAreNotInspected() async {
        let text = "func helperUsedByNobody() {}\n"
        let inTest = await unused(text, isTest: true)
        XCTAssertTrue(inTest.isEmpty)
        let inMain = await unused(text, url: URL(fileURLWithPath: "/proj/Sources/App/main.swift"))
        XCTAssertTrue(inMain.isEmpty)
    }

    func testTheCommentsThatSilenceARuleSilenceThisOneToo() async {
        let silenced = await unused("// umbra:disable unused-declaration\nfunc orphan() {}\n")
        XCTAssertTrue(silenced.isEmpty)
        let swiftLint = await unused("// swiftlint:disable:next unused_declaration\nfunc orphan() {}\n")
        XCTAssertTrue(swiftLint.isEmpty)
    }

    func testTheEditorsPassAndAPlainRunDoNotSearchTheProject() {
        let text = "func orphan() {}\n"
        let options = SwiftInspectionOptions()
        XCTAssertTrue(SwiftInspectionRule.unusedDeclaration.isProjectWide)
        XCTAssertTrue(SwiftInspectionPipeline.analyze(text: text, options: options, cache: SwiftSyntaxParseCache(capacity: 1)).findings.isEmpty)
        XCTAssertTrue(SwiftBatchInspector.located(in: text, options: .init(inspection: options)).isEmpty)
    }

    // MARK: - Against a real index

    func testARunOverAProjectReportsWhatNothingElseNames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("swift-unused-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("Sources/App/A.swift")
        let b = root.appendingPathComponent("Sources/App/B.swift")
        try "func used() {}\nfunc orphan() {}\nstruct Widget {}\n".write(to: a, atomically: true, encoding: .utf8)
        try "func caller() { used(); _ = Widget() }\nfunc run() { caller() }\n".write(to: b, atomically: true, encoding: .utf8)
        let index = SwiftIndex()
        await index.setRoot(root)

        let options = SwiftBatchInspector.Options(
            inspection: SwiftInspectionOptions(), onlyRules: [.unusedDeclaration], includeProjectRules: true, projectLookup: index
        )
        var found: [String: [String]] = [:]
        for await event in SwiftBatchInspector().run(files: [a, b], options: options, text: { try? String(contentsOf: $0, encoding: .utf8) }) {
            if case .file(let url, let findings) = event { found[url.lastPathComponent] = findings.map(\.inspection.message) }
        }
        XCTAssertEqual(found["A.swift"], ["'orphan' is never used in the project."])
        XCTAssertEqual(found["B.swift"], ["'run' is never used in the project."])

        // Without the switch the run does not search.
        var plain = options
        plain.includeProjectRules = false
        var none = 0
        for await event in SwiftBatchInspector().run(files: [a, b], options: plain, text: { try? String(contentsOf: $0, encoding: .utf8) }) {
            if case .file = event { none += 1 }
        }
        XCTAssertEqual(none, 0)
    }
}
