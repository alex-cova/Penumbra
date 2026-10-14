import EditorIntelligence
import XCTest
@testable import JavaIntelligence

/// The migration rules: each needs a language level that allows the syntax it suggests.
final class JavaLanguageLevelInspectionsTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/proj/T.java")

    private func findings(
        _ rule: JavaInspectionRule, _ source: String, level: Int?, file: StaticString = #filePath, line: UInt = #line
    ) throws -> [JavaInspection] {
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source), file: file, line: line)
        let context = try XCTUnwrap(
            JavaInspectionContext(source: source, tree: tree, url: url, index: JavaIndex(), languageLevel: level),
            "source must parse", file: file, line: line
        )
        return JavaInspectionRunner.run(context: context, enabled: [rule])
    }

    private func count(_ rule: JavaInspectionRule, _ source: String, level: Int? = 21, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        try findings(rule, source, level: level, file: file, line: line).count
    }

    private func fixed(_ rule: JavaInspectionRule, _ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let inspection = try XCTUnwrap(findings(rule, source, level: 21, file: file, line: line).first, "no \(rule.code) finding", file: file, line: line)
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source))
        let action = try XCTUnwrap(
            JavaInspectionRegistry.fixes(for: inspection.asDiagnostic(), tree: tree, source: source).first, "no fix", file: file, line: line
        )
        var text = source as NSString
        for edit in action.edits.sorted(by: { $0.range.start.utf16Offset > $1.range.start.utf16Offset }) {
            let range = NSRange(location: edit.range.start.utf16Offset, length: edit.range.end.utf16Offset - edit.range.start.utf16Offset)
            text = text.replacingCharacters(in: range, with: edit.replacement) as NSString
        }
        return text as String
    }

    private func method(_ body: String, params: String = "") -> String {
        "class T {\n    void f(\(params)) {\n\(body)\n    }\n}\n"
    }

    func testRulesStaySilentWithoutALevelOrBelowTheirVersion() throws {
        let source = method("        boolean b = !o.isPresent();", params: "Optional<String> o")
        XCTAssertEqual(try count(.optionalIsEmpty, source, level: nil), 0)
        XCTAssertEqual(try count(.optionalIsEmpty, source, level: 8), 0)
        XCTAssertEqual(try count(.optionalIsEmpty, source, level: 10), 0)
        XCTAssertEqual(try count(.optionalIsEmpty, source, level: 11), 1)
        XCTAssertEqual(try count(.optionalIsEmpty, source, level: 21), 1)
    }

    func testInstanceOfPattern() throws {
        let source = method("        if (x instanceof Foo) {\n            Foo f = (Foo) x;\n            use(f);\n        }", params: "Object x")
        XCTAssertEqual(try count(.instanceOfPattern, source), 1)
        XCTAssertEqual(try count(.instanceOfPattern, source, level: 11), 0)
        XCTAssertEqual(
            try fixed(.instanceOfPattern, source),
            method("        if (x instanceof Foo f) {\n            use(f);\n        }", params: "Object x")
        )
        // Already a pattern, a different type, a cast of something else, or the cast is not first.
        XCTAssertEqual(try count(.instanceOfPattern, method("        if (x instanceof Foo f) { use(f); }", params: "Object x")), 0)
        XCTAssertEqual(try count(.instanceOfPattern, method("        if (x instanceof Foo) { Bar b = (Bar) x; }", params: "Object x")), 0)
        XCTAssertEqual(try count(.instanceOfPattern, method("        if (x instanceof Foo) { use(x); Foo f = (Foo) x; }", params: "Object x")), 0)
    }

    func testEnhancedSwitch() throws {
        let source = method("        switch (n) {\n            case 1:\n                a();\n                break;\n            case 2:\n            case 3:\n                b();\n                c();\n                break;\n            default:\n                d();\n        }", params: "int n")
        XCTAssertEqual(try count(.enhancedSwitch, source), 1)
        XCTAssertEqual(try count(.enhancedSwitch, source, level: 13), 0)
        XCTAssertEqual(
            try fixed(.enhancedSwitch, source),
            method("        switch (n) {\n            case 1 -> a();\n            case 2, 3 -> {\n                b();\n                c();\n            }\n            default -> d();\n        }", params: "int n")
        )
        // A local declared in one group and used in a later one needs the old shared scope.
        let shared = method("        switch (n) {\n            case 1:\n                int x = 1;\n                break;\n            case 2:\n                x = 2;\n                use(x);\n                break;\n        }", params: "int n")
        XCTAssertEqual(try count(.enhancedSwitch, shared), 0)
        let separate = method("        switch (n) {\n            case 1:\n                int x = 1;\n                use(x);\n                break;\n            case 2:\n                int y = 2;\n                use(y);\n                break;\n        }", params: "int n")
        XCTAssertEqual(try count(.enhancedSwitch, separate), 1)
        // A fall-through, or a break that leaves the switch from inside an `if`, cannot become arrows.
        let falls = method("        switch (n) {\n            case 1:\n                a();\n            case 2:\n                b();\n                break;\n        }", params: "int n")
        XCTAssertEqual(try count(.enhancedSwitch, falls), 0)
        let inner = method("        switch (n) {\n            case 1:\n                if (k) break;\n                a();\n                break;\n            default:\n                b();\n        }", params: "int n, boolean k")
        XCTAssertEqual(try count(.enhancedSwitch, inner), 0)
        let arrows = method("        switch (n) {\n            case 1 -> a();\n            default -> b();\n        }", params: "int n")
        XCTAssertEqual(try count(.enhancedSwitch, arrows), 0)
    }

    func testTextBlock() throws {
        let source = method("        String s = \"line one\\n\" +\n            \"line two\\n\" +\n            \"line three\";")
        XCTAssertEqual(try count(.textBlock, source), 1)
        XCTAssertEqual(try count(.textBlock, source, level: 14), 0)
        XCTAssertEqual(
            try fixed(.textBlock, source),
            method("        String s = \"\"\"\n            line one\n            line two\n            line three\"\"\";")
        )
        let closing = method("        String s = \"a\\n\" + \"b\\n\" + \"c\\n\";")
        XCTAssertEqual(
            try fixed(.textBlock, closing),
            method("        String s = \"\"\"\n            a\n            b\n            c\n            \"\"\";")
        )
        // A variable inside, too few line breaks, and trailing whitespace are left alone.
        XCTAssertEqual(try count(.textBlock, method("        String s = \"a\\n\" + x + \"b\\n\";")), 0)
        XCTAssertEqual(try count(.textBlock, method("        String s = \"a\" + \"b\" + \"c\";")), 0)
        XCTAssertEqual(try count(.textBlock, method("        String s = \"a \\n\" + \"b\\n\" + \"c\";")), 0)
    }

    func testLocalVariableTypeCanBeVar() throws {
        XCTAssertEqual(try count(.localVariableTypeCanBeVar, method("        Foo f = new Foo(1);")), 1)
        XCTAssertEqual(try count(.localVariableTypeCanBeVar, method("        String s = \"x\";")), 1)
        // Primitives with a literal read better spelled out.
        XCTAssertEqual(try count(.localVariableTypeCanBeVar, method("        int i = 0;\n        long l = 1L;\n        boolean b = true;")), 0)
        XCTAssertEqual(try count(.localVariableTypeCanBeVar, method("        Foo f = (Foo) o;", params: "Object o")), 1)
        // The initializer's type differs from the declared one.
        XCTAssertEqual(try count(.localVariableTypeCanBeVar, method("        List<String> l = new ArrayList<>();")), 0)
        XCTAssertEqual(try count(.localVariableTypeCanBeVar, method("        Object o = new Foo();")), 0)
        XCTAssertEqual(try count(.localVariableTypeCanBeVar, method("        long l = 1;")), 0)
        XCTAssertEqual(try count(.localVariableTypeCanBeVar, method("        var f = new Foo();")), 0)
        XCTAssertEqual(try count(.localVariableTypeCanBeVar, method("        Foo f = new Foo();"), level: 9), 0)
        XCTAssertEqual(try fixed(.localVariableTypeCanBeVar, method("        Foo f = new Foo(1);")), method("        var f = new Foo(1);"))
    }

    func testCollectionsEmptyFactory() throws {
        XCTAssertEqual(try count(.collectionsEmptyFactory, method("        var l = Collections.emptyList();")), 1)
        XCTAssertEqual(try count(.collectionsEmptyFactory, method("        var s = Collections.emptySet();")), 1)
        XCTAssertEqual(try count(.collectionsEmptyFactory, method("        var l = Collections.<String>emptyList();")), 0)
        XCTAssertEqual(try count(.collectionsEmptyFactory, method("        var l = Collections.emptyList();"), level: 8), 0)
        XCTAssertEqual(try fixed(.collectionsEmptyFactory, method("        var m = Collections.emptyMap();")), method("        var m = Map.of();"))
    }

    func testStringIsBlank() throws {
        XCTAssertEqual(try count(.stringIsBlank, method("        boolean b = s.trim().isEmpty();", params: "String s")), 1)
        XCTAssertEqual(try count(.stringIsBlank, method("        boolean b = s.strip().isEmpty();", params: "String s")), 1)
        XCTAssertEqual(try count(.stringIsBlank, method("        boolean b = s.isEmpty();", params: "String s")), 0)
        XCTAssertEqual(try count(.stringIsBlank, method("        boolean b = o.trim().isEmpty();", params: "Object o")), 0)
        XCTAssertEqual(
            try fixed(.stringIsBlank, method("        boolean b = s.trim().isEmpty();", params: "String s")),
            method("        boolean b = s.isBlank();", params: "String s")
        )
    }

    func testOptionalIsEmpty() throws {
        XCTAssertEqual(
            try fixed(.optionalIsEmpty, method("        boolean b = !o.isPresent();", params: "Optional<String> o")),
            method("        boolean b = o.isEmpty();", params: "Optional<String> o")
        )
        XCTAssertEqual(try count(.optionalIsEmpty, method("        boolean b = o.isPresent();", params: "Optional<String> o")), 0)
        XCTAssertEqual(try count(.optionalIsEmpty, method("        boolean b = !o.isPresent();", params: "Foo o")), 0)
    }

    func testStreamToList() throws {
        let source = method("        var l = items.stream().map(x -> x).collect(Collectors.toList());", params: "java.util.List<String> items")
        XCTAssertEqual(try count(.streamToList, source), 1)
        XCTAssertEqual(try count(.streamToList, source, level: 15), 0)
        XCTAssertEqual(
            try fixed(.streamToList, source),
            method("        var l = items.stream().map(x -> x).toList();", params: "java.util.List<String> items")
        )
        XCTAssertEqual(try count(.streamToList, method("        var s = items.stream().collect(Collectors.toSet());", params: "java.util.List<String> items")), 0)
    }

    func testSequencedCollectionAccess() throws {
        XCTAssertEqual(try count(.sequencedCollectionAccess, method("        String a = list.get(0);", params: "java.util.List<String> list")), 1)
        XCTAssertEqual(try count(.sequencedCollectionAccess, method("        String a = list.get(list.size() - 1);", params: "java.util.List<String> list")), 1)
        XCTAssertEqual(try count(.sequencedCollectionAccess, method("        String a = list.get(1);", params: "java.util.List<String> list")), 0)
        XCTAssertEqual(try count(.sequencedCollectionAccess, method("        String a = list.get(other.size() - 1);", params: "java.util.List<String> list, java.util.List<String> other")), 0)
        XCTAssertEqual(try count(.sequencedCollectionAccess, method("        String a = map.get(0);", params: "java.util.Map<Integer, String> map")), 0)
        XCTAssertEqual(try count(.sequencedCollectionAccess, method("        String a = list.get(0);", params: "java.util.List<String> list"), level: 17), 0)
        XCTAssertEqual(
            try fixed(.sequencedCollectionAccess, method("        String a = list.get(list.size() - 1);", params: "java.util.List<String> list")),
            method("        String a = list.getLast();", params: "java.util.List<String> list")
        )
    }

    func testStringFormatted() throws {
        XCTAssertEqual(
            try fixed(.stringFormatted, method("        String s = String.format(\"%d of %d\", a, b);", params: "int a, int b")),
            method("        String s = \"%d of %d\".formatted(a, b);", params: "int a, int b")
        )
        XCTAssertEqual(try count(.stringFormatted, method("        String s = String.format(pattern, a);", params: "String pattern, int a")), 0)
        XCTAssertEqual(try count(.stringFormatted, method("        String s = String.format(\"%d\", a);", params: "int a"), level: 11), 0)
    }

    func testMapGetOrDefault() throws {
        XCTAssertEqual(
            try fixed(.mapGetOrDefault, method("        String v = m.containsKey(k) ? m.get(k) : \"none\";", params: "java.util.Map<String, String> m, String k")),
            method("        String v = m.getOrDefault(k, \"none\");", params: "java.util.Map<String, String> m, String k")
        )
        XCTAssertEqual(try count(.mapGetOrDefault, method("        String v = m.containsKey(k) ? m.get(k) : null;", params: "java.util.Map<String, String> m, String k")), 0)
        // The default is evaluated eagerly by getOrDefault, so a call stays a conditional.
        XCTAssertEqual(try count(.mapGetOrDefault, method("        String v = m.containsKey(k) ? m.get(k) : compute();", params: "java.util.Map<String, String> m, String k")), 0)
        XCTAssertEqual(try count(.mapGetOrDefault, method("        String v = m.containsKey(k) ? m.get(k) : other;", params: "java.util.Map<String, String> m, String k, String other")), 1)
        XCTAssertEqual(try count(.mapGetOrDefault, method("        String v = m.containsKey(k) ? m.get(j) : \"x\";", params: "java.util.Map<String, String> m, String k, String j")), 0)
        XCTAssertEqual(try count(.mapGetOrDefault, method("        String v = a.containsKey(k) ? b.get(k) : \"x\";", params: "java.util.Map<String, String> a, java.util.Map<String, String> b, String k")), 0)
    }

    func testRegistrationAndDefaults() {
        let added: [JavaInspectionRule] = [
            .instanceOfPattern, .enhancedSwitch, .textBlock, .localVariableTypeCanBeVar, .collectionsEmptyFactory, .stringIsBlank,
            .optionalIsEmpty, .streamToList, .sequencedCollectionAccess, .stringFormatted, .mapGetOrDefault,
        ]
        for rule in added {
            XCTAssertNotNil(JavaInspectionRegistry.inspection(for: rule), "\(rule.code) is not registered")
            XCTAssertTrue(rule.hasQuickFix, "\(rule.code) should offer a fix")
            XCTAssertEqual(rule.group, .migration)
            XCTAssertEqual(
                rule.isEnabledByDefault, ![.localVariableTypeCanBeVar, .streamToList, .collectionsEmptyFactory].contains(rule),
                "\(rule.code) default state"
            )
        }
    }

    func testModelFindsTheLanguageLevelOfAFile() {
        let main = JavaGradleProjectModel.SourceSet(
            name: "main", sourceDirs: [URL(fileURLWithPath: "/p/app/src/main/java")], outputDirs: [], compileClasspathJars: [], runtimeClasspathJars: []
        )
        let app = JavaGradleProjectModel.Subproject(
            path: ":app", directory: URL(fileURLWithPath: "/p/app"), languageLevel: 17, sourceSets: [main]
        )
        let lib = JavaGradleProjectModel.Subproject(path: ":lib", directory: URL(fileURLWithPath: "/p/lib"), languageLevel: 11, sourceSets: [])
        let model = JavaGradleProjectModel(formatVersion: 5, gradleVersion: "8", subprojects: [app, lib])
        XCTAssertEqual(model.languageLevel(forFile: URL(fileURLWithPath: "/p/app/src/main/java/a/A.java")), 17)
        XCTAssertEqual(model.languageLevel(forFile: URL(fileURLWithPath: "/p/lib/src/B.java")), 11)
        XCTAssertNil(model.languageLevel(forFile: URL(fileURLWithPath: "/elsewhere/C.java")))
    }
}
