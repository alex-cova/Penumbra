import EditorIntelligence
import XCTest
@testable import JavaIntelligence

/// One catch parameter has one type. Dot completion, statement matching, chains, the local's
/// display (what an inlay prints), `var` inference and a generic call all read
/// `effectiveCatchType`. An incomplete classpath falls back to `java.lang.Throwable` everywhere,
/// and that fallback is not treated as a subtype of either alternative.
final class JavaMultiCatchConsistencyTests: XCTestCase {
    private let fileURL = URL(fileURLWithPath: "/tmp/penumbra-tests/Catch.java")

    private func classType(_ name: String) -> JavaTypeRef {
        .classType(qualifiedName: name, arguments: [], outer: nil)
    }

    private func stub(
        _ qualifiedName: String, superclass: String? = nil, methods: [JavaMethodStub] = [],
        typeParameters: [JavaTypeParameter] = []
    ) -> JavaClassStub {
        let simple = String(qualifiedName.split(separator: ".").last!)
        let packageName = qualifiedName.split(separator: ".").dropLast().joined(separator: ".")
        return JavaClassStub(
            binaryName: qualifiedName, qualifiedName: qualifiedName, simpleName: simple, packageName: packageName,
            kind: .classKind, modifiers: [.publicFlag], typeParameters: typeParameters,
            superclass: superclass.map { classType($0) }, methods: methods, origin: .jdkModule("test")
        )
    }

    private func method(
        _ name: String, returns: JavaTypeRef = .void, parameters: [JavaParameterStub] = [],
        typeParameters: [JavaTypeParameter] = [], modifiers: JavaModifiers = [.publicFlag]
    ) -> JavaMethodStub {
        JavaMethodStub(
            name: name, typeParameters: typeParameters, parameters: parameters,
            returnType: returns, modifiers: modifiers
        )
    }

    /// `Gone` is named by the incomplete test and deliberately has no stub. `java.lang.Throwable`
    /// is present, which is what makes the conservative fallback available.
    private func jdkStubs() -> [JavaClassStub] {
        let string = classType("java.lang.String")
        return [
            stub("java.lang.Object"),
            stub("java.lang.Throwable", superclass: "java.lang.Object", methods: [method("printStackTrace")]),
            stub("java.lang.Exception", superclass: "java.lang.Throwable", methods: [method("getMessage", returns: string)]),
            stub("java.lang.String", superclass: "java.lang.Object"),
            stub("java.io.IOException", superclass: "java.lang.Exception", methods: [method("read")]),
            stub("java.sql.SQLException", superclass: "java.lang.Exception", methods: [method("getSQLState", returns: string)]),
            stub("Ids", methods: [
                method(
                    "id", returns: .typeVariable(name: "T"),
                    parameters: [JavaParameterStub(name: "value", type: .typeVariable(name: "T"))],
                    typeParameters: [JavaTypeParameter(name: "T", bounds: [])],
                    modifiers: [.publicFlag, .staticFlag]
                )
            ])
        ]
    }

