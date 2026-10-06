import XCTest
@testable import Umbra

final class HTTPProtobufTests: XCTestCase {
    private let protobuf = "application/x-protobuf"
    private let grpc = "application/grpc"

    private func data(_ hex: String) -> Data {
        Data(hex.split(separator: " ").map { UInt8($0, radix: 16)! })
    }

    private func render(_ hex: String, contentType: String? = nil, grpcEncoding: String? = nil) -> String? {
        HTTPProtobuf.render(data(hex), contentType: contentType ?? protobuf, grpcEncoding: grpcEncoding)
    }

    // MARK: - Content types

    func testRecognisesProtobufContentTypes() {
        for type in [
            "application/protobuf", "application/x-protobuf", "application/vnd.google.protobuf",
            "application/x-google-protobuf", "application/proto", "application/grpc",
            "application/grpc+proto", "application/grpc-web", "application/grpc-web+proto",
            "application/connect+proto", "Application/X-Protobuf; charset=binary",
        ] {
            XCTAssertTrue(HTTPProtobuf.isProtobuf(contentType: type), type)
        }
    }

    func testRejectsOtherContentTypes() {
        for type in ["text/plain", "application/json", "application/octet-stream", "application/grpc-web-text", ""] {
            XCTAssertFalse(HTTPProtobuf.isProtobuf(contentType: type), type)
        }
        XCTAssertFalse(HTTPProtobuf.isProtobuf(contentType: nil))
    }

    // MARK: - Values

    func testContactsSampleRendersAsATree() {
        let sample = "0a 2f 0a 08 4a 6f 68 6e 20 44 6f 65 10 01 1a 10 6a 6f 68 6e 40 65 78 61 6d 70 6c 65 2e 63 6f 6d 22 0f 0a 0b 31 31 31 2d 32 32 32 2d 33 33 33 10 01 0a 1e 0a 08 4a 61 6e 65 20 44 6f 65 10 02 1a 10 6a 61 6e 65 40 65 78 61 6d 70 6c 65 2e 63 6f 6d"
        XCTAssertEqual(render(sample), """
        1 {
          1: "John Doe"
          2: 1  // sint: -1
          3: "john@example.com"
          4 {
            1: "111-222-333"
            2: 1  // sint: -1
          }
        }
        1 {
          1: "Jane Doe"
          2: 2  // sint: 1
          3: "jane@example.com"
        }
        """)
    }

    func testVarintShowsUnsignedValueAndZigzagReading() {
        XCTAssertEqual(render("08 96 01"), "1: 150  // sint: 75")
        XCTAssertEqual(render("08 00"), "1: 0")
    }

    func testMinusOneVarintDoesNotTrap() {
        XCTAssertEqual(
            render("08 ff ff ff ff ff ff ff ff ff 01"),
            "1: 18446744073709551615  // int64: -1, sint: -9223372036854775808"
        )
    }

    func testOverlongVarintStopsTheParse() {
        // Eleven bytes: not a varint, so nothing decodes.
        XCTAssertNil(render("08 ff ff ff ff ff ff ff ff ff ff 01"))
    }

    func testFixed32ShowsFloatReading() {
        XCTAssertEqual(render("0d db 0f 49 40"), "1: 1078530011  // float: 3.1415927")
        XCTAssertEqual(render("0d ff ff ff ff"), "1: -1  // uint: 4294967295, float: nan")
    }

    func testFixed64ShowsDoubleReading() {
        XCTAssertEqual(render("09 00 00 00 00 00 00 f8 3f"), "1: 4609434218613702656  // double: 1.5")
    }

    func testStringsAreEscaped() {
        XCTAssertEqual(render("0a 04 61 22 62 0a"), "1: \"a\\\"b\\n\"")
    }

    func testEmptyLengthDelimitedFieldIsAnEmptyString() {
        XCTAssertEqual(render("0a 00"), "1: \"\"")
    }

    func testBinaryPayloadIsHex() {
        XCTAssertEqual(render("0a 03 ff ff ff"), "1: <ff ff ff>")
    }

    func testLongBinaryPayloadIsTruncated() {
        let hex = "0a 46 " + Array(repeating: "ff", count: 70).joined(separator: " ")
        let expected = "1: <" + Array(repeating: "ff", count: 64).joined(separator: " ") + " … (70 bytes)>"
        XCTAssertEqual(render(hex), expected)
    }

