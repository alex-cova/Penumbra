import XCTest
import EditorIntelligence
@testable import JavaIntelligence

/// F16: the members Lombok generates are part of the class stub, so completion and typing see them.
final class JavaLombokMembersTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/p/Person.java")

    private func stub(_ source: String, named name: String = "Person") throws -> JavaClassStub {
        try XCTUnwrap(JavaSourceStubBuilder.build(source: source, url: url).classes.first { $0.simpleName == name })
    }

    private func signature(_ method: JavaMethodStub) -> String {
        let parameters = method.parameters.map { "\($0.type)" }
        return "\(method.name)(\(parameters.joined(separator: ",")))"
    }

    private func names(_ stub: JavaClassStub) -> [String] { stub.methods.map(\.name).sorted() }

    private func allClasses(_ source: String) throws -> [JavaClassStub] {
        JavaSourceStubBuilder.build(source: source, url: url).classes
    }

    func testFieldGettersAndSetters() throws {
        let person = try stub("""
        package p;
        import lombok.Getter;
        import lombok.Setter;
        public class Person {
            @Getter private String name;
            @Getter @Setter private boolean active;
            @Getter private Boolean wrapped;
            @Getter private boolean isDone;
            @Setter private boolean isReady;
            private int plain;
        }
        """)
        XCTAssertEqual(names(person), ["getName", "getWrapped", "isActive", "isDone", "setActive", "setReady"].sorted())
        XCTAssertEqual(person.methods.first { $0.name == "getName" }?.returnType, .unresolved(simpleName: "String", arguments: []))
        XCTAssertEqual(person.methods.first { $0.name == "isActive" }?.returnType, .primitive(.boolean))
        XCTAssertEqual(person.methods.first { $0.name == "setActive" }?.returnType, .void)
    }

    func testClassLevelGetterAndSetterCoverInstanceFieldsOnly() throws {
        let person = try stub("""
        import lombok.*;
        @Getter @Setter
        class Person {
            private String name;
            private static int counter;
            private final int id = 1;
        }
        """)
        XCTAssertEqual(names(person), ["getId", "getName", "setName"], "static fields need their own annotation; final fields get no setter")
    }

    func testDataAndValue() throws {
        let data = try stub("""
        import lombok.Data;
        @Data class Person { private final String id; private String name; }
        """)
        XCTAssertEqual(names(data), ["Person", "getId", "getName", "setName"])
        let constructor = try XCTUnwrap(data.methods.first { $0.isConstructor })
        XCTAssertEqual(constructor.parameters.map(\.name), ["id"], "@Data's constructor takes the final fields")

        let value = try stub("""
        import lombok.Value;
        @Value class Point { int x; int y; }
        """, named: "Point")
        XCTAssertEqual(names(value), ["Point", "getX", "getY"], "@Value: getters, no setters, an all-args constructor")
        XCTAssertEqual(value.methods.first { $0.isConstructor }?.parameters.map(\.name), ["x", "y"])
    }

    func testConstructorAnnotations() throws {
        let person = try stub("""
        import lombok.*;
        @NoArgsConstructor @AllArgsConstructor @RequiredArgsConstructor
        class Person { private final String id; private String name; private final int fixed = 3; }
        """)
        let constructors = person.methods.filter(\.isConstructor).map { $0.parameters.map(\.name) }
        XCTAssertTrue(constructors.contains([]))
        XCTAssertTrue(constructors.contains(["id", "name"]), "all-args skips an initialized final field: \(constructors)")
        XCTAssertTrue(constructors.contains(["id"]), "required-args: the uninitialized final field")
    }

    func testAnExplicitConstructorSuppressesDataButNotAnExplicitAnnotation() throws {
        let data = try stub("""
        import lombok.Data;
        @Data class Person { private String name; Person(String name) { this.name = name; } }
        """)
        XCTAssertEqual(data.methods.filter(\.isConstructor).count, 1, "@Data adds no constructor next to an explicit one")
    }

    func testAccessLevelNoneAndProtected() throws {
        let person = try stub("""
        import lombok.*;
        @Getter class Person {
            @Getter(AccessLevel.NONE) private String secret;
            @Setter(AccessLevel.PROTECTED) private String guarded;
            private String name;
        }
        """)
        XCTAssertEqual(names(person), ["getGuarded", "getName", "setGuarded"])
        XCTAssertTrue(person.methods.first { $0.name == "setGuarded" }?.modifiers.contains(.protectedFlag) == true)
        XCTAssertTrue(person.methods.first { $0.name == "getName" }?.modifiers.contains(.publicFlag) == true)
    }

    /// F-07: `@Builder` adds a static `builder()` entry point plus a nested `*Builder` class
    /// with one chained setter per field and `build()`.
    func testBuilderGeneratesEntryPointAndNestedClass() throws {
        let classes = try allClasses("""
        import lombok.*;
        @Builder class Person { private String name; private int age; private static int counter; }
        """)
        let person = try XCTUnwrap(classes.first { $0.simpleName == "Person" })
        let entry = try XCTUnwrap(person.methods.first { $0.name == "builder" })
        XCTAssertTrue(entry.modifiers.contains(.staticFlag))
        XCTAssertEqual(entry.returnType, .classType(qualifiedName: "Person.PersonBuilder", arguments: [], outer: nil))
        XCTAssertTrue(person.innerTypeNames.contains("Person.PersonBuilder"))

        let builder = try XCTUnwrap(classes.first { $0.simpleName == "PersonBuilder" })
        XCTAssertEqual(builder.qualifiedName, "Person.PersonBuilder")
        XCTAssertTrue(builder.modifiers.contains(.staticFlag))
        XCTAssertEqual(names(builder), ["age", "build", "name"])
        XCTAssertEqual(
            builder.methods.first { $0.name == "build" }?.returnType,
            .classType(qualifiedName: "Person", arguments: [], outer: nil)
        )
        XCTAssertEqual(
            builder.methods.first { $0.name == "name" }?.returnType,
            .classType(qualifiedName: "Person.PersonBuilder", arguments: [], outer: nil),
            "field setters chain on the builder"
        )
    }

    /// F-07: an explicit `builder()` wins; the nested class still generates around it.
    func testExplicitBuilderMethodWins() throws {
        let person = try stub("""
        import lombok.*;
        @Builder class Person {
            private String name;
            public static PersonBuilder builder() { return null; }
        }
        """)
        XCTAssertEqual(person.methods.filter { $0.name == "builder" }.count, 1)
    }

    /// F-07: `@With` (field- and class-level) adds `withField` copies; static fields are skipped.
    func testWithGeneratesCopyMethods() throws {
        let person = try stub("""
        import lombok.*;
        @With class Person {
            private String name;
            @With private boolean active;
            private static int counter;
        }
        """)
        let withs = person.methods.filter { $0.name.hasPrefix("with") }.map(\.name).sorted()
        XCTAssertEqual(withs, ["withActive", "withName"])
        XCTAssertEqual(
            person.methods.first { $0.name == "withName" }?.returnType,
            .classType(qualifiedName: "Person", arguments: [], outer: nil)
        )
    }

    /// F-07: without a Lombok import, `@Builder`/`@With` generate nothing.
    func testBuilderAndWithNeedTheLombokImport() throws {
        let person = try stub("""
        @Builder @With class Person { private String name; }
        """)
        XCTAssertTrue(person.methods.isEmpty)
        XCTAssertFalse(person.innerTypeNames.contains("Person.PersonBuilder"))
    }

    func testAMethodYouWroteWins() throws {
        let person = try stub("""
        import lombok.Getter;
        class Person {
            @Getter private String name;
            public String getName() { return "mine"; }
        }
        """)
        XCTAssertEqual(person.methods.filter { $0.name == "getName" }.count, 1)
    }

    func testFluentAndChainedAccessors() throws {
        let person = try stub("""
        import lombok.*;
        import lombok.experimental.Accessors;
        @Getter @Setter @Accessors(fluent = true)
        class Person { private String name; }
        """)
        XCTAssertEqual(names(person), ["name", "name"], "fluent: name() and name(String)")
        XCTAssertEqual(person.methods.filter { $0.name == "name" }.map { $0.parameters.count }.sorted(), [0, 1])
        let chained = try stub("""
        import lombok.*;
        import lombok.experimental.Accessors;
        @Setter @Accessors(chain = true)
        class Person { private String name; }
        """)
        XCTAssertEqual(chained.methods.first { $0.name == "setName" }?.returnType, .classType(qualifiedName: "Person", arguments: [], outer: nil))
    }

    func testNothingIsAddedWithoutALombokImport() throws {
        let person = try stub("""
        import com.other.Getter;
        class Person { @Getter private String name; }
        """)
        XCTAssertTrue(person.methods.isEmpty, "a `@Getter` from another library is not Lombok")
    }

    // MARK: - In completion

    func testCompletionOffersGeneratedAccessorsAndTypesTheirResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lombok-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("p"), withIntermediateDirectories: true)
        let personSource = """
        package p;
        import lombok.Getter;
        import lombok.Setter;
        public class Person {
            @Getter private String name;
            @Getter @Setter private boolean active;
        }
        """
        let person = dir.appendingPathComponent("p/Person.java")
        try personSource.write(to: person, atomically: true, encoding: .utf8)
        let use = dir.appendingPathComponent("p/Use.java")
        try "package p; class Use {}".write(to: use, atomically: true, encoding: .utf8)

        let paths = JavaIndexPaths(root: root.appendingPathComponent("index"))
        let shard = paths.projectSourcesShard(for: dir.standardizedFileURL)
        try FileManager.default.createDirectory(at: shard.deletingLastPathComponent(), withIntermediateDirectories: true)
        let string = JavaClassStub(
            binaryName: "java.lang.String", qualifiedName: "java.lang.String", simpleName: "String", packageName: "java.lang",
            kind: .classKind, modifiers: [.publicFlag, .finalFlag],
            methods: [JavaMethodStub(name: "length", parameters: [], returnType: .primitive(.int), modifiers: [.publicFlag])],
            origin: .jdkModule("java.base")
        )
        let jdk = root.appendingPathComponent("jdk.idx")
        try JavaIndexShardWriter().write([string], stamp: JavaStamp(size: 0, modificationDate: 0), to: jdk)
        try JavaIndexShardWriter().write(
            JavaSourceStubBuilder.build(source: personSource, url: person).classes,
            stamp: JavaStamp(size: 1, modificationDate: 0), to: shard
        )
        let index = JavaIndex()
        await index.setSources([
            .init(precedence: 3, reader: try JavaIndexShardReader(url: jdk)),
            .init(precedence: 1, reader: try JavaIndexShardReader(url: shard), shardPath: shard.path)
        ])
        let provider = JavaCompletionProvider(index: index)

        func complete(_ source: String) async -> Set<String> {
            let marker = source.range(of: "€")!
            let text = source.replacingOccurrences(of: "€", with: "")
            let offset = source.utf16.distance(from: source.utf16.startIndex, to: marker.lowerBound.samePosition(in: source.utf16)!)
            let position = TextPosition(line: 0, column: offset, utf16Offset: offset)
            let document = Document(
                id: DocumentID(), url: use, displayName: "Use.java", contentSnapshot: TextSnapshot(version: 0, text: text),
                selection: Selection(range: TextRange(start: position, end: position)), cursor: Cursor(position: position),
                viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: "java"
            )
            return Set(await provider.provide(context: makeCompletionContext(document: document, trigger: .manual)).map(\.label))
        }
        let members = await complete("package p; class Use { void m(Person person) { person.€ } }")
        XCTAssertTrue(members.contains("getName"), "@Getter generates getName()")
        XCTAssertTrue(members.contains("isActive"), "@Getter on a boolean generates isActive()")
        XCTAssertTrue(members.contains("setActive"), "@Setter generates setActive(boolean)")
        XCTAssertFalse(members.contains("setName"), "@Getter alone has no setter")
        let chained = await complete("package p; class Use { void m(Person person) { person.getName().€ } }")
        XCTAssertTrue(chained.contains("length"), "the generated method's return type resolves")
    }
}
