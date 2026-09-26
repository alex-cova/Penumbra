import XCTest
@testable import Penumbra

/// Recent Locations rows: newest first, one per file and line, titled `File:line`.
@MainActor
final class RecentLocationsPaletteProviderTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/proj")

    func testListsNewestFirstWithoutRepeatingAFileAndLine() async {
        let a = root.appendingPathComponent("src/A.java")
        let b = root.appendingPathComponent("B.java")
        let provider = RecentLocationsPaletteProvider(
            entries: {
                [
                    PaletteLocationEntry(url: a, line: 12, lineText: "    int x = 1;\n"),
                    PaletteLocationEntry(url: b, line: 3),
                    PaletteLocationEntry(url: a, line: 12, column: 5)
                ]
            },
            root: { URL(fileURLWithPath: "/proj") },
            onOpen: { _, _ in }
        )

        let items = await provider.items(matching: "", limit: 10)

        XCTAssertEqual(items.map(\.title), ["A.java:12", "B.java:3"])
        XCTAssertEqual(items.first?.location, "int x = 1;")
        XCTAssertEqual(items.first?.subtitle, "src")
        XCTAssertNil(items.last?.location)
    }

    func testOpensTheChosenLine() async {
        let url = root.appendingPathComponent("A.java")
        let opened = OpenedTargets()
        let provider = RecentLocationsPaletteProvider(
            entries: { [PaletteLocationEntry(url: url, line: 7, column: 3)] },
            onOpen: { url, target in opened.values.append((url, target)) }
        )

        let items = await provider.items(matching: "A.java", limit: 10)
        await items.first?.action()

        XCTAssertEqual(opened.values.first?.0, url)
        XCTAssertEqual(opened.values.first?.1, PaletteLineTarget(line: 7, column: 3))
    }
}

@MainActor
private final class OpenedTargets {
    var values: [(URL, PaletteLineTarget)] = []
}
