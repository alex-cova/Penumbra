import EditorIntelligence
import JavaIntelligence
import SwiftIntelligence
import XCTest

final class DependencySourceLocationTests: XCTestCase {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    func testASourceKitGeneratedInterfaceIsRecognisedWhateverTheTemporaryFolderIsCalled() {
        for path in [
            "/var/folders/3f/abc/T/sourcekit-lsp/GeneratedInterfaces/9186664781623773929/Swift.String.swiftinterface",
            "/private/var/folders/3f/abc/T/sourcekit-lsp/GeneratedInterfaces/9186664781623773929/Foundation.swiftinterface",
            "/tmp/sourcekit-lsp/GeneratedInterfaces/1/A.swiftinterface",
        ] {
            XCTAssertTrue(DependencySourceLocation.isGeneratedInterface(url(path)), path)
        }
    }

    func testAnythingElseIsTheUsersOwnFile() {
        for path in [
            // A `.swiftinterface` the project owns is not generated.
            "/proj/Sources/Lib/Lib.swiftinterface",
            "/proj/Sources/Lib/Box.swift",
            // Only the folder SourceKit-LSP writes counts, not a lookalike.
            "/proj/GeneratedInterfaces/Box.swift",
            "/var/T/sourcekit-lsp/Logs/log.txt",
            "/var/T/sourcekit-lsp",
            "/",
        ] {
            XCTAssertFalse(DependencySourceLocation.isGeneratedInterface(url(path)), path)
        }
    }

    func testAGeneratedInterfaceIsADependencySourceLikeADecompiledClass() {
        func document(_ path: String) -> Document {
            let origin = TextPosition(line: 0, column: 0, utf16Offset: 0)
            return Document(
                url: url(path), displayName: "D",
                contentSnapshot: TextSnapshot(version: 0, text: ""),
                selection: Selection(range: TextRange(start: origin, end: origin)),
                cursor: Cursor(position: origin), viewport: Viewport(x: 0, y: 0, width: 1, height: 1)
            )
        }
        XCTAssertTrue(document("/var/T/sourcekit-lsp/GeneratedInterfaces/1/Swift.String.swiftinterface").isDependencySource)
        XCTAssertTrue(document("/cache/JavaIndex/attached-sources/decompiled/ab/T.java").isDependencySource)
        XCTAssertFalse(document("/proj/Sources/Lib/Box.swift").isDependencySource)
    }

    /// Opening a 1 MB SDK interface as a Swift tab must not turn `String` and `Array` into project symbols.
    func testTheNativeSwiftIndexNeverReadsAnInterfaceFile() {
        XCTAssertFalse(SwiftPaths.isSourceFile(url("/var/T/sourcekit-lsp/GeneratedInterfaces/1/Swift.String.swiftinterface")))
        XCTAssertFalse(SwiftPaths.isSourceFile(url("/proj/Sources/Lib/Lib.swiftinterface")))
        XCTAssertTrue(SwiftPaths.isSourceFile(url("/proj/Sources/Lib/Box.swift")))
    }
}
