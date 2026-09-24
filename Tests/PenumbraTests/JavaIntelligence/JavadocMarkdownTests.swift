import XCTest
@testable import JavaIntelligence

final class JavadocMarkdownTests: XCTestCase {
    func testPlainDescriptionJoinsWrappedLines() {
        XCTAssertEqual(
            JavadocMarkdown.format("Returns the number of\n elements in this list."),
            "Returns the number of elements in this list."
        )
    }

    func testCodeAndLinkTagsBecomeInlineCode() {
        let doc = "Same as {@code size() == 0}, see {@link List#size()} and {@link java.util.Map Map} or {@linkplain #clear}."
        XCTAssertEqual(
            JavadocMarkdown.format(doc),
            "Same as `size() == 0`, see `List.size()` and `Map` or `clear`."
        )
    }

    func testParagraphsListsAndInlineHtml() {
        let doc = """
        First <b>bold</b> and <i>italic</i> and <code>x &lt; y</code>.
        <p>Second paragraph.
        <ul>
        <li>one
        <li>two
        </ul>
        """
        XCTAssertEqual(
            JavadocMarkdown.format(doc),
            "First **bold** and *italic* and `x < y`.\n\nSecond paragraph.\n\n- one\n- two"
        )
    }

    func testPreBlockBecomesAFencedCodeBlock() {
        let doc = "Example:\n<pre>{@code\nList<String> l = new ArrayList<>();\n}</pre>\nDone."
        let result = JavadocMarkdown.format(doc)
        XCTAssertTrue(result.contains("```java\n"), result)
        XCTAssertTrue(result.contains("List<String> l = new ArrayList<>();"), result)
        XCTAssertTrue(result.hasSuffix("Done."), result)
    }

    func testBlockTagsBecomeSections() {
        let doc = """
        Adds an element.
        @param index where to add it
        @param element what to add, must not be
            {@code null}
        @return {@code true} if added
        @throws IllegalArgumentException if the element is null
        @see List#add(Object)
        @since 1.2
        @author someone
        """
        XCTAssertEqual(JavadocMarkdown.format(doc), """
        Adds an element.

        **Parameters**
        - `index` — where to add it
        - `element` — what to add, must not be `null`

        **Returns** `true` if added

        **Throws**
        - `IllegalArgumentException` — if the element is null

        **See also** `List.add(Object)`
        """)
    }

    func testDeprecatedComesFirst() {
        let doc = "Old way.\n@deprecated Use {@link #newWay()} instead."
        XCTAssertEqual(JavadocMarkdown.format(doc), "**Deprecated.** Use `newWay()` instead.\n\nOld way.")
    }

    func testAtSignInsidePreIsNotATag() {
        let doc = "Use it:\n<pre>\n@Override\nvoid run() {}\n</pre>"
        let result = JavadocMarkdown.format(doc)
        XCTAssertTrue(result.contains("@Override"), result)
        XCTAssertFalse(result.contains("**"), result)
    }

    func testEmptyInputIsEmpty() {
        XCTAssertEqual(JavadocMarkdown.format(""), "")
        XCTAssertEqual(JavadocMarkdown.format("  \n  "), "")
    }
}

final class JavaSignatureTextTests: XCTestCase {
    private func stub(kind: JavaTypeKind = .classKind, modifiers: JavaModifiers = [.publicFlag], typeParameters: [JavaTypeParameter] = [],
                      superclass: JavaTypeRef? = nil, interfaces: [JavaTypeRef] = []) -> JavaClassStub {
        JavaClassStub(
            binaryName: "p.Foo", qualifiedName: "p.Foo", simpleName: "Foo", packageName: "p", kind: kind, modifiers: modifiers,
            typeParameters: typeParameters, superclass: superclass, interfaces: interfaces,
            origin: .jdkModule("java.base")
        )
    }

    private func classType(_ name: String, _ arguments: [JavaTypeArgument] = []) -> JavaTypeRef {
        .classType(qualifiedName: name, arguments: arguments, outer: nil)
    }

    func testClassSignatureWithGenericsSuperclassAndInterfaces() {
        let text = JavaSignatureText.type(stub(
            modifiers: [.publicFlag, .abstractFlag],
            typeParameters: [JavaTypeParameter(name: "T", bounds: [classType("java.lang.Comparable", [.type(.typeVariable(name: "T"))])])],
            superclass: classType("p.Base"),
            interfaces: [classType("java.util.List", [.type(.typeVariable(name: "T"))])]
        ))
        XCTAssertEqual(text, "public abstract class Foo<T extends Comparable<T>> extends Base implements List<T>")
    }

    func testInterfaceOmitsAbstractAndObjectSuperclass() {
        let text = JavaSignatureText.type(stub(kind: .interfaceKind, modifiers: [.publicFlag, .abstractFlag], superclass: classType("java.lang.Object")))
        XCTAssertEqual(text, "public interface Foo")
    }

    func testMethodSignatureWithGenericsVarargsAndThrows() {
        let method = JavaMethodStub(
            name: "of",
            typeParameters: [JavaTypeParameter(name: "E", bounds: [])],
            parameters: [JavaParameterStub(name: "items", type: .array(element: .typeVariable(name: "E")))],
            returnType: classType("java.util.List", [.type(.typeVariable(name: "E"))]),
            thrownTypes: [classType("java.io.IOException")],
            modifiers: [.publicFlag, .staticFlag, .varargs]
        )
        XCTAssertEqual(JavaSignatureText.method(method, in: nil), "public static <E> List<E> of(E... items) throws IOException")
    }

    func testConstructorAndFieldSignatures() {
        let constructor = JavaMethodStub(
            name: "<init>", parameters: [JavaParameterStub(name: "n", type: .primitive(.int))],
            returnType: .void, modifiers: [.publicFlag], isConstructor: true
        )
        XCTAssertEqual(JavaSignatureText.method(constructor, in: stub()), "public Foo(int n)")
        let field = JavaFieldStub(name: "MAX", type: .primitive(.int), modifiers: [.publicFlag, .staticFlag, .finalFlag])
        XCTAssertEqual(JavaSignatureText.field(field), "public static final int MAX")
    }
}