    private func makeIndex(source: String) async throws -> JavaIndex {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(jdkStubs(), stamp: JavaStamp(size: 0, modificationDate: 0), to: url)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: try JavaIndexShardReader(url: url))])
        let stubs = JavaSourceStubBuilder.build(source: source, url: fileURL)
        await index.setOverlay(Dictionary(uniqueKeysWithValues: stubs.classes.map { ($0.qualifiedName, $0) }))
        return index
    }

    private func context(enclosing: [String] = ["Foo"]) -> JavaResolutionContext {
        JavaResolutionContext(
            packageName: "",
            imports: [
                JavaImportDeclaration(qualifiedName: "java.io.IOException", isStatic: false, isOnDemand: false),
                JavaImportDeclaration(qualifiedName: "java.sql.SQLException", isStatic: false, isOnDemand: false)
            ],
            enclosingTypeQualifiedNames: enclosing
        )
    }

    private func tree(_ source: String) throws -> JavaSyntaxTree {
        try XCTUnwrap(JavaSyntaxParser().parse(source))
    }

    private func offset(of snippet: String, in source: String) -> Int {
        let utf16 = source.utf16.distance(from: source.utf16.startIndex, to: source.range(of: snippet)!.lowerBound.samePosition(in: source.utf16)!)
        return String(source.utf16.prefix(utf16))!.utf8.count
    }

    private let header = """
    import java.io.IOException;
    import java.sql.SQLException;

    """

    private func names(of type: JavaTypeRef, index: JavaIndex) async -> Set<String> {
        let members = await JavaMemberLookup.members(of: type, mode: .instance, context: context(), index: index)
        return Set(members.map(\.name))
    }

    func testCompleteMultiCatchAgreesEverywhere() async throws {
        let source = header + """
        class Foo {
            void m() {
                try { } catch (IOException | SQLException e) {
                    var copy = e;
                    Ids.id(e);
                }
            }
        }
        """
        let index = try await makeIndex(source: source)
        let parsed = try tree(source)
        let resolution = context()
        let atCopy = offset(of: "Ids.id", in: source)
        let locals = parsed.visibleLocals(atByteOffset: atCopy)
        let resolved = await JavaExpressionTyper.resolvingVarLocals(locals, context: resolution, index: index)
        let caught = try XCTUnwrap(resolved.first { $0.name == "e" })
        let copy = try XCTUnwrap(resolved.first { $0.name == "copy" })
        XCTAssertEqual(caught.type.erasedQualifiedName, "java.lang.Exception")
        XCTAssertEqual(copy.type.erasedQualifiedName, "java.lang.Exception", "var reads the same catch type")
        XCTAssertEqual(caught.alternativeTypes.count, 2, "the alternatives stay, so the lub is not stored as a subtype of the first")
        XCTAssertEqual(JavaSignatureText.text(of: caught.type), "Exception")

        let typed = await JavaExpressionTyper.typeOfExpression("e", locals: locals, context: resolution, index: index)
        XCTAssertEqual(typed?.type.erasedQualifiedName, "java.lang.Exception")
        let generic = await JavaExpressionTyper.typeOfExpression("Ids.id(e)", locals: resolved, context: resolution, index: index)
        XCTAssertEqual(generic?.type.erasedQualifiedName, "java.lang.Exception")

        let memberNames = await names(of: caught.type, index: index)
        XCTAssertTrue(memberNames.contains("getMessage"))
        XCTAssertTrue(memberNames.contains("printStackTrace"))
        XCTAssertFalse(memberNames.contains("getSQLState"))
        XCTAssertFalse(memberNames.contains("read"))

        let assignability = JavaAssignability(index: index, context: resolution)
        let exception = classType("java.lang.Exception")
        let sql = classType("java.sql.SQLException")
        let matchesException = await JavaCompletionProvider.matchesExpected(caught.type, expected: [exception], assignability: assignability)
        let matchesSQL = await JavaCompletionProvider.matchesExpected(caught.type, expected: [sql], assignability: assignability)
        let assignsToSQL = await assignability.isAssignable(caught.type, to: sql)
        XCTAssertTrue(matchesException)
        XCTAssertFalse(matchesSQL)
        XCTAssertFalse(assignsToSQL, "the lub must not prove a subtype of one alternative")

        let origin = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let chains = await JavaCompletionSuggestions.chains(
            locals: resolved, members: [], expected: [classType("java.lang.String")],
            invocationCount: 2, mode: .smart, fastHasExpectedMatch: false,
            factory: JavaCompletionItemFactory(range: TextRange(start: origin, end: origin), source: ""),
            context: resolution, index: index, assignability: assignability
        )
        XCTAssertTrue(chains.contains { $0.label == "e.getMessage" })
        XCTAssertFalse(chains.contains { $0.label.contains("getSQLState") })

        let dot = await complete(header + """
        class Foo {
            void m() {
                try { } catch (IOException | SQLException e) { e.€ }
            }
        }
        """, index: index)
        XCTAssertTrue(dot.contains("getMessage"))
        XCTAssertTrue(dot.contains("printStackTrace"))
        XCTAssertFalse(dot.contains("getSQLState"))
        XCTAssertFalse(dot.contains("read"))

        let statement = await complete(header + """
        class Foo {
            void m() {
                try { } catch (IOException | SQLException e) { Exception value = e€ }
            }
        }
        """, index: index)
        XCTAssertTrue(statement.contains("e"))
    }

    func testStatementMatchUsesTheSharedCatchType() async throws {
        let source = header + """
        class Foo {
            void m() {
                try { } catch (IOException | SQLException e) {
                    Exception wide = e;
                    SQLException narrow = e;
                }
            }
        }
        """
        let index = try await makeIndex(source: source)
        let wide = await item(named: "e", in: header + """
        class Foo {
            void m() {
                try { } catch (IOException | SQLException e) { Exception wide = e€ }
            }
        }
        """, index: index)
        let narrow = await item(named: "e", in: header + """
        class Foo {
            void m() {
                try { } catch (IOException | SQLException e) { SQLException narrow = e€ }
            }
        }
        """, index: index)
        XCTAssertEqual(wide?.preselect, true)
        XCTAssertEqual(wide?.detail, "Exception")
        XCTAssertEqual(narrow?.preselect, false)
        XCTAssertEqual(narrow?.detail, "Exception")
    }

    func testIncompleteMultiCatchIsThrowableEverywhere() async throws {
        let source = header + """
        class Foo {
            void m() {
                try { } catch (IOException | Gone e) {
                    var copy = e;
                    Ids.id(e);
                }
            }
        }
        """
        let index = try await makeIndex(source: source)
        let parsed = try tree(source)
        let resolution = context()
        let locals = parsed.visibleLocals(atByteOffset: offset(of: "Ids.id", in: source))
        let resolved = await JavaExpressionTyper.resolvingVarLocals(locals, context: resolution, index: index)
        let caught = try XCTUnwrap(resolved.first { $0.name == "e" })
        let copy = try XCTUnwrap(resolved.first { $0.name == "copy" })
        XCTAssertEqual(caught.type.erasedQualifiedName, "java.lang.Throwable")
        XCTAssertEqual(copy.type.erasedQualifiedName, "java.lang.Throwable")
        XCTAssertEqual(JavaSignatureText.text(of: caught.type), "Throwable")
        let typed = await JavaExpressionTyper.typeOfExpression("e", locals: locals, context: resolution, index: index)
        XCTAssertEqual(typed?.type.erasedQualifiedName, "java.lang.Throwable")
        let generic = await JavaExpressionTyper.typeOfExpression("Ids.id(e)", locals: resolved, context: resolution, index: index)
        XCTAssertEqual(generic?.type.erasedQualifiedName, "java.lang.Throwable")

        let memberNames = await names(of: caught.type, index: index)
        XCTAssertTrue(memberNames.contains("printStackTrace"))
        XCTAssertFalse(memberNames.contains("read"), "the resolved alternative's own methods are not the catch type")
        XCTAssertFalse(memberNames.contains("getMessage"))
        XCTAssertFalse(memberNames.contains("getSQLState"))

        let assignability = JavaAssignability(index: index, context: resolution)
        let assignsToIO = await assignability.isAssignable(caught.type, to: classType("java.io.IOException"))
        XCTAssertFalse(assignsToIO)

        let dot = await complete(header + """
        class Foo {
            void m() {
                try { } catch (IOException | Gone e) { e.€ }
            }
        }
        """, index: index)
        XCTAssertTrue(dot.contains("printStackTrace"))
        XCTAssertFalse(dot.contains("read"))
        XCTAssertFalse(dot.contains("getMessage"))
        XCTAssertFalse(dot.contains("getSQLState"))
    }

    private func complete(_ marked: String, index: JavaIndex) async -> Set<String> {
        Set(await items(in: marked, index: index).map(\.label))
    }

    private func item(named name: String, in marked: String, index: JavaIndex) async -> CompletionItem? {
        await items(in: marked, index: index).first { $0.label == name }
    }

    private func items(in marked: String, index: JavaIndex) async -> [CompletionItem] {
        let marker = marked.range(of: "€")!
        let text = marked.replacingOccurrences(of: "€", with: "")
        let utf16 = marked.utf16.distance(from: marked.utf16.startIndex, to: marker.lowerBound.samePosition(in: marked.utf16)!)
        let lines = String(text.utf16.prefix(utf16))!.components(separatedBy: "\n")
        let position = TextPosition(line: lines.count - 1, column: (lines.last ?? "").utf16.count, utf16Offset: utf16)
        let document = Document(
            id: DocumentID(), url: fileURL, displayName: "Catch.java",
            contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: TextRange(start: position, end: position)), cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: "java"
        )
        return await JavaCompletionProvider(index: index).provide(context: makeCompletionContext(document: document, trigger: .manual))
    }
}
