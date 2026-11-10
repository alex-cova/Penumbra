import XCTest
@testable import JavaIntelligence

/// Local and anonymous classes are named by the declaration's start byte and live in the
/// request's registry. A later parse, a different document, or another task must not resolve
/// the previous revision's name.
final class JavaLocalClassIdentityTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/proj/Foo.java")

    private func strip(_ source: String) -> (text: String, offset: Int) {
        let marker = source.range(of: "€")!
        let offset = source.utf8.distance(
            from: source.utf8.startIndex,
            to: marker.lowerBound.samePosition(in: source.utf8)!)
        return (source.replacingOccurrences(of: "€", with: ""), offset)
    }

    private func bind(
        _ text: String, at offset: Int, package: String = "p", fileURL: URL? = nil
    ) -> (names: [String: String], registry: JavaAnonymousClass.Registry, tree: JavaSyntaxTree) {
        let url = fileURL ?? file
        let tree = JavaSyntaxParser().parse(text)!
        let registry = JavaAnonymousClass.Registry(fileURL: url)
        let context = JavaResolutionContext(packageName: package, imports: [])
        let bound = JavaAnonymousClass.$registry.withValue(registry) {
            JavaAnonymousClass.bindLocalClasses(in: tree, atByteOffset: offset, context: context, fileURL: url)
        }
        return (bound.localTypes, registry, tree)
    }

    private func site(of qualifiedName: String) -> Int {
        guard let marker = qualifiedName.range(of: "$Local") else {
            XCTFail("\(qualifiedName) has no local-class site")
            return -1
        }
        let digits = qualifiedName[marker.upperBound...].prefix { $0.isNumber }
        return Int(digits) ?? -1
    }

    func testAnEditBeforeALocalClassChangesItsIdentity() async {
        let original = """
        package p;
        class Foo {
          void m() {
            class Acc { int n; }
            Acc €a;
          }
        }
        """
        let edited = """
        package p;
        class Foo {
          void m() {
            int pad;
            class Acc { int n; }
            Acc €a;
          }
        }
        """
        let (beforeText, beforeOffset) = strip(original)
        let (afterText, afterOffset) = strip(edited)
        let before = bind(beforeText, at: beforeOffset)
        let after = bind(afterText, at: afterOffset)
        let oldName = before.names["Acc"]!
        let newName = after.names["Acc"]!
        XCTAssertNotEqual(oldName, newName)
        XCTAssertGreaterThan(site(of: newName), site(of: oldName))
        XCTAssertNil(after.registry.stub(named: oldName))
        XCTAssertNotNil(after.registry.stub(named: newName))
        XCTAssertNil(before.registry.stub(named: newName))

        let index = JavaIndex()
        await JavaAnonymousClass.$registry.withValue(before.registry) {
            let visible = await index.classStub(qualifiedName: oldName)
            XCTAssertEqual(visible?.qualifiedName, oldName)
            let hidden = await JavaAnonymousClass.$registry.withValue(after.registry) {
                await index.classStub(qualifiedName: oldName)
            }
            XCTAssertNil(hidden)
            let stillThere = await index.classStub(qualifiedName: oldName)
            XCTAssertEqual(stillThere?.qualifiedName, oldName)
        }
    }

    func testAnEditInsideALocalClassKeepsTheSiteAndDropsThePreviousStub() {
        let original = """
        package p;
        class Foo {
          void m() {
            class Acc { int n; €}
          }
        }
        """
        let edited = """
        package p;
        class Foo {
          void m() {
            class Acc { int n; int extra; €}
          }
        }
        """
        let (beforeText, beforeOffset) = strip(original)
        let (afterText, afterOffset) = strip(edited)
        let before = bind(beforeText, at: beforeOffset)
        let after = bind(afterText, at: afterOffset)
        XCTAssertEqual(before.names["Acc"], after.names["Acc"])
        let name = after.names["Acc"]!
        XCTAssertNil(before.registry.stub(named: name)?.fields.first { $0.name == "extra" })
        XCTAssertNotNil(after.registry.stub(named: name)?.fields.first { $0.name == "extra" })
    }

    func testIncrementalReparseDoesNotReuseThePreviousScope() throws {
        let parser = JavaSyntaxParser()
        let (beforeText, beforeOffset) = strip("class Foo { void m() { int pad = 1;\n    € } }")
        let previous = try XCTUnwrap(parser.parse(beforeText))
        XCTAssertTrue(previous.visibleLocals(atByteOffset: beforeOffset).map(\.name).contains("pad"))
        let stubs = JavaSourceStubBuilder.build(tree: previous, url: file)
        let (afterText, afterOffset) = strip("class Foo { void m() { € } }")
        let reparsed = try XCTUnwrap(JavaStubReuse.reparse(
            previous: (previous, stubs), to: afterText, parser: parser, url: file))
        XCTAssertFalse(reparsed.tree === previous)
        XCTAssertFalse(reparsed.tree.visibleLocals(atByteOffset: afterOffset).map(\.name).contains("pad"))
    }

    func testSiblingAndNestedLocalClassesStayDistinct() {
        let (leftText, leftOffset) = strip("""
        package p;
        class Foo {
          void m() {
            { class Acc { int left; } Acc €a; }
            { class Acc { int right; } Acc b; }
          }
        }
        """)
        let (rightText, rightOffset) = strip("""
        package p;
        class Foo {
          void m() {
            { class Acc { int left; } Acc a; }
            { class Acc { int right; } Acc €b; }
          }
        }
        """)
        let (otherText, otherOffset) = strip("""
        package p;
        class Foo {
          void m() {
            { class Acc { int left; } Acc a; }
          }
          void n() { € }
        }
        """)
        let left = bind(leftText, at: leftOffset)
        let right = bind(rightText, at: rightOffset)
        let other = bind(otherText, at: otherOffset)
        XCTAssertNotEqual(left.names["Acc"], right.names["Acc"])
        XCTAssertTrue(left.names["Acc"]!.hasSuffix(".Acc"))
        XCTAssertTrue(right.names["Acc"]!.hasSuffix(".Acc"))
        XCTAssertNil(other.names["Acc"])

        let (nestedText, nestedOffset) = strip("""
        package p;
        class Foo {
          void m() {
            class Outer {
              void n() {
                class Inner { int y; }
                Inner €x;
              }
            }
          }
        }
        """)
        let nested = bind(nestedText, at: nestedOffset)
        let outer = nested.names["Outer"]!
        let inner = nested.names["Inner"]!
        XCTAssertTrue(outer.hasPrefix("p.Foo.$Local"))
        XCTAssertTrue(outer.hasSuffix(".Outer"))
        XCTAssertTrue(inner.hasPrefix(outer + ".$Local"))
        XCTAssertTrue(inner.hasSuffix(".Inner"))
        XCTAssertEqual(nested.registry.stub(named: inner)?.outerQualifiedName, outer)
        XCTAssertEqual(nested.registry.stub(named: outer)?.outerQualifiedName, "p.Foo")
    }

    func testAnonymousClassInsideALocalClassKeepsPrivateAccess() async throws {
        let (text, offset) = strip("""
        package p;
        class Foo {
          void m() {
            class Acc {
              private int secret;
              class Nested { private int buried; }
              Object o = new Object() {
                private int own;
                void run() { int €x; }
              };
            }
          }
        }
        """)
        let url = file
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(text))
        let object = JavaClassStub(
            binaryName: "java.lang.Object", qualifiedName: "java.lang.Object", simpleName: "Object", packageName: "java.lang",
            kind: .classKind, modifiers: [.publicFlag], origin: .jdkModule("java.base")
        )
        let index = JavaIndex()
        let shard = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write([object], stamp: JavaStamp(size: 0, modificationDate: 0), to: shard)
        await index.setSources([.init(precedence: 3, reader: try JavaIndexShardReader(url: shard))])
        let registry = JavaAnonymousClass.Registry(fileURL: url)
        let fileContext = JavaResolutionContext.file(JavaSourceStubBuilder.build(tree: tree, url: url))
        try await JavaAnonymousClass.$registry.withValue(registry) {
            let bound = JavaAnonymousClass.bindLocalClasses(
                in: tree, atByteOffset: offset, context: fileContext, fileURL: url)
            var context = fileContext.withLocalClasses(bound.localTypes, enclosing: bound.enclosing)
            let acc = try XCTUnwrap(bound.localTypes["Acc"])
            let accStub = try XCTUnwrap(registry.stub(named: acc))
            XCTAssertEqual(accStub.outerQualifiedName, "p.Foo")
            XCTAssertTrue(accStub.fields.contains { $0.name == "secret" && $0.modifiers.contains(.privateFlag) })
            let nestedName = try XCTUnwrap(accStub.innerTypeNames.first { $0.hasSuffix(".Nested") })
            XCTAssertEqual(registry.stub(named: nestedName)?.outerQualifiedName, acc)

            var anonymous: JavaClassStub?
            for creation in JavaAnonymousClass.enclosingCreations(in: tree, atByteOffset: offset).reversed() {
                if let stub = await JavaAnonymousClass.stub(for: creation, context: context, index: index) {
                    anonymous = stub
                    context = context.entering(type: stub)
                }
            }
            let anonymousStub = try XCTUnwrap(anonymous)
            XCTAssertTrue(anonymousStub.qualifiedName.contains("$Anonymous"))
            XCTAssertEqual(anonymousStub.outerQualifiedName, "p.Foo")

            let visible = Set((await JavaMemberLookup.members(
                of: .classType(qualifiedName: acc, arguments: [], outer: nil),
                mode: .instance, context: context, index: index)).map(\.name))
            XCTAssertTrue(visible.contains("secret"))
            let buried = Set((await JavaMemberLookup.members(
                of: .classType(qualifiedName: nestedName, arguments: [], outer: nil),
                mode: .instance, context: context, index: index)).map(\.name))
            XCTAssertTrue(buried.contains("buried"))
            let own = Set((await JavaMemberLookup.members(
                of: .classType(qualifiedName: anonymousStub.qualifiedName, arguments: [], outer: nil),
                mode: .instance, context: context, index: index)).map(\.name))
            XCTAssertTrue(own.contains("own"))

            let foreign = JavaResolutionContext(
                packageName: "p", imports: [], enclosingTypeQualifiedNames: ["p.Other"])
            let hidden = Set((await JavaMemberLookup.members(
                of: .classType(qualifiedName: acc, arguments: [], outer: nil),
                mode: .instance, context: foreign, index: index)).map(\.name))
            XCTAssertFalse(hidden.contains("secret"))

            registry.register(JavaClassStub(
                binaryName: acc, qualifiedName: acc, simpleName: "Acc", packageName: "p",
                outerQualifiedName: "p.Foo", kind: .classKind, modifiers: [],
                fields: [JavaFieldStub(name: "other", type: .primitive(.int), modifiers: [.publicFlag])],
                origin: .jdkModule("test")
            ))
            let replaced = Set((await JavaMemberLookup.members(
                of: .classType(qualifiedName: acc, arguments: [], outer: nil),
                mode: .instance, context: context, index: index)).map(\.name))
            XCTAssertTrue(replaced.contains("other"))
            XCTAssertFalse(replaced.contains("secret"))
        }
    }

    func testADocumentSwitchReparsesFromThatDocument() async throws {
        let provider = JavaCompletionProvider(index: JavaIndex())
        let urlA = URL(fileURLWithPath: "/proj/A.java")
        let urlB = URL(fileURLWithPath: "/proj/B.java")
        let original = "package p;\nclass A { void m() { class Acc { int n; } Acc a; } }\n"
        let edited = "package p;\nclass A { void m() { int pad; class Acc { int n; } Acc a; } }\n"
        let other = "package q;\nclass B { void m() { class Acc { int n; } Acc a; } }\n"
        let firstParsed = await provider.parse(original, url: urlA)
        let shiftedParsed = await provider.parse(edited, url: urlA)
        let first = try XCTUnwrap(firstParsed)
        let shifted = try XCTUnwrap(shiftedParsed)
        XCTAssertFalse(first.tree === shifted.tree)
        let switchedParsed = await provider.parse(other, url: urlB)
        let backParsed = await provider.parse(edited, url: urlA)
        let againParsed = await provider.parse(edited, url: urlA)
        let switched = try XCTUnwrap(switchedParsed)
        let back = try XCTUnwrap(backParsed)
        let again = try XCTUnwrap(againParsed)
        XCTAssertTrue(back.tree === again.tree)

        func accName(in tree: JavaSyntaxTree, package: String, url: URL) -> String? {
            let source = tree.rootNode.text
            guard let range = source.range(of: "Acc a") else { return nil }
            let offset = source.utf8.distance(
                from: source.utf8.startIndex, to: range.lowerBound.samePosition(in: source.utf8)!)
            let registry = JavaAnonymousClass.Registry(fileURL: url)
            let context = JavaResolutionContext(packageName: package, imports: [])
            return JavaAnonymousClass.$registry.withValue(registry) {
                JavaAnonymousClass.bindLocalClasses(
                    in: tree, atByteOffset: offset, context: context, fileURL: url
                ).localTypes["Acc"]
            }
        }
        let freshA = try XCTUnwrap(JavaSyntaxParser().parse(edited))
        let freshB = try XCTUnwrap(JavaSyntaxParser().parse(other))
        XCTAssertEqual(accName(in: back.tree, package: "p", url: urlA), accName(in: freshA, package: "p", url: urlA))
        XCTAssertEqual(accName(in: switched.tree, package: "q", url: urlB), accName(in: freshB, package: "q", url: urlB))
        XCTAssertNotEqual(accName(in: first.tree, package: "p", url: urlA), accName(in: back.tree, package: "p", url: urlA))
    }
}
