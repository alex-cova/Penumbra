import EditorIntelligence
import Foundation
import JavaIntelligence
import Penumbra
import XCTest
@testable import Umbra

@MainActor
final class IDEJavaMembersPaletteSourceTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("members-palette-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private final class Opened: @unchecked Sendable {
        var member: JavaMemberMatch?
        var inSplit: Bool?
    }

    private func makeSource(_ opened: Opened) async throws -> IDEJavaMembersPaletteSource {
        let text = """
        package demo;
        public class Person {
            public static final int MAX_AGE = 150;
            private String name;
            public String getName() { return name; }
            public void greet(String who, int times) { }
        }
        """
        let url = scratch.appendingPathComponent("Person.java")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let shard = scratch.appendingPathComponent("p.idx")
        try JavaIndexShardWriter().write(JavaSourceStubBuilder.build(source: text, url: url).classes, stamp: JavaStamp(size: 0, modificationDate: 0), to: shard)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 1, reader: try JavaIndexShardReader(url: shard))])
        return IDEJavaMembersPaletteSource(
            javaIndex: index,
            fileIndex: { nil },
            onOpen: { member, split in opened.member = member; opened.inSplit = split }
        )
    }

    private func firstRow(_ source: IDEJavaMembersPaletteSource, _ query: String) async throws -> PaletteItem {
        let items = await source.items(matching: query, limit: 5)
        return try XCTUnwrap(items.first, "no row for \(query)")
    }

    func testRowsCarryTheMemberSignatureOwnerAndSectionOfTheSymbolsTab() async throws {
        let source = try await makeSource(Opened())
        let items = await source.items(matching: "gN", limit: 10)

        let row = try XCTUnwrap(items.first)
        XCTAssertEqual(row.title, "getName")
        XCTAssertEqual(row.sectionTitle, "Symbols")
        XCTAssertEqual(row.location, "(): String")
        XCTAssertEqual(row.trailing, "Person")
        XCTAssertEqual(row.matchedIndices, [0, 3], "The g and the N that the camel-hump match used")
        XCTAssertTrue(row.footer?.hasPrefix("demo.Person — ") == true)
        XCTAssertEqual(row.icon?.systemName, "m.square.fill")
    }

    func testMethodsWithParametersAndFieldsAreDescribed() async throws {
        let source = try await makeSource(Opened())
        let greet = try await firstRow(source, "greet")
        XCTAssertEqual(greet.location, "(String who, int times): void")
        let constant = try await firstRow(source, "MAX_AGE")
        XCTAssertEqual(constant.location, ": int")
        XCTAssertEqual(constant.icon?.systemName, "f.square.fill")
        XCTAssertEqual(constant.icon?.tint, .accent, "Static members are tinted differently")
    }

    func testTheActionsOpenTheMemberInPlaceOrInASplit() async throws {
        let opened = Opened()
        let source = try await makeSource(opened)
        let row = try await firstRow(source, "getName")

        row.action()
        XCTAssertEqual(opened.member?.name, "getName")
        XCTAssertEqual(opened.inSplit, false)
        row.alternateAction?()
        XCTAssertEqual(opened.inSplit, true)
    }

    func testRanksFollowTheIndexOrderAndAnEmptyQueryFindsNothing() async throws {
        let source = try await makeSource(Opened())
        let items = await source.items(matching: "name", limit: 10)
        XCTAssertEqual(items.map(\.score), items.map(\.score).sorted(by: >))
        XCTAssertEqual(items.first?.title, "name", "The exact name outranks getName")
        let none = await source.items(matching: "", limit: 10)
        XCTAssertTrue(none.isEmpty)
    }
}
