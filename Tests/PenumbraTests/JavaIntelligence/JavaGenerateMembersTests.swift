import EditorIntelligence
import XCTest
@testable import JavaIntelligence

final class JavaGenerateMembersTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/Person.java")

    // MARK: - Menu

    func testMenuOffersEveryKindForAClassWithFields() throws {
        let menu = try menu("""
        class Person {
            private String name;
            private int age;
            €
        }
        """)
        XCTAssertEqual(menu.typeName, "Person")
        XCTAssertEqual(
            menu.options.map(\.title),
            ["Constructor", "Getter and Setter", "Getter", "Setter", "toString()"]
        )
        XCTAssertEqual(menu.options.first { $0.kind == .getter }?.fields.map(\.name), ["name", "age"])
        XCTAssertEqual(menu.options.first { $0.kind == .getter }?.fields.map(\.typeText), ["String", "int"])
    }

    func testMenuLeavesOutWhatIsAlreadyThere() throws {
        let menu = try menu("""
        class Person {
            private final int id = 1;
            private String name;
            public String getName() { return name; }
            public void setName(String name) { this.name = name; }
            public String toString() { return name; }
            €
        }
        """)
        let byKind = Dictionary(uniqueKeysWithValues: menu.options.map { ($0.kind, $0) })
        XCTAssertEqual(byKind[.getter]?.fields.map(\.name), ["id"])
        XCTAssertNil(byKind[.setter], "id is final and name already has a setter")
        XCTAssertEqual(byKind[.getterAndSetter]?.fields.map(\.name), ["id"])
        XCTAssertNil(byKind[.toString])
        XCTAssertEqual(byKind[.constructor]?.fields.map(\.name), ["name"], "a final field with a value can't be assigned")
        XCTAssertEqual(byKind[.constructor]?.allowsEmptySelection, true)
    }

    func testMenuIsUnavailableInAnInterfaceAndInRecords() {
        XCTAssertNil(JavaGenerateMembers.menu(source: "interface T { int x(); }", caretUTF16: 12))
        XCTAssertNil(JavaGenerateMembers.menu(source: "record P(int x) { }", caretUTF16: 17))
    }

    func testMenuFallsBackToTheFirstTypeWhenTheCaretIsOutsideAny() throws {
        let menu = try menu("€import java.util.List;\nclass A { int x; }\n")
        XCTAssertEqual(menu.typeName, "A")
    }

    func testMenuUsesTheInnermostClass() throws {
        let menu = try menu("""
        class Outer {
            int a;
            static class Inner {
                int b;
                €
            }
        }
        """)
        XCTAssertEqual(menu.typeName, "Inner")
        XCTAssertEqual(menu.options.first { $0.kind == .getter }?.fields.map(\.name), ["b"])
    }

    // MARK: - Constructor

    func testConstructorAfterTheCaretsMember() throws {
        let text = try generate(.constructor, ["name", "age"], """
        class Person {
            private String name;
            private int age;€
            void run() {}
        }
        """)
        XCTAssertEqual(text, """
        class Person {
            private String name;
            private int age;

            public Person(String name, int age) {
                this.name = name;
                this.age = age;
            }

            void run() {}
        }
        """)
    }

    func testConstructorWithOnlyTheTickedFieldsInDeclarationOrder() throws {
        let text = try generate(.constructor, ["age", "name"], """
        class Person {
            String name;
            int age;
            String nick;
            €
        }
        """)
        XCTAssertTrue(text.contains("public Person(String name, int age) {"))
        XCTAssertFalse(text.contains("this.nick"))
    }

    func testConstructorWithNoFieldsIsEmpty() throws {
        let text = try generate(.constructor, [], "class T {\n    int x;\n    €\n}\n")
        XCTAssertEqual(text, """
        class T {
            int x;

            public T() {
            }
        }

        """)
    }

    func testConstructorGoesAfterTheLastFieldWhenTheCaretIsOutsideTheBody() throws {
        let text = try generate(.constructor, ["a"], """
        €class T {
            int a;
            void run() {}
        }
        """)
        XCTAssertEqual(text, """
        class T {
            int a;

            public T(int a) {
                this.a = a;
            }

            void run() {}
        }
        """)
    }

    func testAbstractClassConstructorIsProtectedAndEnumConstructorHasNoModifier() throws {
        let abstractText = try generate(.constructor, ["a"], "abstract class T {\n    int a;€\n}\n")
        XCTAssertTrue(abstractText.contains("    protected T(int a) {"))
        let enumText = try generate(.constructor, ["label"], """
        enum Color {
            RED("r");
            private final String label;€
        }
        """)
        XCTAssertTrue(enumText.contains("    Color(String label) {"), enumText)
        XCTAssertFalse(enumText.contains("public Color"))
    }

    func testDuplicateConstructorIsBlocked() throws {
        let plan = try plan(.constructor, ["a"], """
        class T {
            int a;
            T(int a) { this.a = a; }
            €
        }
        """)
        XCTAssertEqual(plan.blockingError, "T(int) already exists.")
    }

    // MARK: - Accessors

    func testGettersAndSettersInFieldOrder() throws {
        let text = try generate(.getterAndSetter, ["name", "age"], """
        class Person {
            private String name;
            private int age;€
        }
        """)
        XCTAssertEqual(text, """
        class Person {
            private String name;
            private int age;

            public String getName() {
                return this.name;
            }

            public void setName(String name) {
                this.name = name;
            }

            public int getAge() {
                return this.age;
            }

            public void setAge(int age) {
                this.age = age;
            }
        }
        """)
    }

    func testBooleanAccessorsAndFinalFieldsAndStaticFields() throws {
        let text = try generate(.getterAndSetter, ["active", "isReady", "id", "count"], """
        class T {
            private boolean active;
            private boolean isReady;
            private final int id = 1;
            private static int count;€
        }
        """)
        XCTAssertTrue(text.contains("public boolean isActive() {"))
        XCTAssertTrue(text.contains("public void setActive(boolean active) {"))
        XCTAssertTrue(text.contains("public boolean isReady() {"))
        XCTAssertTrue(text.contains("public void setReady(boolean isReady) {\n        this.isReady = isReady;"))
        XCTAssertTrue(text.contains("public int getId() {"))
        XCTAssertFalse(text.contains("setId"))
        XCTAssertTrue(text.contains("public static int getCount() {\n        return count;"))
        XCTAssertTrue(text.contains("public static void setCount(int count) {\n        T.count = count;"))
    }

    func testOnlyGettersOrOnlySetters() throws {
        let source = "class T {\n    int a;€\n}\n"
        let getters = try generate(.getter, ["a"], source)
        XCTAssertTrue(getters.contains("getA()"))
        XCTAssertFalse(getters.contains("setA"))
        let setters = try generate(.setter, ["a"], source)
        XCTAssertTrue(setters.contains("setA(int a)"))
        XCTAssertFalse(setters.contains("getA"))
    }

    func testExistingAccessorsAreSkippedAndNothingLeftIsReported() throws {
        let text = try generate(.getterAndSetter, ["a", "b"], """
        class T {
            int a;
            int b;
            int getA() { return a; }€
        }
        """)
        XCTAssertEqual(text.components(separatedBy: "getA()").count - 1, 1, "getA() must not be generated twice")
        XCTAssertTrue(text.contains("setA(int a)"))
        XCTAssertTrue(text.contains("getB()"))

        let plan = try plan(.getter, ["a"], "class T {\n    int a;\n    int getA() { return a; }€\n}\n")
        XCTAssertNotNil(plan.blockingError)
    }

    func testMultipleDeclaratorsAndArrayFields() throws {
        let text = try generate(.getter, ["x", "y", "tags"], """
        class T {
            int x, y;
            String[] tags;€
        }
        """)
        XCTAssertTrue(text.contains("public int getX()"))
        XCTAssertTrue(text.contains("public int getY()"))
        XCTAssertTrue(text.contains("public String[] getTags()"))
    }

    // MARK: - toString

    func testToStringLayout() throws {
        let text = try generate(.toString, ["name", "age", "tags"], """
        class Person {
            private String name;
            private int age;
            private static int count;
            private int[] tags;€
        }
        """)
        XCTAssertEqual(text, """
        class Person {
            private String name;
            private int age;
            private static int count;
            private int[] tags;

            @Override
            public String toString() {
                return "Person{" +
                        "name='" + name + '\\'' +
                        ", age=" + age +
                        ", tags=" + java.util.Arrays.toString(tags) +
                        '}';
            }
        }
        """)
    }

    func testToStringIgnoresStaticFieldsAndIsBlockedWhenPresent() throws {
        let noFields = try plan(.toString, ["count"], "class T {\n    static int count;€\n}\n")
        XCTAssertEqual(noFields.blockingError, "Select at least one field.")
        let existing = try plan(.toString, ["a"], """
        class T {
            int a;
            @Override public String toString() { return ""; }€
        }
        """)
        XCTAssertEqual(existing.blockingError, "toString() already exists.")
    }

    // MARK: - Placement

    func testInsertsIntoAnEmptyBody() throws {
        let empty = try generate(.constructor, [], "class T {€}\n")
        XCTAssertEqual(empty, "class T {\n    public T() {\n    }\n}\n")
    }

    func testInsertsAfterTheMemberTheCaretIsIn() throws {
        let text = try generate(.getter, ["a"], """
        class T {
            int a;
            void first() {
                €
            }
            void second() {}
        }
        """)
        let getter = try XCTUnwrap(text.range(of: "getA()")).lowerBound
        let first = try XCTUnwrap(text.range(of: "void first()")).lowerBound
        let second = try XCTUnwrap(text.range(of: "void second()")).lowerBound
        XCTAssertTrue(first < getter && getter < second, text)
    }

    func testKeepsATrailingLineCommentWithItsMember() throws {
        let text = try generate(.getter, ["a"], "class T {\n    int a; // the a€\n}\n")
        XCTAssertTrue(text.contains("int a; // the a\n\n    public int getA()"), text)
    }

    func testKeepsTabIndentation() throws {
        let text = try generate(.getter, ["a"], "class T {\n\tint a;€\n}\n")
        XCTAssertTrue(text.contains("\n\tpublic int getA() {\n\t\treturn this.a;\n\t}\n"), text)
    }

    func testNestedClassIsIndentedRelativeToItsDeclaration() throws {
        let text = try generate(.getter, ["b"], """
        class Outer {
            static class Inner {
                int b;€
            }
        }
        """)
        XCTAssertTrue(text.contains("        public int getB() {\n            return this.b;\n        }\n"), text)
    }

    func testEnumWithConstantsOnlyGetsASemicolon() throws {
        let text = try generate(.constructor, [], """
        enum Color {
            RED, GREEN€
        }
        """)
        XCTAssertEqual(text, """
        enum Color {
            RED, GREEN;

            Color() {
            }
        }
        """)
    }

    func testEnumWithMembersInsertsAfterTheCaretsMember() throws {
        let text = try generate(.getter, ["label"], """
        enum Color {
            RED("r");
            private final String label;€
        }
        """)
        XCTAssertTrue(text.contains("public String getLabel() {\n        return this.label;"), text)
    }

    func testGeneratedFileStillParsesWithoutErrors() throws {
        for kind in [CodeGenerationKind.constructor, .getterAndSetter, .toString] {
            let text = try generate(kind, ["a", "b"], """
            package p;
            import java.util.List;
            public class T<X> extends Base implements Comparable<T<X>> {
                private final List<String> a = null;
                private Map<String, List<X>> b;€
            }
            """)
            let tree = try XCTUnwrap(JavaSyntaxParser().parse(text))
            XCTAssertFalse(tree.rootNode.hasError, "\(kind): \(text)")
        }
    }

    // MARK: - Helpers

    private func split(_ marked: String) throws -> (source: String, caret: Int) {
        let range = try XCTUnwrap(marked.range(of: "€"), "missing € caret marker")
        let caret = (String(marked[..<range.lowerBound]) as NSString).length
        return (marked.replacingCharacters(in: range, with: ""), caret)
    }

    private func menu(_ marked: String) throws -> CodeGenerationMenu {
        let (source, caret) = try split(marked)
        return try XCTUnwrap(JavaGenerateMembers.menu(source: source, caretUTF16: caret))
    }

    private func plan(_ kind: CodeGenerationKind, _ fields: [String], _ marked: String) throws -> WorkspaceEditPlan {
        let (source, caret) = try split(marked)
        return JavaGenerateMembers.plan(kind: kind, fieldNames: fields, source: source, url: url, caretUTF16: caret)
    }

    /// The source after applying the plan's single edit.
    private func generate(_ kind: CodeGenerationKind, _ fields: [String], _ marked: String) throws -> String {
        let (source, caret) = try split(marked)
        let plan = JavaGenerateMembers.plan(kind: kind, fieldNames: fields, source: source, url: url, caretUTF16: caret)
        XCTAssertNil(plan.blockingError)
        let entry = try XCTUnwrap(plan.entries.first, "no edit for \(kind)")
        XCTAssertEqual(plan.entries.count, 1)
        let range = NSRange(
            location: entry.range.start.utf16Offset,
            length: entry.range.end.utf16Offset - entry.range.start.utf16Offset
        )
        return (source as NSString).replacingCharacters(in: range, with: entry.newText)
    }
}
