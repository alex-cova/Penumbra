@preconcurrency import AppKit
import TestTreeSitterLanguages
import XCTest
@testable import Penumbra

/// Next / Previous Method reads the nearest function name from the syntax tree.
@MainActor
final class MethodNavigatorTests: XCTestCase {
    private let source = """
    class Widget {
      render(items) {
        return items;
      }
      update() {
        return 1;
      }
      tail() {}
    }
    """

    private func offset(of name: String, in text: String) -> Int {
        (text as NSString).range(of: name).location
    }

    private func target(from location: Int, forward: Bool, in text: String) throws -> Int? {
        let mode = LanguageModeFactory.javaScriptLanguageMode(text: text)
        let root = try XCTUnwrap(mode.rootSyntaxNode)
        let nsText = text as NSString
        let row = nsText.substring(to: location).components(separatedBy: "\n").count - 1
        let lineCount = text.components(separatedBy: "\n").count
        return MethodNavigator.target(
            from: location, row: row, lineCount: lineCount, forward: forward, root: root, configuration: .javaScript
        )
    }

    func testForwardWalksTheMethodsInOrderAndStopsAfterTheLast() throws {
        let render = offset(of: "render", in: source)
        let update = offset(of: "update", in: source)
        let tail = offset(of: "tail", in: source)
        XCTAssertEqual(try target(from: 0, forward: true, in: source), render)
        XCTAssertEqual(try target(from: render, forward: true, in: source), update)
        XCTAssertEqual(try target(from: update, forward: true, in: source), tail)
        XCTAssertNil(try target(from: tail, forward: true, in: source))
    }

    func testBackwardFromInsideAMethodGoesToItsOwnName() throws {
        let render = offset(of: "render", in: source)
        let update = offset(of: "update", in: source)
        let insideUpdate = offset(of: "return 1", in: source)
        XCTAssertEqual(try target(from: insideUpdate, forward: false, in: source), update)
        XCTAssertEqual(try target(from: update, forward: false, in: source), render)
        XCTAssertNil(try target(from: render, forward: false, in: source))
    }

    func testTheWindowGrowsToFindAMethodFarAway() throws {
        let filler = String(repeating: "  // filler\n", count: 1500)
        let text = "class A {\n  first() {}\n\(filler)  last() {}\n}"
        let first = offset(of: "first", in: text)
        let last = offset(of: "last", in: text)
        XCTAssertEqual(try target(from: first, forward: true, in: text), last)
        XCTAssertEqual(try target(from: last, forward: false, in: text), first)
    }

    func testNearestPicksTheClosestStartOnTheRightSide() {
        XCTAssertEqual(MethodNavigator.nearest(in: [10, 50, 90], to: 50, forward: true), 90)
        XCTAssertEqual(MethodNavigator.nearest(in: [10, 50, 90], to: 50, forward: false), 10)
        XCTAssertNil(MethodNavigator.nearest(in: [10], to: 10, forward: false))
    }
}
