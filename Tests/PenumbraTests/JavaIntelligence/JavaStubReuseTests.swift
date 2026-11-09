import XCTest
@_spi(Benchmarks) @testable import JavaIntelligence

/// `JavaStubReuse` moves the previous stubs past an edit inside one method body instead of
/// rebuilding them. The reference is the full rebuild on the same incrementally parsed tree:
/// whatever the reuse path returns must equal `JavaSourceStubBuilder.build(tree:)`, ranges included.
final class JavaStubReuseTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/virtual/Sample.java")
    private let parser = JavaSyntaxParser()

    // MARK: - Fixtures

    private static let plain = """
    package com.acme.demo;

    import java.util.List;
    import java.util.Map;
    import static java.lang.Math.max;

    /** A café — naïve 日本語. */
    public class Sample<T extends Comparable<T>> extends Base implements Runnable {
        private static final String GREETING = "héllo 😀";
        private List<String> names = new java.util.ArrayList<>();
        int counter;

        static { System.out.println("init"); }

        public Sample() {
            this.counter = 1;
        }

        /** Runs. */
        @Override
        public void run() {
            int local = counter + 1;
            names.add("x" + local);
            Runnable r = new Runnable() { public void run() { counter++; } };
            class Local { void m() { counter--; } }
        }

        public String ñame(String ünï, int... rest) throws java.io.IOException {
            return ünï + rest.length + GREETING;
        }

        static <U> U first(List<U> items) { return items.get(0); }

        public static class Nested {
            int depth;
            void deeper() {
                depth++;
            }
            class Inner { void innermost() { } }
        }

        enum Mode { ON, OFF; Mode flip() { return this == ON ? OFF : ON; } }

        abstract void missingBody();
    }

    class Other {
        void last() { int z = 0; }
    }
    """

    private static let shapes = """
    package shapes;

    public interface Shape {
        double PI = 3.14;
        double area();
        default String describe() { return "shape " + area(); }
        static Shape unit() { return () -> 1.0; }
    }

    record Point(int x, int y) {
        Point { if (x < 0) throw new IllegalArgumentException(); }
        int sum() { return x + y; }
    }

    enum Level { LOW, HIGH; boolean isHigh() { return this == HIGH; } }

    @interface Marker { String value() default ""; }
    """

    private static let lombok = """
    package lom;

    import lombok.Builder;
    import lombok.Data;

    @Data
    @Builder
    public class Person {
        private String name;
        private boolean active;
        public String shout() {
            return name.toUpperCase();
        }
    }

    class Tail { void t() { } }
    """

    private static let unterminated = """
    package inc;

    public class Broken {
        int a;
        void one() {
            int x = ;
            foo(
        }
        void two() { a++; }
        void three() {
            if (a > 0 {
    """

    private static func crlf(_ text: String) -> String { text.replacingOccurrences(of: "\n", with: "\r\n") }

    private static func bigClass(methods: Int) -> String {
        var text = "package big;\nimport java.util.*;\npublic class Big {\n    int field;\n"
        for index in 0..<methods {
            text += "    /** m\(index) */\n    public int method\(index)(int a, String b) {\n        int d = a * 2;\n        return d + \(index);\n    }\n"
        }
        return text + "    static class Tail { void t() { } }\n}\n"
    }

    private var fixtures: [(String, String)] {
        [
            ("plain", Self.plain), ("plain-crlf", Self.crlf(Self.plain)), ("shapes", Self.shapes),
            ("lombok", Self.lombok), ("unterminated", Self.unterminated), ("big", Self.bigClass(methods: 60))
        ]
    }

    // MARK: - Helpers

    private struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private static let chunks = [
        "x", " ", "\n", "\r\n", "foo.", "bar(", ")", "int v = 1;", "é", "日本", "😀", "__penumbra__", "= ;", "// c\n",
        "\"s\"", "if (a) {", "}", "{", "}}", "class L {}", "->", "return;", ";", "/*", "*/", "new Object() { void q() { } }"
    ]

    /// Independent random campaigns per property test; `JAVA_STUB_REUSE_ROUNDS=50` for a deep run.
    private var rounds: Int { Int(ProcessInfo.processInfo.environment["JAVA_STUB_REUSE_ROUNDS"] ?? "") ?? 2 }

    private func parse(_ text: String) throws -> JavaSyntaxTree {
        try XCTUnwrap(parser.parse(text))
    }

    private func fullStubs(_ tree: JavaSyntaxTree) -> JavaSourceFileStubs {
        JavaSourceStubBuilder.build(tree: tree, url: url)
    }

    /// Byte offsets at which a scalar starts (a valid place to cut or insert).
    private func scalarBoundaries(_ bytes: [UInt8], in range: Range<Int>) -> [Int] {
        (range.lowerBound...range.upperBound).filter { $0 == bytes.count || (bytes[$0] & 0xC0) != 0x80 }
    }

    /// Method and constructor body blocks of `tree`, as byte ranges.
    private func bodyRanges(_ tree: JavaSyntaxTree) -> [Range<Int>] {
        var result: [Range<Int>] = []
        func walk(_ node: SyntaxNode) {
            if node.type == "method_declaration" || node.type == "constructor_declaration",
               let body = node.child(byFieldName: "body"), body.type == "block" {
                result.append(body.byteRange)
            }
            for child in node.namedChildren { walk(child) }
        }
        walk(tree.rootNode)
        return result
    }

    private func apply(_ bytes: [UInt8], replacing range: Range<Int>, with insertion: String) -> [UInt8] {
        var copy = bytes
        copy.replaceSubrange(range, with: Array(insertion.utf8))
        return copy
    }

    private struct State {
        var tree: JavaSyntaxTree
        var stubs: JavaSourceFileStubs
        var text: String
    }

    /// Reparse from `state` to `newText`; assert the stubs equal a rebuild of the new tree. Returns the new state.
    @discardableResult
    private func check(_ state: State, to newText: String, context: String, file: StaticString = #filePath, line: UInt = #line) throws -> (state: State, reused: Bool) {
        let result = try XCTUnwrap(
            JavaStubReuse.reparse(previous: (state.tree, state.stubs), to: newText, parser: parser, url: url),
            "incremental parse failed: \(context)", file: file, line: line
        )
        let expected = fullStubs(result.tree)
        XCTAssertEqual(result.stubs.packageName, expected.packageName, "package: \(context)", file: file, line: line)
        XCTAssertEqual(result.stubs.imports, expected.imports, "imports: \(context)", file: file, line: line)
        XCTAssertEqual(result.stubs.classes, expected.classes, "reused=\(result.reusedStubs): \(context)", file: file, line: line)
        // When the text parses cleanly from scratch, the incremental tree must give the same stubs too.
        if let fresh = parser.parse(newText), !fresh.rootNode.hasError {
            XCTAssertEqual(result.stubs.classes, fullStubs(fresh).classes, "vs independent parse: \(context)", file: file, line: line)
        }
        return (State(tree: result.tree, stubs: result.stubs, text: newText), result.reusedStubs)
    }

    private func startState(_ text: String) throws -> State {
        let tree = try parse(text)
        return State(tree: tree, stubs: fullStubs(tree), text: text)
    }

    // MARK: - Property tests

    /// Edits inside method bodies, chained so the stubs are moved several times in a row.
    func testRandomBodyEditsEqualAFullRebuild() throws {
        var reused = 0
        var total = 0
        for round in 0..<rounds {
        var generator = Generator(state: 0xB0D1 &+ UInt64(round) &* 7919)
        for (name, source) in fixtures {
            var state = try startState(source)
            for step in 0..<60 {
                // Random edits pile up syntax errors, and a file with errors elsewhere rightly
                // rebuilds. Starting over every few steps keeps this measuring reuse.
                if step % 4 == 0 { state = try startState(source) }
                var bytes = Array(state.text.utf8)
                let bodies = bodyRanges(state.tree)
                guard let body = bodies.randomElement(using: &generator) else { break }
                // One to three edits land before the next request; the diff merges them.
                for _ in 0..<Int.random(in: 1...3, using: &generator) {
                    let inside = (body.lowerBound + 1)..<(min(body.upperBound, bytes.count) - 1)
                    guard inside.lowerBound < inside.upperBound else { break }
                    let places = scalarBoundaries(bytes, in: inside)
                    guard let start = places.randomElement(using: &generator) else { break }
                    let end = places.filter { $0 >= start && $0 - start <= 6 }.randomElement(using: &generator) ?? start
                    let insertion = Bool.random(using: &generator) ? Self.chunks.randomElement(using: &generator)! : ""
                    bytes = apply(bytes, replacing: start..<end, with: insertion)
                }
                let text = String(decoding: bytes, as: UTF8.self)
                guard Array(text.utf8) == bytes else { continue }  // never produce invalid UTF-8
                let outcome = try check(state, to: text, context: "\(name) round \(round) step \(step)")
                state = outcome.state
                total += 1
                if outcome.reused { reused += 1 }
            }
        }
        }
        print("STUBREUSE body-edit property: reused \(reused) of \(total)")
        // Random edits are mostly nonsense (braces, half comments), so only a floor: enough reuse
        // that the equality checks above were not all against rebuilds.
        XCTAssertGreaterThan(reused, total / 5, "reuse should still apply to a fair share of body edits, or this test proves nothing")
    }

    /// Edits anywhere, braces and broken syntax included: reused or rebuilt, never different.
    func testRandomEditsAnywhereEqualAFullRebuild() throws {
        for round in 0..<rounds {
        var generator = Generator(state: 0xA11 &+ UInt64(round) &* 7919)
        for (name, source) in fixtures {
            var state = try startState(source)
            for step in 0..<80 {
                var bytes = Array(state.text.utf8)
                let places = scalarBoundaries(bytes, in: 0..<bytes.count)
                guard let start = places.randomElement(using: &generator) else { break }
                let end = places.filter { $0 >= start && $0 - start <= 40 }.randomElement(using: &generator) ?? start
                let insertion = Bool.random(using: &generator) ? Self.chunks.randomElement(using: &generator)! : ""
                bytes = apply(bytes, replacing: start..<end, with: insertion)
                let text = String(decoding: bytes, as: UTF8.self)
                guard Array(text.utf8) == bytes else { continue }
                state = try check(state, to: text, context: "\(name) round \(round) step \(step) edit \(start)..<\(end) -> \(insertion.debugDescription)").state
            }
        }
        }
    }

    // MARK: - Targeted cases

    private func edit(_ text: String, replacing target: String, with replacement: String, occurrence: Int = 0) -> String {
        var searchRange = text.startIndex..<text.endIndex
        var found: Range<String.Index>?
        for _ in 0...occurrence {
            guard let range = text.range(of: target, range: searchRange) else { XCTFail("no \(target)"); return text }
            found = range
            searchRange = range.upperBound..<text.endIndex
        }
        return text.replacingCharacters(in: found!, with: replacement)
    }

    func testInsertingRightAfterTheOpeningBraceAndBeforeTheClosingBraceIsReused() throws {
        let state = try startState(Self.plain)
        let afterBrace = edit(Self.plain, replacing: "void m() { counter--; }", with: "void m() {X counter--; }")
        XCTAssertTrue(try check(state, to: afterBrace, context: "after {").reused)
        let beforeBrace = edit(Self.plain, replacing: "int z = 0; }", with: "int z = 0; X}")
        XCTAssertTrue(try check(state, to: beforeBrace, context: "before }").reused)
    }

    func testClassesAfterTheEditMoveByTheEditLengthInBytesNotCharacters() throws {
        // `ñame`, `ünï`, `日本語` and the emoji sit before and after the edit: UTF-16 or scalar
        // counts would put every later range in the wrong place.
        let state = try startState(Self.plain)
        let edited = edit(Self.plain, replacing: "int local = counter + 1;", with: "int local = counter + 1; String s = \"日本語😀é\";")
        let outcome = try check(state, to: edited, context: "multibyte insertion")
        XCTAssertTrue(outcome.reused)
        let before = state.stubs.classes.first { $0.simpleName == "Other" }
        let after = outcome.state.stubs.classes.first { $0.simpleName == "Other" }
        guard case .source(_, let beforeRange)? = before?.origin, case .source(_, let afterRange)? = after?.origin else {
            return XCTFail("Other has a source origin")
        }
        XCTAssertEqual(afterRange.lowerBound - beforeRange.lowerBound, " String s = \"日本語😀é\";".utf8.count)
    }

    func testLombokBuilderRangeThatSpansTheEditGrows() throws {
        let state = try startState(Self.lombok)
        let edited = edit(Self.lombok, replacing: "return name.toUpperCase();", with: "return name.toUpperCase() + \"é\";")
        XCTAssertTrue(try check(state, to: edited, context: "lombok body edit").reused)
    }

    func testStructuralEditsFallBackToARebuild() throws {
        let state = try startState(Self.plain)
        let cases: [(String, String)] = [
            ("rename a method", edit(Self.plain, replacing: "static <U> U first", with: "static <U> U firstOf")),
            ("add a method", edit(Self.plain, replacing: "void deeper() {", with: "void extra() { }\n        void deeper() {")),
            ("delete the brace", edit(Self.plain, replacing: "int z = 0; }", with: "int z = 0; ")),
            ("close the body early", edit(Self.plain, replacing: "int z = 0;", with: "int z = 0; }")),
            ("open an unbalanced brace", edit(Self.plain, replacing: "int z = 0; }", with: "int z = 0; { }")),
            ("change a parameter", edit(Self.plain, replacing: "String ünï", with: "int ünï")),
            ("edit an import", edit(Self.plain, replacing: "java.util.Map", with: "java.util.Set")),
            ("edit the package", edit(Self.plain, replacing: "com.acme.demo", with: "com.acme")),
            ("edit a field initializer", edit(Self.plain, replacing: "new java.util.ArrayList<>()", with: "null")),
            ("edit the static initializer", edit(Self.plain, replacing: "\"init\"", with: "\"in\"")),
            ("edit a javadoc", edit(Self.plain, replacing: "/** Runs. */", with: "/** Runs fast. */"))
        ]
        for (name, text) in cases {
            let outcome = try check(state, to: text, context: name)
            XCTAssertFalse(outcome.reused, "\(name) must not reuse stubs")
        }
    }

    func testAnEditSpanningTwoMethodsRebuilds() throws {
        let state = try startState(Self.plain)
        // One diff covering the end of one body and the start of the next.
        let edited = edit(Self.plain, replacing: "names.add(\"x\" + local);", with: "names.add(\"y\" + local);")
            .replacingOccurrences(of: "return ünï + rest.length", with: "return ünï + rest.length + 1")
        XCTAssertFalse(try check(state, to: edited, context: "two methods").reused)
    }

    func testIncompleteCodeInsideABody() throws {
        let state = try startState(Self.plain)
        for broken in ["int x = ;", "foo(", "if (a", "names.", "a = b +", "new Foo(1, "] {
            let edited = edit(Self.plain, replacing: "int local = counter + 1;", with: "int local = counter + 1; \(broken)")
            try check(state, to: edited, context: "incomplete \(broken)")
        }
    }

    func testEveryKindOfMethodOwner() throws {
        let shapes = try startState(Self.shapes)
        for (target, replacement) in [
            ("return \"shape \" + area();", "return \"shape \" + area() + 1;"),
            ("if (x < 0) throw", "if (x < 1) throw"),
            ("return x + y;", "return x + y + 1;"),
            ("return this == HIGH;", "return this != HIGH;")
        ] {
            try check(shapes, to: edit(Self.shapes, replacing: target, with: replacement), context: target)
        }
    }

    /// What the editor does: one character at a time into a method of a file that is otherwise
    /// clean. Every keystroke after the first must reuse the stubs, and the ranges of the classes
    /// after the edit must keep moving with it.
    func testTypingAStatementCharacterByCharacterReusesTheStubs() throws {
        for (name, source) in [("plain", Self.plain), ("plain-crlf", Self.crlf(Self.plain)), ("big", Self.bigClass(methods: 200))] {
            var state = try startState(source)
            let anchor = name == "big" ? "int d = a * 2;" : "int local = counter + 1;"
            var typed = ""
            var reused = 0
            let statement = Array(" names.add(\"é日本😀\" + x); foo.bar(1, 2);")
            for character in statement {
                typed.append(character)
                let text = edit(source, replacing: anchor, with: anchor + typed)
                let outcome = try check(state, to: text, context: "\(name) typing \(typed.debugDescription)")
                state = outcome.state
                if outcome.reused { reused += 1 } else { print("STUBREUSE typing \(name) fell back at \(typed.debugDescription)") }
            }
            print("STUBREUSE typing \(name): reused \(reused) of \(statement.count)")
            // While a string literal is open and unterminated (`names.add("é`) the file has an error
            // outside the body, and the stubs are rebuilt: safe, and brief since the editor pairs quotes.
            // Where a later line happens to close the literal (the `plain` fixtures), nothing falls back.
            let floor = name == "big" ? statement.count * 4 / 5 : statement.count
            XCTAssertGreaterThanOrEqual(reused, floor, "\(name): typing inside a clean file should reuse the stubs")
        }
    }

    /// Through the provider the editor uses: typing into a clean file reuses the stubs, and what
    /// `parse` hands back is what a rebuild gives. Reuse is counted, so a provider that quietly
    /// stopped calling it would fail here.
    func testProviderReusesStubsWhileTyping() async throws {
        let provider = JavaCompletionProvider(index: JavaIndex())
        let anchor = "int local = counter + 1;"
        _ = await provider.parse(Self.plain, url: url)
        JavaStubReuseStatistics.reset()
        var typed = ""
        let keystrokes = Array(" names.add(x); foo.bar(1);")
        for character in keystrokes {
            typed.append(character)
            let text = edit(Self.plain, replacing: anchor, with: anchor + typed)
            let parsed = await provider.parse(text, url: url)
            let result = try XCTUnwrap(parsed)
            XCTAssertEqual(result.stubs.classes, fullStubs(result.tree).classes, "after \(typed.debugDescription)")
        }
        let counts = JavaStubReuseStatistics.counts
        XCTAssertEqual(counts.reused, keystrokes.count)
        XCTAssertEqual(counts.rebuilt, 0)
    }

    /// A parse is only good for the bytes it was made from. `String ==` calls a precomposed `é` and `e`
    /// followed by a combining accent equal, so comparing with it would hand back the first text's tree
    /// (whose byte offsets are off by one from there on) for the second text.
    func testTheParseAlwaysMatchesTheBytesOfTheTextAskedFor() async throws {
        let provider = JavaCompletionProvider(index: JavaIndex())
        let precomposed = "class A { int \u{E9}; void m() { } }"
        let decomposed = "class A { int e\u{301}; void m() { } }"
        XCTAssertEqual(precomposed, decomposed, "precondition: String == treats these as the same text")
        XCTAssertNotEqual(Array(precomposed.utf8), Array(decomposed.utf8))
        for text in [precomposed, decomposed, precomposed, decomposed, decomposed] {
            let parsed = await provider.parse(text, url: url)
            XCTAssertEqual(try XCTUnwrap(parsed).tree.sourceBytes, Array(text.utf8), "tree for \(text.debugDescription)")
        }
        // The same bytes twice is the same parse, not a new one.
        let first = await provider.parse(precomposed, url: url)
        let second = await provider.parse(precomposed, url: url)
        XCTAssertTrue(try XCTUnwrap(first).tree === (try XCTUnwrap(second)).tree)
    }

    /// Found by a deep random campaign (`JAVA_STUB_REUSE_ROUNDS=40`, plain fixture, round 1, step 34):
    /// the file already had syntax errors (an enum constant list missing its `;`), and editing an
    /// unrelated method body made tree-sitter's error recovery read that enum differently, so the
    /// reused stubs listed a field `OFFMode` where a rebuild found `flip`. Stubs are reused only
    /// when everything around the edited body parses without errors.
    func testErrorRecoveryElsewhereInTheFileIsNotReused() throws {
        let before = "package com.acme.demo;\n\nimport java.util.List;\nimport java.util.Map;\nimport static java.lang.Math.max;\n\n/** A caf\u{E9} \u{2014} na\u{EF}ve \u{65E5}\u{672C}\u{8A9E}. */\npublic class Sample<T extends Comparable<T>> extends Base implements Runnable {\n    private static final String GREETING = \"h\u{E9}llo \u{1F600}\";\n    private List<String> names = new java.util.ArrayList<>();\n    int counter;\n\n    static { System.out.println(\"init\"); }\n\n    public Sample() {\n        this.counter = 1;\n    }\n\n    /** Runs. */\n    @Override\n    public void run() {\n        int local = counter + 1;\n        names.add(\"x\" + local);\n        Runnable r = new Runnabreturn;) { publ\n void run() {new Object() { void)() { } }ur++;new Obj\u{E9}{ void q() {}} ;} }} };\n        class Local { void m() {}c\n   }\n\n    public String \u{F1}ame(String \u{FC}n\u{EF}, int... rest) throws java.io.IOException {\n      r*/\u{FC}.len EEfoo.INGc L= ; new Object() {int v = 1;d q() {}\"s\"\u{1F600} ->}\n\n    static <U> U first(List<U> items) { return iteme ); }\n\n    public static class Nested {\n        int depth;\n        void deeper() {\n         pt       }\n\nif (a) {        class-{ { void nnermo } }\n    }\n\n    enum Mode { ON, OFFMode flip() { return this == ON ? OFF : ON; } }\n\n    abstract id missingBody();\n}\n\nclass Other {\n    void last() { int z = 0bar(}\n}"
        let after = "package com.acme.demo;\n\nimport java.util.List;\nimport java.util.Map;\nimport static java.lang.Math.max;\n\n/** A caf\u{E9} \u{2014} na\u{EF}ve \u{65E5}\u{672C}\u{8A9E}. */\npublic class Sample<T extends Comparable<T>> extends Base implements Runnable {\n    private static final String GREETING = \"h\u{E9}llo \u{1F600}\";\n    private List<String> names = new java.util.ArrayList<>();\n    int counter;\n\n    static { System.out.println(\"init\"); }\n\n    public Sample() {\n        this.counter = 1;\n    }\n\n    /** Runs. */\n    @Override\n    public void run() {\n        int local = counter + 1;\n        names.add(\"x\" + local);\n        Runnable r = new Runnabreturn;) { publ\n void run() {new Object() { void)() { } }ur++;new Obj\u{E9}{ void q() {}} ;} }} };\n        class Local { void m() {}c\n   }\n\n    public String \u{F1}ame(String \u{FC}n\u{EF}, int... rest) throws java.io.IOException {\n      r*/\u{FC}.len EEfoo.INGc L= ; new Object() {int v = 1;d q() {}\"s\"\u{1F600} ->}\n\n    static <U> U first(List<U> items) { return iteme ); }\n\n    public static class Nested {\n        int depth;\n        void deeper() {\n         ->    }\n\nif (a) {        class-{ { void nnermo } }\n    }\n\n    enum Mode { ON, OFFMode flip() { return this == ON ? OFF : ON; } }\n\n    abstract id missingBody();\n}\n\nclass Other {\n    void last() { int z = 0bar(}\n}"
        let state = try startState(before)
        let outcome = try check(state, to: after, context: "error recovery outside the edited body")
        XCTAssertFalse(outcome.reused)
    }
}
