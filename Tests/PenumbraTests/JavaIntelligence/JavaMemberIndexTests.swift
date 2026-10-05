import XCTest
import EditorIntelligence
@testable import JavaIntelligence

/// Project-wide members for Go to Symbol: what is listed, how it is matched and ranked, how an
/// open buffer overrides a stored file, and how a hit is located in its file.
final class JavaMemberIndexTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("java-members-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private let person = """
    package demo;

    public class Person {
        public static final int MAX_AGE = 150;
        private String name;
        private int age;

        public Person(String name, int age) { this.name = name; this.age = age; }

        public String getName() { return name; }
        public void setName(String name) { this.name = name; }
        public int getAge() { return age; }
        public static Person of(String name) { return new Person(name, 0); }
        public void greet(String who) { }
        public void greet(int times) { }

        public static class Builder {
            private String label;
            public Builder withLabel(String label) { this.label = label; return this; }
        }
    }
    """

    private func makeIndex(_ files: [(String, String)], precedence: Int = 1) async throws -> JavaIndex {
        var stubs: [JavaClassStub] = []
        for (name, source) in files {
            let url = scratch.appendingPathComponent(name)
            try source.write(to: url, atomically: true, encoding: .utf8)
            stubs.append(contentsOf: JavaSourceStubBuilder.build(source: source, url: url).classes)
        }
        let shard = scratch.appendingPathComponent("\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: shard)
        let index = JavaIndex()
        await index.setSources([.init(precedence: precedence, reader: try JavaIndexShardReader(url: shard))])
        return index
    }

    private func first(_ index: JavaIndex, _ query: String) async throws -> JavaMemberMatch {
        let hits = await index.members(matching: query, limit: 5)
        return try XCTUnwrap(hits.first, "no member matched \(query)")
    }

    private func names(_ matches: [JavaMemberMatch]) -> [String] {
        matches.map { "\($0.ownerSimpleName).\($0.name)" }
    }

    // MARK: - What is listed

    func testListsMethodsFieldsAndNestedClassMembers() async throws {
        let index = try await makeIndex([("Person.java", person)])
        let all = await index.members(matching: "a", limit: 100)
        let listed = Set(names(all))
        XCTAssertTrue(listed.contains("Person.getAge"))
        XCTAssertTrue(listed.contains("Person.MAX_AGE"))
        XCTAssertTrue(listed.contains("Person.age"))
        XCTAssertTrue(listed.contains("Person.of") == false, "`of` has no `a`")
        let builder = await index.members(matching: "withL", limit: 10)
        XCTAssertEqual(names(builder), ["Builder.withLabel"])
        XCTAssertEqual(builder.first?.ownerQualifiedName, "demo.Person.Builder")
    }

    func testConstructorsAreNotListed() async throws {
        let index = try await makeIndex([("Person.java", person)])
        let hits = await index.members(matching: "Person", limit: 20)
        XCTAssertFalse(hits.contains { $0.name == "Person" }, "The class itself is a Classes result")
    }

    func testEnumConstantsAreListedButValuesAndValueOfAreNot() async throws {
        let color = "package demo; public enum Color { RED, GREEN; public String hex() { return \"\"; } }"
        let index = try await makeIndex([("Color.java", color)])
        let constants = await index.members(matching: "RED", limit: 10)
        XCTAssertEqual(constants.first?.kind, .enumConstant)
        let synthesized = await index.members(matching: "valueOf", limit: 10)
        XCTAssertTrue(synthesized.isEmpty)
        let values = await index.members(matching: "values", limit: 10)
        XCTAssertTrue(values.isEmpty)
        let declared = await index.members(matching: "hex", limit: 10)
        XCTAssertEqual(declared.first?.kind, .method)
    }

    func testARecordListsItsComponentsOnceNotTheFieldAndAccessor() async throws {
        let point = "package demo; public record Point(int x, int y) { public int sum() { return x + y; } }"
        let index = try await makeIndex([("Point.java", point)])
        let x = await index.members(matching: "x", limit: 10)
        XCTAssertEqual(x.map(\.kind), [.recordComponent])
        XCTAssertEqual(x.first?.typeText, "int")
        let sum = await index.members(matching: "sum", limit: 10)
        XCTAssertEqual(sum.map(\.kind), [.method])
    }

    func testInheritedMembersAreNotListed() async throws {
        let base = "package demo; public class Base { public void baseOnly() {} }"
        let child = "package demo; public class Child extends Base { public void childOnly() {} }"
        let index = try await makeIndex([("Base.java", base), ("Child.java", child)])
        let hits = await index.members(matching: "Only", limit: 10)
        XCTAssertEqual(Set(names(hits)), ["Base.baseOnly", "Child.childOnly"], "Each is listed once, under its declaring class")
    }

    func testLibraryShardsAreLeftOut() async throws {
        let index = try await makeIndex([("Person.java", person)], precedence: 2)
        let hits = await index.members(matching: "getName", limit: 10)
        XCTAssertTrue(hits.isEmpty, "Precedence 2 is a JAR: not a project member")
    }

    // MARK: - Matching and ranking

    func testCamelHumpAndLaterWordMatches() async throws {
        let index = try await makeIndex([("Person.java", person)])
        let hump = await index.members(matching: "gN", limit: 10)
        XCTAssertEqual(names(hump), ["Person.getName"])
        XCTAssertEqual(hump.first?.tier, .camelHump)
        let word = await index.members(matching: "Name", limit: 10)
        XCTAssertTrue(names(word).contains("Person.getName"))
        XCTAssertTrue(names(word).contains("Person.setName"))
        XCTAssertEqual(word.first { $0.name == "name" }?.tier, CompletionMatcher.match("Name", in: "name")?.tier)
        XCTAssertEqual(word.first { $0.name == "getName" }?.tier, .wordStart)
    }

    func testDigitWordStartFindsToBase64() async throws {
        let source = "package demo; public class Codec { public String toBase64(String text) { return text; } }"
        let index = try await makeIndex([("Codec.java", source)])
        let hits = await index.members(matching: "64", limit: 10)
        XCTAssertEqual(names(hits), ["Codec.toBase64"])
    }

    func testBetterTiersAndShorterNamesComeFirst() async throws {
        let index = try await makeIndex([("Person.java", person)])
        let hits = await index.members(matching: "name", limit: 10)
        XCTAssertEqual(names(hits).first, "Person.name", "Exact before prefix before later-word matches")
        let tiers = hits.map(\.tier)
        XCTAssertEqual(tiers, tiers.sorted(by: >), "Never a worse tier ahead of a better one")
    }

    func testLimitKeepsTheBestOnes() async throws {
        let index = try await makeIndex([("Person.java", person)])
        let two = await index.members(matching: "name", limit: 2)
        XCTAssertEqual(two.count, 2)
        XCTAssertEqual(names(two).first, "Person.name")
    }

    func testOverloadsAreBothListedWithTheirSignatures() async throws {
        let index = try await makeIndex([("Person.java", person)])
        let greets = await index.members(matching: "greet", limit: 10)
        XCTAssertEqual(Set(greets.map(\.parameterList)), ["(String who)", "(int times)"])
        XCTAssertEqual(Set(greets.map(\.parameterKeys)), [["String"], ["int"]])
    }

    func testAnEmptyOrUnmatchedQueryFindsNothing() async throws {
        let index = try await makeIndex([("Person.java", person)])
        let empty = await index.members(matching: "", limit: 10)
        XCTAssertTrue(empty.isEmpty)
        let none = await index.members(matching: "zzzq", limit: 10)
        XCTAssertTrue(none.isEmpty)
    }

    // MARK: - Open buffers and changing sources

    func testAnOpenBuffersClassReplacesTheStoredOne() async throws {
        let index = try await makeIndex([("Person.java", person)])
        let edited = person.replacingOccurrences(of: "getName", with: "fullName")
        let url = scratch.appendingPathComponent("Person.java")
        await index.replaceOverlay(removing: [], adding: JavaSourceStubBuilder.build(source: edited, url: url).classes)

        let old = await index.members(matching: "getName", limit: 10)
        XCTAssertTrue(old.isEmpty, "The stored member is masked by the buffer's version of the class")
        let new = await index.members(matching: "fullName", limit: 10)
        XCTAssertEqual(names(new), ["Person.fullName"])
        let untouched = await index.members(matching: "getAge", limit: 10)
        XCTAssertEqual(names(untouched), ["Person.getAge"], "Members the buffer still has are listed once")
    }

    func testAnOverlayOnlyClassIsListedAndRemovingItBringsBackTheStoredOne() async throws {
        let index = try await makeIndex([("Person.java", person)])
        let scratchSource = "package demo; public class Scratch { public void brandNew() {} }"
        let url = scratch.appendingPathComponent("Scratch.java")
        let stubs = JavaSourceStubBuilder.build(source: scratchSource, url: url).classes
        await index.replaceOverlay(removing: [], adding: stubs)
        let added = await index.members(matching: "brandNew", limit: 10)
        XCTAssertEqual(names(added), ["Scratch.brandNew"])
        await index.replaceOverlay(removing: Set(stubs.map(\.qualifiedName)), adding: [])
        let gone = await index.members(matching: "brandNew", limit: 10)
        XCTAssertTrue(gone.isEmpty)
    }

    func testReplacingTheSourcesRebuildsTheTable() async throws {
        let index = try await makeIndex([("Person.java", person)])
        let before = await index.members(matching: "getName", limit: 10)
        XCTAssertEqual(before.count, 1)
        let other = "package demo; public class Other { public void unrelated() {} }"
        let url = scratch.appendingPathComponent("Other.java")
        let shard = scratch.appendingPathComponent("\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(JavaSourceStubBuilder.build(source: other, url: url).classes, stamp: JavaStamp(size: 0, modificationDate: 0), to: shard)
        await index.setSources([.init(precedence: 1, reader: try JavaIndexShardReader(url: shard))])
        let gone = await index.members(matching: "getName", limit: 10)
        XCTAssertTrue(gone.isEmpty)
        let now = await index.members(matching: "unrelated", limit: 10)
        XCTAssertEqual(names(now), ["Other.unrelated"])
    }

    // MARK: - Locating a hit

    private func nameText(_ match: JavaMemberMatch, in source: String) throws -> (text: String, line: Int) {
        let range = try XCTUnwrap(JavaMemberLocator.nameRange(of: match, in: source))
        let bytes = Array(source.utf8)
        let text = String(decoding: bytes[range], as: UTF8.self)
        let line = source.utf8.prefix(range.lowerBound).filter { $0 == 0x0A }.count + 1
        return (text, line)
    }

    func testTheLocatorFindsTheRightOverload() async throws {
        let index = try await makeIndex([("Person.java", person)])
        let greets = await index.members(matching: "greet", limit: 10)
        let byInt = try XCTUnwrap(greets.first { $0.parameterKeys == ["int"] })
        let byString = try XCTUnwrap(greets.first { $0.parameterKeys == ["String"] })
        let lines = person.components(separatedBy: "\n")
        XCTAssertEqual(try nameText(byString, in: person).line, lines.firstIndex { $0.contains("greet(String who)") }! + 1)
        XCTAssertEqual(try nameText(byInt, in: person).line, lines.firstIndex { $0.contains("greet(int times)") }! + 1)
    }

    func testTheLocatorFindsFieldsConstantsAndRecordComponents() async throws {
        let source = """
        package demo;
        public enum Mode { FAST, SLOW; int limit = 3; }
        """
        let record = "package demo; public record Point(int x, int y) { }"
        let index = try await makeIndex([("Mode.java", source), ("Point.java", record)])
        let fast = try await first(index, "FAST")
        XCTAssertEqual(try nameText(fast, in: source).text, "FAST")
        let limit = try await first(index, "limit")
        XCTAssertEqual(try nameText(limit, in: source).text, "limit")
        let x = try await first(index, "x")
        let located = try nameText(x, in: record)
        XCTAssertEqual(located.text, "x")
        let expected = record.utf8.distance(from: record.utf8.startIndex, to: record.range(of: "x, int y")!.lowerBound.samePosition(in: record.utf8)!)
        XCTAssertEqual(try XCTUnwrap(JavaMemberLocator.nameRange(of: x, in: record)).lowerBound, expected, "The component in the header, not a use of x")
    }

    func testAStaleMemberFallsBackToTheOwnerClass() async throws {
        let index = try await makeIndex([("Person.java", person)])
        let getName = try await first(index, "getName")
        let changed = person.replacingOccurrences(of: "getName", with: "renamed")
        let located = try nameText(getName, in: changed)
        XCTAssertEqual(located.text, "Person", "The member is gone, so the row still opens the class")
    }

    func testTheLocatorFollowsTheFileAsItIsNow() async throws {
        let index = try await makeIndex([("Person.java", person)])
        let getAge = try await first(index, "getAge")
        let shifted = "// a new first line\n// and another\n" + person
        let before = try nameText(getAge, in: person).line
        XCTAssertEqual(try nameText(getAge, in: shifted).line, before + 2, "A stored position would now point two lines too high")
    }
}
