import Foundation
import XCTest
@testable import SwiftIntelligence

final class SwiftPreviewExtractorTests: XCTestCase {
    private func extract(_ source: String) -> [SwiftPreviewBlock] {
        SwiftPreviewExtractor.extract(from: source)
    }

    private func text(_ bytes: Range<Int>, in source: String) -> String {
        String(decoding: Array(source.utf8)[bytes], as: UTF8.self)
    }

    func testUntitledAndTitledMacroBlocks() {
        let source = """
        import SwiftUI
        #Preview { Text("hi") }
        #Preview("Dark") {
            Text("dark")
        }
        """
        let blocks = extract(source)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertNil(blocks[0].title)
        XCTAssertEqual(blocks[0].displayName, "Preview 1")
        XCTAssertEqual(blocks[0].line, 2)
        XCTAssertEqual(text(blocks[0].bodyBytes, in: source), " Text(\"hi\") ")
        XCTAssertEqual(blocks[1].title, "Dark")
        XCTAssertEqual(blocks[1].displayName, "Dark")
        XCTAssertEqual(blocks[1].line, 3)
        XCTAssertEqual(blocks.map(\.index), [0, 1])
    }

    func testTraitsAreVariadicAndKeptAsWritten() {
        let blocks = extract("""
        #Preview("x", traits: .fixedLayout(width: 1, height: 2), .landscapeLeft) { Text("c") }
        #Preview(traits: .sizeThatFitsLayout) { Text("d") }
        """)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].traits, ".fixedLayout(width: 1, height: 2), .landscapeLeft")
        XCTAssertEqual(blocks[0].title, "x")
        XCTAssertEqual(blocks[1].traits, ".sizeThatFitsLayout")
        XCTAssertNil(blocks[1].title)
    }

    func testBodyLabelAndTitleWithInterpolation() {
        let blocks = extract("""
        #Preview("n \\(1)", body: { Text("b") })
        """)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].title, "n \\(1)")
    }

    func testPreviewableDeclarationsAreSplitFromContent() {
        let source = """
        #Preview {
            @Previewable @State var n = 3
            @Previewable @Environment(\\.colorScheme) var scheme
            CounterView(count: n)
        }
        """
        let blocks = extract(source)
        XCTAssertEqual(blocks.count, 1)
        let block = blocks[0]
        XCTAssertEqual(block.previewables.map(\.name), ["n", "scheme"])
        XCTAssertEqual(block.previewables[0].declarationText, "@State var n = 3")
        XCTAssertEqual(block.previewables[1].declarationText, "@Environment(\\.colorScheme) var scheme")
        XCTAssertTrue(block.previewables[0].text.hasPrefix("@Previewable"))
        XCTAssertEqual(text(block.contentBytes, in: source).trimmingCharacters(in: .whitespacesAndNewlines), "CounterView(count: n)")
    }

    func testAPreviewableAfterContentIsNotLifted() {
        let blocks = extract("""
        #Preview {
            Text("a")
            @Previewable @State var late = 1
        }
        """)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertTrue(blocks[0].previewables.isEmpty)
    }

    func testPreviewProviderTypesAreBlocksNamedForTheType() {
        let source = """
        struct Foo_Previews: PreviewProvider {
            static var previews: some View {
                Group { Foo(); Foo().padding() }
            }
        }
        struct NotAProvider {
            static var previews: some View { Text("no") }
        }
        """
        let blocks = extract(source)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .provider(typeName: "Foo_Previews"))
        XCTAssertEqual(blocks[0].displayName, "Foo_Previews")
        XCTAssertEqual(blocks[0].line, 1)
        XCTAssertTrue(text(blocks[0].bodyBytes, in: source).contains("Group { Foo(); Foo().padding() }"))
    }

    func testBlocksAreInSourceOrderAcrossKinds() {
        let blocks = extract("""
        struct A_Previews: PreviewProvider { static var previews: some View { Text("a") } }
        #Preview("b") { Text("b") }
        struct C_Previews: PreviewProvider { static var previews: some View { Text("c") } }
        """)
        XCTAssertEqual(blocks.map(\.displayName), ["A_Previews", "b", "C_Previews"])
        XCTAssertEqual(blocks.map(\.index), [0, 1, 2])
    }

    func testPreviewsInsideConditionalCompilationAndExtensionsAreFound() {
        let blocks = extract("""
        #if DEBUG
        #Preview("in if") { Text("a") }
        #endif
        @available(macOS 14, *)
        #Preview("available") { Text("b") }
        extension Foo {
            #Preview("nested") { Text("c") }
        }
        """)
        XCTAssertEqual(blocks.map(\.displayName), ["in if", "available", "nested"])
    }

    func testOtherMacrosStringsAndCommentsAreNotPreviews() {
        let blocks = extract("""
        // #Preview { Text("comment") }
        let s = "#Preview { Text(\\"string\\") }"
        #expect(true)
        #Predicate<Int> { $0 > 1 }
        struct Preview { var name = "Preview" }
        """)
        XCTAssertTrue(blocks.isEmpty)
    }

    func testFileWithoutTheWordIsNotParsed() {
        XCTAssertTrue(extract("struct A {}").isEmpty)
    }

    func testBytesAreUTF8OffsetsWithNonASCIIBefore() {
        let source = "// é\n#Preview(\"ñ\") { Text(\"é\") }\n"
        let blocks = extract(source)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].title, "ñ")
        XCTAssertEqual(text(blocks[0].bodyBytes, in: source), " Text(\"é\") ")
        XCTAssertEqual(blocks[0].line, 2)
    }
}
