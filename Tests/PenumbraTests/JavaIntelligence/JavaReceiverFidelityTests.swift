import EditorIntelligence
import Foundation
import XCTest
@testable import JavaIntelligence

/// The last receiver-type mismatches of the javac audit (`docs/JAVA_RECEIVER_FIDELITY_FINAL_AUDIT.md`),
/// checked against javac itself rather than against a printed type name.
///
/// Each site is answered twice on the same text: by the engine (the completion provider with the caret
/// after the dot, the receiver type and the offered members) and by javac
/// (`Tools/JavaReceiverOracle/ReceiverMemberOracle.java`: the attributed receiver type, its binary name,
/// its owners and the instance members accessible at that site). The receiver audit compares how a type
/// is *written*; these tests compare what it *is*: which class, owned by what, and with which members.
/// Skipped without a JDK.
final class JavaReceiverFidelityTests: XCTestCase {
    private static let corpus = Task { try await CorpusIndex.build() }

    // MARK: - Harness

    struct EngineSite {
        let type: JavaTypeRef?
        let members: Set<String>
    }

    struct JavacSite {
        var line = 0
        var receiver = ""
        let type: String
        let binary: String?
        let owners: String?
        let members: Set<String>
        /// `name : signature` as javac's `Types.asMemberOf` writes it.
        let signatures: [String: [String]]
    }

    private func corpus() async throws -> CorpusIndex {
        do { return try await Self.corpus.value } catch { throw XCTSkip("No JDK with ct.sym") }
    }

