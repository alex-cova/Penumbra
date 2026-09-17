import XCTest
@testable import Penumbra

/// Section merging, ordering and cancellation for the "Search Everywhere" engine.
@MainActor
final class SearchEverywhereEngineTests: XCTestCase {
    private final class StubProvider: SearchEverywhereProvider {
        let sectionTitle: String
        let sectionOrder: Int
        let titles: [String]

        init(sectionTitle: String, sectionOrder: Int, titles: [String]) {
            self.sectionTitle = sectionTitle
            self.sectionOrder = sectionOrder
            self.titles = titles
        }

        func items(matching query: String, limit: Int) async -> [PaletteItem] {
            let matches = query.isEmpty ? titles : titles.filter { $0.localizedCaseInsensitiveContains(query) }
            return matches.prefix(limit).enumerated().map { index, title in
                PaletteItem(id: "\(sectionTitle):\(title)", title: title, sectionTitle: sectionTitle,
                            score: limit - index, action: {})
            }
        }
    }

    func testSectionsAreOrderedBySectionOrder() async {
        let engine = SearchEverywhereEngine(providers: [
            StubProvider(sectionTitle: "Symbols", sectionOrder: 30, titles: ["alpha"]),
            StubProvider(sectionTitle: "Files", sectionOrder: 20, titles: ["alpha.swift"]),
            StubProvider(sectionTitle: "Recent Files", sectionOrder: 5, titles: ["alpha.md"])
        ])
        let sections = await engine.sectionsNow(for: "alpha")
        XCTAssertEqual(sections.map(\.title), ["Recent Files", "Files", "Symbols"])
    }

    func testEmptySectionsAreDropped() async {
        let engine = SearchEverywhereEngine(providers: [
            StubProvider(sectionTitle: "Files", sectionOrder: 20, titles: ["main.swift"]),
            StubProvider(sectionTitle: "Symbols", sectionOrder: 30, titles: ["helper"])
        ])
        let sections = await engine.sectionsNow(for: "main")
        XCTAssertEqual(sections.map(\.title), ["Files"])
    }

    func testDebouncedSearchDeliversLatestQueryOnly() {
        let provider = StubProvider(sectionTitle: "Files", sectionOrder: 10, titles: ["one", "two", "three"])
        let engine = SearchEverywhereEngine(providers: [provider])
        engine.debounceMilliseconds = 20
        let expectation = expectation(description: "final result")
        var delivered: [[PaletteSection]] = []

        engine.search("o") { delivered.append($0) }
        engine.search("tw") { sections in
            delivered.append(sections)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(delivered.count, 1, "The superseded query must not call back")
        XCTAssertEqual(delivered.first?.first?.items.map(\.title), ["two"])
    }
}
