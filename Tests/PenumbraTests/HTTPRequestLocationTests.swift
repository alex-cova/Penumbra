import XCTest
@testable import Umbra

final class HTTPRequestLocationTests: XCTestCase {
    func testSingleRequestStartsOnItsMethodLine() {
        let locations = HTTPRequestParser.requestLocations(in: "GET https://example.com/a\nAccept: */*\n")
        XCTAssertEqual(locations.map(\.startLine), [1])
        XCTAssertEqual(locations.first?.utf16Range.lowerBound, 0)
    }

    func testRequestsSeparatedByHashesGetTheirOwnLines() {
        let text = """
        ### first
        GET https://example.com/a

        ### second
        POST https://example.com/b
        Content-Type: application/json

        {"a": 1}

        ###
        DELETE https://example.com/c
        """
        let locations = HTTPRequestParser.requestLocations(in: text)
        XCTAssertEqual(locations.map(\.startLine), [2, 5, 11])
    }

    func testOffsetsAreUTF16AndSelectTheRequest() throws {
        // "é" is two UTF-8 bytes but one UTF-16 unit; the emoji is four bytes and two units.
        let text = "# é 😀\nGET https://example.com/a\n"
        let location = try XCTUnwrap(HTTPRequestParser.requestLocations(in: text).first)
        let nsText = text as NSString
        XCTAssertEqual(nsText.substring(from: location.utf16Range.lowerBound).hasPrefix("GET "), true)
        // The offset can be handed straight to `parse` to pick this request.
        let prepared = try HTTPRequestParser.parse(text: text, caretUTF16Offset: location.utf16Range.lowerBound, fileURL: nil)
        XCTAssertEqual(prepared.method, "GET")
    }

    func testEachStartOffsetPicksItsOwnRequest() throws {
        let text = "GET https://example.com/a\n\n###\nPOST https://example.com/b\n"
        let locations = HTTPRequestParser.requestLocations(in: text)
        XCTAssertEqual(locations.count, 2)
        let methods = try locations.map {
            try HTTPRequestParser.parse(text: text, caretUTF16Offset: $0.utf16Range.lowerBound, fileURL: nil).method
        }
        XCTAssertEqual(methods, ["GET", "POST"])
    }

    func testFilesWithoutRequestsHaveNoLocations() {
        XCTAssertEqual(HTTPRequestParser.requestLocations(in: ""), [])
        XCTAssertEqual(HTTPRequestParser.requestLocations(in: "# just a comment\n"), [])
    }
}
