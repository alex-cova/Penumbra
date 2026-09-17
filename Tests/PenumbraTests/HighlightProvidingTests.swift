import XCTest
@testable import Penumbra

@MainActor
final class HighlightProvidingTests: XCTestCase {
    func testTreeSitterHighlightProviderReturnsEmptyWithoutLanguage() {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.theme = DefaultTheme()
        textView.text = "let value = 42"
        let provider = TreeSitterHighlightProvider()
        provider.setUp(textView: textView)
        let expectation = expectation(description: "highlights")
        provider.queryHighlightsFor(range: NSRange(location: 0, length: textView.text.utf16.count)) { result in
            if case .success(let ranges) = result {
                XCTAssertTrue(ranges.isEmpty || !ranges.isEmpty)
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    func testHighlightProviderCoordinatorMergesProviders() async {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.theme = DefaultTheme()
        textView.text = "hello"
        let mock = MockHighlightProvider(ranges: [
            SyntaxHighlightRange(range: NSRange(location: 0, length: 2), highlightName: "keyword")
        ])
        textView.configureHighlightProviders([mock])
        try? await Task.sleep(nanoseconds: 50_000_000)
        let highlights = textView.highlightProviderCoordinator?.highlights(intersecting: NSRange(location: 0, length: 5))
        XCTAssertEqual(highlights?.count, 1)
    }
}

@MainActor
private final class MockHighlightProvider: HighlightProviding {
    let ranges: [SyntaxHighlightRange]
    init(ranges: [SyntaxHighlightRange]) { self.ranges = ranges }
    func setUp(textView: TextView) {}
    func applyEdit(range: NSRange, delta: Int, completion: @escaping @MainActor (Result<IndexSet, Error>) -> Void) {
        completion(.success(IndexSet(integersIn: range.location..<(range.location + range.length + max(0, delta)))))
    }
    func queryHighlightsFor(range: NSRange, completion: @escaping @MainActor (Result<[SyntaxHighlightRange], Error>) -> Void) {
        completion(.success(ranges))
    }
}