    /// The engine at `€` (removed from the text), with the file written to disk so declaring-file
    /// reads see it, and the file's own classes in the overlay as Umbra keeps them.
    private var fidelityRoot: URL {
        fixtureDirectory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func engine(
        _ marked: String, file name: String = "Fixture", provider existing: JavaCompletionProvider? = nil,
        also: [(path: String, text: String)] = []
    ) async throws -> EngineSite {
        let corpus = try await corpus()
        let marker = try XCTUnwrap(marked.range(of: "€"))
        let utf16 = marked.utf16.distance(from: marked.utf16.startIndex, to: marker.lowerBound.samePosition(in: marked.utf16)!)
        let text = marked.replacingOccurrences(of: "€", with: "")
        let url = try write(text, name: name)
        let prefix = (text as NSString).substring(to: utf16)
        let lines = prefix.components(separatedBy: "\n")
        let position = TextPosition(line: lines.count - 1, column: (lines.last ?? "").utf16.count, utf16Offset: utf16)
        let document = Document(
            id: DocumentID(), url: url, displayName: url.lastPathComponent,
            contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: TextRange(start: position, end: position)), cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: "java"
        )
        let context = CompletionContext(
            document: document, cursor: Cursor(position: position), trigger: .manual, prefix: "",
            range: TextRange(start: position, end: position)
        )
        let parseable = JavaCompletionProvider.repairedText(text, insertingDummyAt: utf16)
        var own = JavaSourceStubBuilder.build(source: parseable, url: url).classes
        for extra in also {
            let extraURL = fidelityRoot.appendingPathComponent(extra.path)
            try FileManager.default.createDirectory(at: extraURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try extra.text.write(to: extraURL, atomically: true, encoding: .utf8)
            own += JavaSourceStubBuilder.build(source: extra.text, url: extraURL).classes
        }
        await corpus.index.setOverlay(Dictionary(own.map { ($0.qualifiedName, $0) }, uniquingKeysWith: { first, _ in first }))
        let provider = existing ?? JavaCompletionProvider(index: corpus.index)
        let diagnosis = await provider.diagnose(context: context)
        let items = await provider.provide(context: context)
        let members = Set(items.filter { [.method, .field, .property].contains($0.kind) }.map(\.label))
        return EngineSite(type: diagnosis?.receiverType, members: members)
    }

    private var fixtureDirectory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("receiver-fidelity-\(UUID().uuidString)/com/acme/cases", isDirectory: true)

    override func tearDown() {
        // `…/receiver-fidelity-<uuid>/com/acme/cases`: remove the whole per-test root.
        try? FileManager.default.removeItem(at: fixtureDirectory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
        super.tearDown()
    }

    private func write(_ text: String, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        let url = fixtureDirectory.appendingPathComponent("\(name).java")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// javac on the same text (markers removed): one entry per `line:receiver` asked for.
    private func javac(
        _ marked: String, file name: String = "Fixture", sites: [String], classpath: [URL] = [],
        extraSourcepath: URL? = nil
    ) throws -> [JavacSite] {
        let jdk = try ParityTestSupport.requireJDK()
        let text = marked.replacingOccurrences(of: "€", with: "")
        let url = try write(text, name: name)
        let oracle = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/JavaReceiverOracle/ReceiverMemberOracle.java")
        let process = Process()
        process.executableURL = jdk.home.appendingPathComponent("bin/java")
        var sourcepath = CorpusIndex.directory.appendingPathComponent("project").path
        if let extraSourcepath { sourcepath += ":" + extraSourcepath.path }
        var arguments = [oracle.path, "-sourcepath", sourcepath]
        if !classpath.isEmpty { arguments += ["-cp", classpath.map(\.path).joined(separator: ":")] }
        process.arguments = arguments + [url.path] + sites
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // The oracle reports in tree order; answer in the order asked.
        let parsed = Self.parse(String(decoding: data, as: UTF8.self))
        return sites.compactMap { wanted in
            let parts = wanted.split(separator: ":", maxSplits: 1).map(String.init)
            return parsed.first { String($0.line) == parts[0] && (parts.count == 1 || $0.receiver == parts[1]) }
        }
    }

    static func parse(_ output: String) -> [JavacSite] {
        var sites: [JavacSite] = []
        var type: String?, binary: String?, owners: String?
        var line = 0, receiver = ""
        func flush(members: Set<String>, signatures: [String: [String]]) {
            if let current = type {
                sites.append(JavacSite(line: line, receiver: receiver, type: current, binary: binary, owners: owners, members: members, signatures: signatures))
            }
            type = nil; binary = nil; owners = nil
        }
        for row in output.split(separator: "\n").map(String.init) {
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("== line") {
                if type != nil { flush(members: [], signatures: [:]) }
                // `== line 24 | counter .count`
                let header = trimmed.dropFirst("== line ".count)
                let fields = header.components(separatedBy: " | ")
                line = Int(fields[0]) ?? 0
                receiver = fields.count > 1 ? (fields[1].components(separatedBy: " .").dropLast().joined(separator: " .")) : ""
                // `receiver @start:end`: the oracle appends the receiver's source range.
                if let at = receiver.range(of: " @", options: .backwards) { receiver = String(receiver[..<at.lowerBound]) }
            } else if trimmed.hasPrefix("type:") {
                type = String(trimmed.dropFirst("type:".count)).components(separatedBy: "   (kind").first?.trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("binary:") {
                binary = String(trimmed.dropFirst("binary:".count)).components(separatedBy: "   nesting").first?.trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("owners:") {
                owners = String(trimmed.dropFirst("owners:".count)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("members ("), let colon = trimmed.range(of: "): ") {
                var names = Set<String>()
                var signatures: [String: [String]] = [:]
                for entry in trimmed[colon.upperBound...].components(separatedBy: ", ") {
                    let parts = entry.components(separatedBy: " : ")
                    names.insert(parts[0])
                    if parts.count > 1 { signatures[parts[0], default: []].append(parts[1]) }
                }
                flush(members: names, signatures: signatures)
            }
        }
        if type != nil { flush(members: [], signatures: [:]) }
        return sites
    }

    private func assertSameMembers(_ engine: Set<String>, _ javac: Set<String>, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let extra = engine.subtracting(javac).sorted()
        let missing = javac.subtracting(engine).sorted()
        XCTAssertTrue(extra.isEmpty && missing.isEmpty, "\(message): engine offers \(extra) that javac does not; misses \(missing)", file: file, line: line)
    }

    private func qualifiedName(_ type: JavaTypeRef?) -> String? {
        if case .classType(let name, _, _)? = type { return name }
        return nil
    }

    /// javac's `capture#1 of ? extends X` read as `? extends X`, and qualifiers dropped:
    /// the engine keeps the wildcard that javac captures.
    private func uncaptured(_ javac: String) -> String {
        let capture = try! NSRegularExpression(pattern: "capture#\\d+ of ")
        let range = NSRange(javac.startIndex..., in: javac)
        return capture.stringByReplacingMatches(in: javac, range: range, withTemplate: "")
    }

    private func simplified(_ type: String) -> String {
        JavaReceiverTypeAudit.simplified(type)
    }

    // MARK: - Cluster A: a class declared in an anonymous class body

    /// The shape of commons-collections `CellExtractor.from` (eight audit sites): a member class of an
    /// anonymous class, used as a local's type, a field's type argument, and a lambda's parameter.
    private let extractor = """
    package com.acme.cases;

    import java.util.TreeMap;

    interface Extractor {
        int[] indices();

        static Extractor from(int[] values) {
            return new Extractor() {
                final class Cell implements Comparable<Cell> {
                    final int idx;
                    int count;
                    Cell(int idx, int count) { this.idx = idx; this.count = count; }
                    @Override public int compareTo(Cell other) { return Integer.compare(idx, other.idx); }
                }

                TreeMap<Cell, Cell> cells = new TreeMap<>();

                @Override
                public int[] indices() {
                    for (int v : values) {
                        final Cell cell = new Cell(v, 1);
                        final Cell counter = cells.get(cell);
                        if (counter == null) { cells.put(cell, cell); } else { counter.€count++; }
                    }
                    return cells.keySet().stream().mapToInt(c -> c.idx).toArray();
                }
            };
        }
    }
    """

    func testMemberClassOfAnAnonymousClassHasJavacsOwnerAndMembers() async throws {
        let javacSites = try javac(extractor, file: "Extractor", sites: ["24:counter", "26:cells", "26:cells.keySet()"])
        XCTAssertEqual(javacSites.count, 3)
        let counter = try XCTUnwrap(javacSites.first)
        XCTAssertEqual(counter.binary, "com.acme.cases.Extractor$1$Cell")
        XCTAssertEqual(counter.type, "<anonymous com.acme.cases.Extractor>.Cell")
        XCTAssertTrue(counter.owners?.hasPrefix("<- CLASS com.acme.cases.Extractor$1 <- METHOD from") == true, counter.owners ?? "")

        let site = try await engine(extractor, file: "Extractor")
        let name = try XCTUnwrap(qualifiedName(site.type))
        // The engine's identity: a member `Cell` of the anonymous class (`Extractor.$Anonymous<hash>`),
        // which is javac's `Extractor$1$Cell`. The audit prints both as `Cell` after dropping qualifiers.
        XCTAssertTrue(name.hasPrefix("com.acme.cases.Extractor.$Anonymous"), name)
        XCTAssertTrue(name.hasSuffix(".Cell"), name)
        XCTAssertEqual(name.split(separator: ".").count, 6, name)
        assertSameMembers(site.members, counter.members, "site")

        // The same identity in type arguments, and through `keySet()`. The hash is per request (the
        // creation's text holds the caret's dummy identifier), so names are compared within a request.
        let cells = try await engine(extractor.replacingOccurrences(of: "counter.€count++", with: "counter.count++")
            .replacingOccurrences(of: "return cells.keySet()", with: "return cells.€keySet()"), file: "Extractor")
        let keySet = try await engine(extractor.replacingOccurrences(of: "counter.€count++", with: "counter.count++")
            .replacingOccurrences(of: "keySet().stream()", with: "keySet().€stream()"), file: "Extractor")
        for (site, erased, count) in [(cells, "java.util.TreeMap", 2), (keySet, "java.util.Set", 1)] {
            guard case .classType(let outer, let arguments, _)? = site.type else { return XCTFail("\(erased): \(String(describing: site.type))") }
            XCTAssertEqual(outer, erased)
            XCTAssertEqual(arguments.count, count)
            for case .type(.classType(let argument, _, _)) in arguments {
                XCTAssertTrue(argument.hasPrefix("com.acme.cases.Extractor.$Anonymous") && argument.hasSuffix(".Cell"), argument)
            }
        }
        assertSameMembers(cells.members, javacSites[1].members, "cells")
        assertSameMembers(keySet.members, javacSites[2].members, "cells.keySet()")
    }

    /// One declaration, one identity within a request: `counter` names `Cell` in the body (the local
    /// binding), `cells.firstKey()` reaches it through the anonymous class's field. A conditional's type
    /// is the lub of its arms, so it is `Cell` only when the two are the same type. Before the binding
    /// used the anonymous name, the arms were `Extractor.$Local<start>.Cell` and
    /// `Extractor.$Anonymous<hash>.Cell`, and the lub fell to their common supertype.
    func testOneIdentityWhetherNamedInTheBodyOrReachedThroughTheAnonymousClass() async throws {
        let source = extractor.replacingOccurrences(of: "counter.€count++", with: "(values.length > 0 ? counter : cells.firstKey()).€count++")
        let expected = try XCTUnwrap(javac(source, file: "Extractor", sites: ["24:(values.length > 0 ? counter : cells.firstKey())"]).first)
        XCTAssertEqual(expected.binary, "com.acme.cases.Extractor$1$Cell")
        let site = try await engine(source, file: "Extractor")
        let name = try XCTUnwrap(qualifiedName(site.type), "\(String(describing: site.type))")
        XCTAssertTrue(name.hasPrefix("com.acme.cases.Extractor.$Anonymous") && name.hasSuffix(".Cell"), name)
        assertSameMembers(site.members, expected.members, "conditional")
    }

    /// The example from the task, and the lambda parameter typed by the anonymous member class.
    func testNestedClassReturnedInsideTheAnonymousBody() async throws {
        let source = """
        package com.acme.cases;

        class Outer {
            Object create() {
                return new Object() {
                    class Nested {
                        int value;
                    }

                    Nested createNested() {
                        return new Nested();
                    }

                    int read() {
                        return createNested().€value;
                    }
                };
            }
        }
        """
        let expected = try XCTUnwrap(javac(source, file: "Outer", sites: ["15:createNested()"]).first)
        XCTAssertEqual(expected.binary, "com.acme.cases.Outer$1$Nested")
        let site = try await engine(source, file: "Outer")
        XCTAssertTrue(qualifiedName(site.type)?.hasPrefix("com.acme.cases.Outer.$Anonymous") == true, "\(String(describing: site.type))")
        XCTAssertTrue(qualifiedName(site.type)?.hasSuffix(".Nested") == true)
        assertSameMembers(site.members, expected.members, "site")
    }

    /// Two anonymous classes that each declare `Nested`, with different members: two identities.
    func testTwoAnonymousClassesWithTheSameNestedNameStayDistinct() async throws {
        let source = """
        package com.acme.cases;

        class Twins {
            void run() {
                var left = new Object() {
                    class Nested { int value; }
                    Nested make() { return new Nested(); }
                };
                var right = new Object() {
                    class Nested { String other; }
                    Nested make() { return new Nested(); }
                };
                int a = left.make().value;
                int b = right.make().other.length();
                €
            }
        }
        """
        let expected = try javac(source, file: "Twins", sites: ["13:left.make()", "14:right.make()"])
        XCTAssertEqual(expected.map(\.binary), ["com.acme.cases.Twins$1$Nested", "com.acme.cases.Twins$2$Nested"])
        let left = try await engine(source.replacingOccurrences(of: "left.make().value", with: "left.make().€value").replacingOccurrences(of: "€\n", with: "\n"), file: "Twins")
        let right = try await engine(source.replacingOccurrences(of: "right.make().other", with: "right.make().€other").replacingOccurrences(of: "€\n", with: "\n"), file: "Twins")
        let leftName = try XCTUnwrap(qualifiedName(left.type))
        let rightName = try XCTUnwrap(qualifiedName(right.type))
        XCTAssertNotEqual(leftName, rightName)
        XCTAssertTrue(leftName.hasSuffix(".Nested") && rightName.hasSuffix(".Nested"))
        assertSameMembers(left.members, expected[0].members, "left")
        assertSameMembers(right.members, expected[1].members, "right")
        XCTAssertFalse(left.members.contains("other"))
        XCTAssertFalse(right.members.contains("value"))
    }

    /// An anonymous class inside an anonymous class, and one inside a local class.
    func testAnonymousClassesNestedInAnonymousAndLocalClasses() async throws {
        let source = """
        package com.acme.cases;

        class Nesting {
            void run() {
                Runnable outer = new Runnable() {
                    public void run() {
                        Object inner = new Object() {
                            class Deep { int depth; }
                            int go() { return new Deep().€depth; }
                        };
                    }
                };
                class Local {
                    Object make() {
                        return new Object() {
                            class In { int k; }
                            In in() { return new In(); }
                            int touch() { return in().k; }
                        };
                    }
                }
            }
        }
        """
        let expected = try javac(source, file: "Nesting", sites: ["9:new Deep()", "18:in()"])
        XCTAssertEqual(expected.map(\.binary), ["com.acme.cases.Nesting$1$1$Deep", "com.acme.cases.Nesting$1Local$1$In"])
        let deep = try await engine(source, file: "Nesting")
        XCTAssertTrue(qualifiedName(deep.type)?.hasSuffix(".Deep") == true, "\(String(describing: deep.type))")
        assertSameMembers(deep.members, expected[0].members, "deep")
        let local = try await engine(source.replacingOccurrences(of: "new Deep().€depth", with: "new Deep().depth")
            .replacingOccurrences(of: "in().k;", with: "in().€k;"), file: "Nesting")
        XCTAssertTrue(qualifiedName(local.type)?.hasSuffix(".In") == true, "\(String(describing: local.type))")
        assertSameMembers(local.members, expected[1].members, "local")
    }

    /// The anonymous member class in a type argument, through a cast, and through an inferred local.
    func testAnonymousMemberClassInArgumentsCastsAndVar() async throws {
        let source = """
        package com.acme.cases;

        import java.util.ArrayList;
        import java.util.List;

        class Shapes {
            Object make() {
                return new Object() {
                    class Item { int weight; }
                    List<Item> items = new ArrayList<>();
                    int a() { return items.get(0).weight; }
                    int b(Object o) { return ((Item) o).weight; }
                    int c() { var item = new Item(); return item.weight; }
                };
            }
        }
        """
        let expected = try javac(source, file: "Shapes", sites: ["11:items.get(0)", "12:((Item)o)", "13:item"])
        XCTAssertEqual(expected.count, 3)
        for (needle, javacSite) in zip(["items.get(0).weight", "((Item) o).weight", "item.weight"], expected) {
            let marked = source.replacingOccurrences(of: needle, with: needle.replacingOccurrences(of: ".weight", with: ".€weight"))
            let site = try await engine(marked, file: "Shapes")
            XCTAssertEqual(javacSite.binary, "com.acme.cases.Shapes$1$Item")
            XCTAssertTrue(qualifiedName(site.type)?.hasSuffix(".Item") == true, "\(needle): \(String(describing: site.type))")
            XCTAssertTrue(qualifiedName(site.type)?.contains("$Anonymous") == true, "\(needle): \(String(describing: site.type))")
            assertSameMembers(site.members, javacSite.members, needle)
        }
    }

    /// The same provider, two revisions of one file: the member class's members follow the edit.
    /// Then a second document whose anonymous class has another body: no members leak across.
    func testEditsAndDocumentSwitchesDoNotReusePreviousAnonymousMembers() async throws {
        let corpus = try await corpus()
        let provider = JavaCompletionProvider(index: corpus.index)
        let before = """
        package com.acme.cases;

        class Edited {
            Object make() {
                return new Object() {
                    class Box { int before; }
                    int read() { return new Box().€before; }
                };
            }
        }
        """
        let after = before.replacingOccurrences(of: "int before;", with: "int after;").replacingOccurrences(of: "€before", with: "€after")
        let first = try await engine(before, file: "Edited", provider: provider)
        let second = try await engine(after, file: "Edited", provider: provider)
        XCTAssertTrue(first.members.contains("before"))
        XCTAssertFalse(first.members.contains("after"))
        XCTAssertTrue(second.members.contains("after"))
        XCTAssertFalse(second.members.contains("before"))

        let other = before.replacingOccurrences(of: "class Edited", with: "class Switched").replacingOccurrences(of: "int before;", with: "int elsewhere;")
            .replacingOccurrences(of: "€before", with: "€elsewhere")
        let third = try await engine(other, file: "Switched", provider: provider)
        let fourth = try await engine(before, file: "Edited", provider: provider)
        XCTAssertEqual(third.members.intersection(["before", "after", "elsewhere"]), ["elsewhere"])
        XCTAssertEqual(fourth.members.intersection(["before", "after", "elsewhere"]), ["before"])
    }

    /// Two textually identical anonymous bodies are two classes for javac (`$1`, `$2`). The engine names
    /// an anonymous class by a hash of its text, so they share a synthetic name; the members stay right
    /// because identical text declares identical members. Pinned so a change to the naming is deliberate.
    func testIdenticalAnonymousBodiesShareANameAndKeepTheirMembers() async throws {
        let source = """
        package com.acme.cases;

        class Identical {
            void run() {
                var a = new Object() { class N { int x; } N n() { return new N(); } };
                var b = new Object() { class N { int x; } N n() { return new N(); } };
                int first = a.n().x;
                int second = b.n().x;
            }
        }
        """
        let expected = try javac(source, file: "Identical", sites: ["7:a.n()", "8:b.n()"])
        XCTAssertEqual(expected.map(\.binary), ["com.acme.cases.Identical$1$N", "com.acme.cases.Identical$2$N"])
        let a = try await engine(source.replacingOccurrences(of: "a.n().x", with: "a.n().€x"), file: "Identical")
        let b = try await engine(source.replacingOccurrences(of: "b.n().x", with: "b.n().€x"), file: "Identical")
        assertSameMembers(a.members, expected[0].members, "a.n()")
        assertSameMembers(b.members, expected[1].members, "b.n()")
    }

    /// A member type written in an anonymous body means what it means *there*: `T` is `Outer.T` even when
    /// the caret is in a block where a local class `T` shadows it.
    func testAnonymousMemberTypesResolveWhereTheyAreWritten() async throws {
        let source = """
        package com.acme.cases;

        class Shadowing {
            static class T { int outerField; }

            void run() {
                var x = new Object() { T t = new T(); };
                {
                    class T { String localField; }
                    x.t.outerField = 1;
                }
            }
        }
        """
        let expected = try XCTUnwrap(javac(source, file: "Shadowing", sites: ["10:x.t"]).first)
        XCTAssertEqual(expected.binary, "com.acme.cases.Shadowing$T")
        let site = try await engine(source.replacingOccurrences(of: "x.t.outerField", with: "x.t.€outerField"), file: "Shadowing")
        XCTAssertEqual(qualifiedName(site.type), "com.acme.cases.Shadowing.T")
        assertSameMembers(site.members, expected.members, "x.t")
    }

    // MARK: - Cluster C: getClass() and the members of an array type

    private let getClassSource = """
    package com.acme.cases;

    import java.util.List;

    class Classes<T extends Number> {
        <E extends CharSequence> void run(String text, String[] array, Object[] objects, int[][] matrix, List<String> list,
                                          T number, E chars, List<? extends Runnable> tasks) {
            var a = text.getClass();
            var b = array.getClass();
            var c = objects.getClass();
            var d = matrix.getClass();
            var e = list.getClass();
            var f = number.getClass();
            var g = chars.getClass();
            var h = tasks.get(0).getClass();
            var i = getClass();
            Object o = null;
            var j = text.getClass().cast(o);
            var k = array.getClass().getComponentType();
            €
        }
    }
    """

    /// `x.getClass()` is `Class<? extends |T|>` (JLS 4.3.2). javac captures the wildcard; the engine keeps
    /// it. Before this change every one of these was `Class<?>`, and the array forms were untyped.
    func testGetClassIsClassOfTheErasureOfTheSearchedType() async throws {
        let expressions = [
            ("text.getClass()", 8), ("array.getClass()", 9), ("objects.getClass()", 10), ("matrix.getClass()", 11),
            ("list.getClass()", 12), ("number.getClass()", 13), ("chars.getClass()", 14), ("tasks.get(0).getClass()", 15),
            ("getClass()", 16), ("text.getClass().cast(o)", 18), ("array.getClass().getComponentType()", 19),
        ]
        let marked = getClassSource
        var javacSites: [JavacSite] = []
        for (expression, line) in expressions {
            // A member access on the expression, so the oracle sees it as a receiver.
            let probe = marked.replacingOccurrences(of: "= \(expression);", with: "= \(expression).hashCode();")
            let site = try XCTUnwrap(javac(probe, file: "Classes", sites: ["\(line):\(expression.replacingOccurrences(of: " ", with: ""))"]).first, expression)
            javacSites.append(site)
        }
        let expectedTypes = [
            "Class<? extends String>", "Class<? extends String[]>", "Class<? extends Object[]>", "Class<? extends int[][]>",
            "Class<? extends List>", "Class<? extends Number>", "Class<? extends CharSequence>", "Class<? extends Runnable>",
            "Class<? extends Classes>", "String", "Class<?>",
        ]
        // javac's own spelling once `capture#1 of` is dropped. Only `cast(o)` differs: javac's receiver
        // is the capture variable itself, the engine's is its bound. Both have `String`'s members.
        var javacTypes = expectedTypes
        javacTypes[9] = "? extends String"
        for ((expression, _), (javacSite, (expected, javacExpected))) in zip(expressions, zip(javacSites, zip(expectedTypes, javacTypes))) {
            XCTAssertEqual(simplified(uncaptured(javacSite.type)), simplified(javacExpected), "javac on \(expression)")
            let probe = marked.replacingOccurrences(of: "= \(expression);", with: "= \(expression).€hashCode();")
                .replacingOccurrences(of: "€\n        }", with: "\n        }")
            let site = try await engine(probe, file: "Classes")
            let engineType = site.type.map(JavaReceiverTypeAudit.describe).map(simplified)
            XCTAssertEqual(engineType, simplified(expected), "engine on \(expression)")
            // A capture's members are its bound's: `cast` comes back as the class itself, as for javac.
            assertSameMembers(site.members, javacSite.members, "members of \(expression)")
        }
    }

    /// JLS 10.7: an array has `length`, a public `clone()` and the members of `Object` except `clone`.
    /// `Object`'s protected members are not accessible through an array (JLS 6.6.2.1).
    func testArrayMembersAreLengthCloneAndObjectsPublicMembers() async throws {
        let source = """
        package com.acme.cases;

        class Arrays2 {
            int run(String[] names, int[] numbers) {
                return names.€length + numbers.length;
            }
        }
        """
        let expected = try javac(source, file: "Arrays2", sites: ["5:names", "5:numbers"])
        XCTAssertEqual(expected.count, 2)
        let names = try await engine(source, file: "Arrays2")
        let numbers = try await engine(source.replacingOccurrences(of: "names.€length", with: "names.length")
            .replacingOccurrences(of: "numbers.length", with: "numbers.€length"), file: "Arrays2")
        assertSameMembers(names.members, expected[0].members, "names")
        assertSameMembers(numbers.members, expected[1].members, "numbers")
        XCTAssertTrue(names.members.isSuperset(of: ["length", "clone", "getClass", "equals", "hashCode", "toString", "wait"]))
        XCTAssertFalse(names.members.contains("finalize"))
    }

    /// JLS 6.6.2.1 and 9.2, checked against javac's accessible members rather than the printed type.
    /// `clone` and `finalize` are legal on `this` and on the subclass receiver, and not on `Object`,
    /// `String`, `List`, or an unbounded type variable. An array keeps its public `clone`.
    func testProtectedObjectMembersMatchJavac() async throws {
        let source = """
        package com.acme.cases;

        import java.util.List;

        class Access<T> {
            void run(Object object, String text, List<String> list, String[] names, Access<T> self, T value) {
                object.€hashCode();
                text.hashCode();
                list.hashCode();
                int unused = names.length;
                self.hashCode();
                this.hashCode();
                value.hashCode();
            }
        }
        """
        let probes: [(line: Int, receiver: String, caret: String)] = [
            (7, "object", "object.€hashCode()"),
            (8, "text", "text.€hashCode()"),
            (9, "list", "list.€hashCode()"),
            (10, "names", "names.€length"),
            (11, "self", "self.€hashCode()"),
            (12, "this", "this.€hashCode()"),
            (13, "value", "value.€hashCode()"),
        ]
        let expected = try javac(source, file: "Access", sites: probes.map { "\($0.line):\($0.receiver)" })
        XCTAssertEqual(expected.count, probes.count, "javac sites: \(expected.map(\.receiver))")
        // A missing site used to walk off this array and abort the process before the assertion printed.
        guard expected.count == probes.count else { return }
        for (probe, javacSite) in zip(probes, expected) {
            var marked = source.replacingOccurrences(of: "object.€hashCode()", with: "object.hashCode()")
            marked = marked.replacingOccurrences(of: probe.caret.replacingOccurrences(of: "€", with: ""), with: probe.caret)
            let site = try await engine(marked, file: "Access")
            assertSameMembers(site.members, javacSite.members, probe.receiver)
        }
        let selfSite = expected[4]
        XCTAssertTrue(selfSite.members.contains("clone"))
        XCTAssertTrue(selfSite.members.contains("finalize"))
        XCTAssertFalse(expected[0].members.contains("clone"))
        XCTAssertFalse(expected[1].members.contains("finalize"))
        XCTAssertFalse(expected[2].members.contains("clone"))
        XCTAssertFalse(expected[6].members.contains("clone"))
        XCTAssertTrue(expected[3].members.contains("clone"))
        XCTAssertFalse(expected[3].members.contains("finalize"))
    }

    /// A subclass in another package can use a protected member through its own type, and not through
    /// the declaring class. The static member is available through either receiver.
    func testProtectedMemberAcrossPackagesMatchesJavac() async throws {
        let base = """
        package com.acme.other;

        public class Base {
            protected int secret;
            protected void ping() {}
            public void pub() {}
            protected static int STAT;
        }
        """
        let sub = """
        package com.acme.cases;

        import com.acme.other.Base;

        class Sub extends Base {
            void run(Base base, Sub sub) {
                int a = base.€secret;
                int b = sub.secret;
                int c = base.STAT;
            }
        }
        """
        let also = [(path: "com/acme/other/Base.java", text: base)]
        let baseURL = fidelityRoot.appendingPathComponent("com/acme/other/Base.java")
        try FileManager.default.createDirectory(at: baseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try base.write(to: baseURL, atomically: true, encoding: .utf8)
        let expected = try javac(sub, file: "Sub", sites: ["7:base", "8:sub"], extraSourcepath: fidelityRoot)
        XCTAssertEqual(expected.count, 2, "javac sites: \(expected.map(\.receiver))")
        let baseMembers = try await engine(sub, file: "Sub", also: also).members
        let subMarked = sub.replacingOccurrences(of: "base.€secret", with: "base.secret")
            .replacingOccurrences(of: "sub.secret", with: "sub.€secret")
        let subMembers = try await engine(subMarked, file: "Sub", also: also).members
        assertSameMembers(baseMembers, expected[0].members, "base")
        assertSameMembers(subMembers, expected[1].members, "sub")
        XCTAssertFalse(expected[0].members.contains("secret"))
        XCTAssertFalse(expected[0].members.contains("ping"))
        XCTAssertTrue(expected[0].members.contains("pub"))
        XCTAssertTrue(expected[0].members.contains("STAT"))
        XCTAssertTrue(expected[1].members.contains("secret"))
        XCTAssertTrue(expected[1].members.contains("ping"))
        XCTAssertTrue(expected[1].members.contains("STAT"))
    }

    /// The commons-collections shape: `Holder` implements an interface, and an ancestor does too,
    /// so the interface's public-only `Object` visit is processed before the class chain queues
    /// `Object`. `clone` and `finalize` stay on the class receiver and stay off every other one.
    func testInterfaceBeforeSuperclassKeepsProtectedObjectMembers() async throws {
        let source = """
        package com.acme.cases;

        import java.util.List;

        interface Marker {}
        class Base {}
        class Mid extends Base implements Marker {}
        class Holder extends Mid implements java.io.Serializable {
            void run(Holder self, Object object, String text, List<?> list, String[] names, Sibling other) {
                self.hashCode();
                object.hashCode();
                text.hashCode();
                list.hashCode();
                int unused = names.length;
                other.hashCode();
            }
        }
        class Sibling {}
        """
        let probes = ["self", "object", "text", "list", "names", "other"]
        let lines = probes.map { lineNumber(of: "\($0).", in: source) }
        let expected = try javac(source, file: "Holder", sites: zip(lines, probes).map { "\($0):\($1)" })
        XCTAssertEqual(expected.count, probes.count, "javac sites: \(expected.map(\.receiver))")
        guard expected.count == probes.count else { return }
        for (probe, javacSite) in zip(probes, expected) {
            let range = try XCTUnwrap(source.range(of: "\(probe)."))
            let marked = source.replacingCharacters(in: range, with: "\(probe).€")
            let site = try await engine(marked, file: "Holder")
            assertSameMembers(site.members, javacSite.members, probe)
        }
        XCTAssertTrue(expected[0].members.contains("clone"))
        XCTAssertTrue(expected[0].members.contains("finalize"))
        for index in [1, 2, 3, 5] {
            XCTAssertFalse(expected[index].members.contains("clone"), probes[index])
            XCTAssertFalse(expected[index].members.contains("finalize"), probes[index])
        }
        XCTAssertTrue(expected[4].members.contains("clone"), "an array's public clone stays")
        XCTAssertFalse(expected[4].members.contains("finalize"))
        XCTAssertFalse(expected[3].members.contains("of"), "a static interface method is not an instance member")
    }

    /// `Outer.super` is the superclass of the named enclosing class, not of the innermost one.
    /// An override on that superclass wins. A direct superinterface is a different form.
    func testQualifiedSuperMatchesJavac() async throws {
        let source = """
        package com.acme.cases;

        class Base {
            protected void action() {}
            public void pub() {}
        }
        class Mid extends Base {
            @Override protected void action() {}
        }
        class Outer extends Mid {
            class Inner {
                void run() { Outer.super.action(); } // inner
            }
            class Middle {
                class Deep {
                    void run() { Outer.super.action(); Middle.super.pub(); } // deep
                }
            }
            static class Nested {
                void run() { Outer.super.action(); } // nested
            }
            void instance() { super.action(); } // instance
            void own() { Outer.super.action(); } // own
        }
        interface Speak {
            default void say() {}
            static void shout() {}
        }
        class Talker implements Speak {
            static class Inner implements Speak {
                void run() { Speak.super.say(); } // talker-inner
                static void stat() { Speak.super.say(); } // talker-static
            }
            void run() { Speak.super.say(); } // talker
        }
        interface Indirect extends Speak {}
        class OnlyIndirect implements Indirect {
            void run() { Indirect.super.say(); Speak.super.say(); } // only-indirect
        }
        class Sibling {
            void run() { Outer.super.action(); String.super.action(); } // sibling
        }
        """
        // `type` nil means javac attributes no type (the qualifier is not a legal TypeName).
        // A static nested class still attributes `Outer.super` and reports the error separately.
        let sites: [(snippet: String, receiver: String, type: String?, actionOwner: String?)] = [
            ("Outer.super.action(); } // inner", "Outer.super", "com.acme.cases.Mid", "com.acme.cases.Mid"),
            ("Outer.super.action(); Middle.super.pub();", "Outer.super", "com.acme.cases.Mid", "com.acme.cases.Mid"),
            ("Middle.super.pub()", "Middle.super", "java.lang.Object", nil),
            ("Outer.super.action(); } // nested", "Outer.super", "com.acme.cases.Mid", "com.acme.cases.Mid"),
            ("super.action(); } // instance", "super", "com.acme.cases.Mid", "com.acme.cases.Mid"),
            // javac attributes `Outer.super` inside `Outer` as `Mid` and compiles it.
            ("Outer.super.action(); } // own", "Outer.super", "com.acme.cases.Mid", "com.acme.cases.Mid"),
            ("Speak.super.say(); } // talker-inner", "Speak.super", "com.acme.cases.Speak", nil),
            ("Speak.super.say(); } // talker-static", "Speak.super", nil, nil),
            ("Speak.super.say(); } // talker", "Speak.super", "com.acme.cases.Speak", nil),
            ("Indirect.super.say()", "Indirect.super", "com.acme.cases.Indirect", nil),
            ("Speak.super.say(); } // only-indirect", "Speak.super", nil, nil),
            ("Outer.super.action(); String.super.action();", "Outer.super", nil, nil),
            ("String.super.action()", "String.super", nil, nil),
        ]
        for site in sites {
            let line = lineNumber(of: site.snippet, in: source)
            let javacSites = try javac(source, file: "Qualified", sites: ["\(line):\(site.receiver)"])
            let javacSite = try XCTUnwrap(javacSites.first, "\(site.snippet) line \(line)")
            if site.type == nil {
                XCTAssertEqual(javacSite.type, "<none>", site.snippet)
            } else {
                XCTAssertEqual(javacSite.binary, site.type, site.snippet)
                if let owner = site.actionOwner {
                    XCTAssertTrue(javacSite.signatures["action"]?.contains { $0.contains("@\(owner)") } == true, site.snippet)
                }
            }
            let caret = site.snippet.replacingOccurrences(of: "\(site.receiver).", with: "\(site.receiver).€")
            let marked = source.replacingOccurrences(of: site.snippet, with: caret)
            let engineSite = try await engine(marked, file: "Qualified")
            if site.type == nil {
                XCTAssertNil(engineSite.type, site.snippet)
                XCTAssertTrue(engineSite.members.isEmpty, site.snippet)
                XCTAssertTrue(javacSite.members.isEmpty, site.snippet)
            } else {
                XCTAssertEqual(qualifiedName(engineSite.type), site.type, site.snippet)
                assertSameMembers(engineSite.members, javacSite.members, site.snippet)
            }
        }
    }

    /// A protected member of a superclass in another package is visible through `Outer.super`.
    func testQualifiedSuperProtectedMemberAcrossPackages() async throws {
        let base = """
        package com.acme.other;

        public class Base {
            protected void action() {}
        }
        """
        let sub = """
        package com.acme.cases;

        class Outer extends com.acme.other.Base {
            class Inner {
                void run() { Outer.super.action(); }
            }
        }
        """
        let also = [(path: "com/acme/other/Base.java", text: base)]
        let baseURL = fidelityRoot.appendingPathComponent("com/acme/other/Base.java")
        try FileManager.default.createDirectory(at: baseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try base.write(to: baseURL, atomically: true, encoding: .utf8)
        let line = lineNumber(of: "Outer.super.action()", in: sub)
        let expected = try javac(sub, file: "Outer", sites: ["\(line):Outer.super"], extraSourcepath: fidelityRoot)
        let javacSite = try XCTUnwrap(expected.first)
        XCTAssertEqual(javacSite.binary, "com.acme.other.Base")
        XCTAssertTrue(javacSite.members.contains("action"))
        XCTAssertTrue(javacSite.signatures["action"]?.contains { $0.contains("@com.acme.other.Base") } == true)
        let marked = sub.replacingOccurrences(of: "Outer.super.", with: "Outer.super.€")
        let engineSite = try await engine(marked, file: "Outer", also: also)
        XCTAssertEqual(qualifiedName(engineSite.type), "com.acme.other.Base")
        assertSameMembers(engineSite.members, javacSite.members, "Outer.super")
    }

    /// A local named `Outer` does not hide the type in `Outer.super`. A missing name and a package
    /// select are not member receivers.
    func testQualifiedSuperShadowPackageAndMissingName() async throws {
        let shadow = """
        package com.acme.cases;

        class Base {
            protected void action() {}
        }
        class Outer extends Base {
            class Inner {
                void run() {
                    int Outer = 1;
                    Outer.super.action();
                }
            }
        }
        """
        let line = lineNumber(of: "Outer.super.action()", in: shadow)
        let expected = try XCTUnwrap(try javac(shadow, file: "Shadow", sites: ["\(line):Outer.super"]).first)
        XCTAssertEqual(expected.binary, "com.acme.cases.Base")
        let engineSite = try await engine(shadow.replacingOccurrences(of: "Outer.super.", with: "Outer.super.€"), file: "Shadow")
        XCTAssertEqual(qualifiedName(engineSite.type), "com.acme.cases.Base")
        assertSameMembers(engineSite.members, expected.members, "shadowed Outer.super")

        let other = """
        package com.acme.cases;

        class Other {
            void run() {
                Class<?> c = java.util.List.class;
                Missing.thing();
            }
        }
        """
        let packageLine = lineNumber(of: "java.util.List", in: other)
        let missingLine = lineNumber(of: "Missing.thing()", in: other)
        let packageSite = try XCTUnwrap(try javac(other, file: "Other", sites: ["\(packageLine):java.util"]).first)
        let missingSite = try XCTUnwrap(try javac(other, file: "Other", sites: ["\(missingLine):Missing"]).first)
        XCTAssertEqual(packageSite.type, "<package>")
        XCTAssertTrue(packageSite.members.isEmpty)
        XCTAssertEqual(missingSite.type, "<none>")
        XCTAssertTrue(missingSite.members.isEmpty)
        let packageEngine = try await engine(other.replacingOccurrences(of: "java.util.", with: "java.util.€"), file: "Other")
        XCTAssertNotNil(packageEngine.type, "a package select is a receiver, and it has no class")
        XCTAssertNil(packageEngine.type?.erasedQualifiedName)
        XCTAssertTrue(packageEngine.members.isEmpty)
        let missingEngine = try await engine(other.replacingOccurrences(of: "Missing.", with: "Missing.€"), file: "Other")
        XCTAssertNil(missingEngine.type)
        XCTAssertTrue(missingEngine.members.isEmpty)
    }

    private func lineNumber(of snippet: String, in source: String) -> Int {
        let plain = source.replacingOccurrences(of: "€", with: "")
        let target = snippet.replacingOccurrences(of: "€", with: "")
        guard let range = plain.range(of: target) else { return -1 }
        return plain[..<range.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).count
    }
}
