import XCTest
@testable import Penumbra

final class FindTextSourceTests: XCTestCase {
    func testStringFindTextSourceAndSnapshotAgreeOnSubstring() async throws {
        let original = "café😀\r\nabc"
        let view = try await loadFileBacked(original)
        view.replaceText(in: NSRange(location: 3, length: 0), with: "|")
        let expected = "caf|é😀\r\nabc"
        let snapshot = try XCTUnwrap(view.contentSnapshot())
        let stringSource = StringFindTextSource(expected)

        XCTAssertEqual(snapshot.utf16Length, stringSource.utf16Length)
        XCTAssertEqual(snapshot.utf16Length, (expected as NSString).length)
        XCTAssertEqual(
            snapshot.substring(utf16Offset: 0, length: snapshot.utf16Length),
            stringSource.substring(utf16Offset: 0, length: stringSource.utf16Length)
        )
        XCTAssertEqual(
            snapshot.substring(utf16Offset: 2, length: 5),
            stringSource.substring(utf16Offset: 2, length: 5)
        )
        XCTAssertEqual(snapshot.substring(utf16Offset: snapshot.utf16Length, length: 4), "")
        XCTAssertEqual(snapshot.utf8Length, expected.utf8.count)
    }

    func testSnapshotContiguousNSStringIsNil() async throws {
        let view = try await loadFileBacked("hello world")
        let snapshot = try XCTUnwrap(view.contentSnapshot())
        XCTAssertNil(snapshot.contiguousNSString)
        XCTAssertTrue(view.isFileBacked)
        XCTAssertEqual(view.materializeCount, 0)
    }

    func testStringFindTextSourceExposesContiguousNSString() {
        let source = StringFindTextSource("abc")
        XCTAssertEqual(source.contiguousNSString as String?, "abc")
        XCTAssertEqual(source.utf16Length, 3)
        XCTAssertEqual(source.substring(utf16Offset: 1, length: 2), "bc")
    }

    func testSnapshotSubstringEmitsUnpairedSurrogates() async throws {
        let text = "a😀b"
        let view = try await loadFileBacked(text)
        let snapshot = try XCTUnwrap(view.contentSnapshot())
        let ns = text as NSString
        XCTAssertEqual(ns.length, 4)
        for offset in 0..<ns.length {
            for length in 1...(ns.length - offset) {
                let fromSnapshot = snapshot.substring(utf16Offset: offset, length: length) as NSString
                let fromNS = ns.substring(with: NSRange(location: offset, length: length)) as NSString
                XCTAssertEqual(fromSnapshot.length, fromNS.length, "offset \(offset) length \(length)")
                for index in 0..<fromNS.length {
                    XCTAssertEqual(
                        fromSnapshot.character(at: index),
                        fromNS.character(at: index),
                        "offset \(offset) length \(length) unit \(index)"
                    )
                }
            }
        }
        XCTAssertEqual(snapshot.substring(utf16Offset: 1, length: 1) as NSString, ns.substring(with: NSRange(location: 1, length: 1)) as NSString)
        XCTAssertTrue((0xD800...0xDBFF).contains(ns.character(at: 1)))
        XCTAssertTrue((0xDC00...0xDFFF).contains(ns.character(at: 2)))
    }

    private func loadFileBacked(_ text: String) async throws -> StringView {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try text.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        let state = try await TextViewState.load(contentsOf: url)
        return state.stringView
    }
}
