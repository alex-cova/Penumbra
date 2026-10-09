import XCTest
@testable import Penumbra

final class TextFileEncodingTests: XCTestCase {
    func testEveryOfferedEncodingRoundTripsASCII() throws {
        for encoding in TextFileEncoding.all {
            let data = try XCTUnwrap(encoding.encode("hello\nworld"), encoding.displayName)
            XCTAssertEqual(encoding.decode(data), "hello\nworld", encoding.displayName)
        }
    }

    func testIdentifiersAreUnique() {
        XCTAssertEqual(Set(TextFileEncoding.all.map(\.id)).count, TextFileEncoding.all.count)
        XCTAssertEqual(TextFileEncoding.named("cp1251")?.shortName, "Windows-1251")
    }

    func testRegionalEncodingsRoundTrip() throws {
        let samples: [(String, String)] = [
            ("cp1251", "Привет"), ("koi8r", "Привет"), ("shiftjis", "日本語"), ("eucjp", "日本語"),
            ("gbk", "中文"), ("big5", "中文"), ("euckr", "한국어"), ("cp1250", "zażółć"), ("latin9", "€uro")
        ]
        for (id, text) in samples {
            let encoding = try XCTUnwrap(TextFileEncoding.named(id), id)
            let data = try XCTUnwrap(encoding.encode(text), id)
            XCTAssertEqual(encoding.decode(data), text, id)
        }
    }

    func testByteOrderMarksAreWrittenAndDropped() throws {
        XCTAssertEqual(TextFileEncoding.utf8WithBOM.encode("a"), Data([0xEF, 0xBB, 0xBF, 0x61]))
        XCTAssertEqual(TextFileEncoding.utf16BE.encode("a"), Data([0xFE, 0xFF, 0x00, 0x61]))
        XCTAssertEqual(TextFileEncoding.utf16LE.decode(Data([0xFF, 0xFE, 0x61, 0x00])), "a")
        XCTAssertEqual(TextFileEncoding.utf8WithBOM.decode(Data([0xEF, 0xBB, 0xBF, 0x61])), "a")
    }

    func testUnrepresentableCharacterIsNil() {
        XCTAssertNil(TextFileEncoding.named("latin1")?.encode("☃"))
    }

    func testDetectsByteOrderMarks() {
        XCTAssertEqual(TextFileEncoding.detect(byteOrderMarkIn: Data([0xEF, 0xBB, 0xBF, 0x61])), .utf8WithBOM)
        XCTAssertEqual(TextFileEncoding.detect(byteOrderMarkIn: Data([0xFF, 0xFE, 0x61, 0x00])), .utf16LE)
        XCTAssertEqual(TextFileEncoding.detect(byteOrderMarkIn: Data([0xFE, 0xFF, 0x00, 0x61])), .utf16BE)
        XCTAssertNil(TextFileEncoding.detect(byteOrderMarkIn: Data([0xFF, 0xFE, 0x00, 0x00])))
        XCTAssertNil(TextFileEncoding.detect(byteOrderMarkIn: Data("plain".utf8)))
    }

    func testGuessesUTF16WithoutAMark() throws {
        let le = try XCTUnwrap("hello world, plain ascii text".data(using: .utf16LittleEndian))
        XCTAssertEqual(TextFileEncoding.guess(from: le), .utf16LE)
        let be = try XCTUnwrap("hello world, plain ascii text".data(using: .utf16BigEndian))
        XCTAssertEqual(TextFileEncoding.guess(from: be), .utf16BE)
    }

    func testBinaryDataIsNotGuessed() {
        XCTAssertNil(TextFileEncoding.guess(from: Data([0x00, 0x01, 0x02, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x10])))
    }

    func testWesternTextGuessesWindows1252() throws {
        let data = try XCTUnwrap("café au lait, naïve façade".data(using: .windowsCP1252))
        XCTAssertEqual(TextFileEncoding.guess(from: data), .windows1252)
    }

    // MARK: - Documents

    func testDocumentOpensLatin1AndSavesItBack() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("enc-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try XCTUnwrap("caf\u{E9} cr\u{E8}me\n".data(using: .windowsCP1252))
        try original.write(to: url)

        let document = try await WorkbenchDocument.load(contentsOf: url)
        XCTAssertEqual(document.encoding, .windows1252)
        XCTAssertEqual(document.pendingState?.stringView.string as String?, "caf\u{E9} cr\u{E8}me\n")

        let textView = await MainActor.run { TextView() }
        await MainActor.run { textView.setState(document.pendingState!) }
        _ = try await document.save(from: textView)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testExplicitEncodingIsStrict() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("enc-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0x68, 0xE9, 0x6C]).write(to: url)  // not valid UTF-8
        do {
            _ = try await WorkbenchDocument.load(contentsOf: url, encoding: .utf8)
            XCTFail("expected invalidEncoding")
        } catch DocumentLoadError.invalidEncoding {
            // expected
        }
        let latin1 = try await WorkbenchDocument.load(contentsOf: url, encoding: TextFileEncoding.named("latin1"))
        XCTAssertEqual(latin1.pendingState?.stringView.string as String?, "h\u{E9}l")
    }

    func testBinaryFileStillFailsToOpen() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("enc-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0x89, 0x00, 0x00, 0x01, 0xFF, 0x00, 0x00, 0x00, 0x80]).write(to: url)
        do {
            _ = try await WorkbenchDocument.load(contentsOf: url)
            XCTFail("expected invalidEncoding")
        } catch DocumentLoadError.invalidEncoding {
            // expected
        }
    }

    func testUTF8BOMIsKeptAcrossASave() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("enc-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0xEF, 0xBB, 0xBF] + Array("hi\n".utf8)).write(to: url)
        let document = try await WorkbenchDocument.load(contentsOf: url)
        XCTAssertEqual(document.encoding, .utf8WithBOM)
        let textView = await MainActor.run { TextView() }
        await MainActor.run { textView.setState(document.pendingState!) }
        _ = try await document.save(from: textView)
        XCTAssertEqual(try Data(contentsOf: url), Data([0xEF, 0xBB, 0xBF] + Array("hi\n".utf8)))
    }
}