    func testPackedVarints() {
        XCTAssertEqual(render("0a 03 01 02 03"), "1: [1, 2, 3]")
    }

    func testZeroBytesAreNotAMessage() {
        // Field number 0 is invalid, so this cannot be a nested message.
        let output = render("0a 04 00 00 00 00")
        XCTAssertEqual(output, "1: [0, 0, 0, 0]")
        XCTAssertFalse(output?.contains("{") ?? true)
    }

    func testBytesAfterAMalformedFieldAreReportedAsLeftOver() {
        XCTAssertEqual(render("08 01 0a 05 61"), """
        1: 1  // sint: -1
        // 3 bytes could not be decoded: 0a 05 61
        """)
    }

    func testHugeLengthDoesNotTrap() {
        // Length 2^63 does not fit an Int.
        XCTAssertNil(render("0a 80 80 80 80 80 80 80 80 80 01"))
    }

    func testGroupsAndUnassignedWireTypesEndTheParse() {
        XCTAssertNil(render("0b 01 0c"))
        XCTAssertNil(render("0e 01"))
    }

    func testNothingDecodedReturnsNil() {
        XCTAssertNil(render("00"))
        XCTAssertNil(HTTPProtobuf.render(Data(), contentType: protobuf))
    }

    func testNestingIsCappedAtSixtyFourLevels() {
        func wrap(_ payload: [UInt8]) -> [UInt8] {
            var length: [UInt8] = []
            var remaining = payload.count
            while remaining >= 0x80 {
                length.append(UInt8(remaining & 0x7F) | 0x80)
                remaining >>= 7
            }
            length.append(UInt8(remaining))
            return [0x0A] + length + payload
        }
        var body: [UInt8] = [0x08, 0x01]
        for _ in 0..<70 { body = wrap(body) }

        let output = HTTPProtobuf.render(Data(body), contentType: protobuf)
        XCTAssertNotNil(output)
        XCTAssertEqual(output?.split(separator: "\n").filter { $0.hasSuffix(" {") }.count, 64)
    }

    func testHugeBodiesAreNotDecoded() {
        let body = Data(count: HTTPProtobuf.maxDecodedBytes + 1)
        let output = HTTPProtobuf.render(body, contentType: protobuf)
        XCTAssertEqual(output?.hasPrefix("// "), true)
        XCTAssertEqual(output?.contains("too large"), true)
    }

    // MARK: - gRPC envelopes

    func testGRPCFramesAreSplitIntoMessages() {
        let body = "00 00 00 00 03 08 96 01 00 00 00 00 02 08 01"
        XCTAssertEqual(render(body, contentType: grpc), """
        // message 1 (3 bytes)
        1: 150  // sint: 75
        // message 2 (2 bytes)
        1: 1  // sint: -1
        """)
    }

    func testGRPCCompressedFrameIsNotDecoded() {
        XCTAssertEqual(
            render("01 00 00 00 02 aa bb", contentType: grpc, grpcEncoding: "gzip"),
            "// message 1: compressed (grpc-encoding: gzip), not decoded"
        )
    }

    func testGRPCWebTrailersArePrintedAsText() {
        let trailers = Array("grpc-status: 0\r\n".utf8).map { String($0, radix: 16) }.joined(separator: " ")
        let body = "00 00 00 00 03 08 96 01 80 00 00 00 10 " + trailers
        XCTAssertEqual(render(body, contentType: "application/grpc-web+proto"), """
        // message 1 (3 bytes)
        1: 150  // sint: 75
        // trailers (16 bytes)
        grpc-status: 0
        """)
    }

    func testEmptyGRPCMessageIsListed() {
        XCTAssertEqual(render("00 00 00 00 00", contentType: grpc), "// message 1 (0 bytes)")
    }

    func testMalformedEnvelopesFallBackToOneMessage() {
        XCTAssertEqual(render("08 96 01", contentType: grpc), "1: 150  // sint: 75")
        // Declared length runs past the end of the body.
        XCTAssertNil(render("00 00 00 00 09 08", contentType: grpc))
    }

    func testPlainProtobufIsNotReadAsEnvelopes() {
        // Same bytes as a gRPC frame, but the type says plain protobuf: field 0 is invalid.
        XCTAssertNil(render("00 00 00 00 03 08 96 01", contentType: protobuf))
    }
}
