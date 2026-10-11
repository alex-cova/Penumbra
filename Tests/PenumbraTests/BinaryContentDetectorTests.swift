import Foundation
import Penumbra
import XCTest

final class BinaryContentDetectorTests: XCTestCase {
    func testEachMagicOpensAsBinary() {
        let magics: [(Data, String)] = [
            (Data([0x7F, 0x45, 0x4C, 0x46]), "ELF"),
            (Data([0xFE, 0xED, 0xFA, 0xCF]), "Mach-O 64-bit"),
            (Data([0xCF, 0xFA, 0xED, 0xFE]), "Mach-O 64-bit"),
            (Data([0xFE, 0xED, 0xFA, 0xCE]), "Mach-O 32-bit"),
            (Data([0xCE, 0xFA, 0xED, 0xFE]), "Mach-O 32-bit"),
            (Data([0x4D, 0x5A, 0x90, 0x00]), "PE executable"),
            (Data([0x50, 0x4B, 0x03, 0x04]), "ZIP archive"),
            (Data([0x50, 0x4B, 0x05, 0x06]), "ZIP archive"),
            (Data([0x50, 0x4B, 0x07, 0x08]), "ZIP archive"),
            (Data([0x1F, 0x8B]), "gzip"),
            (Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), "PNG image"),
            (Data("%PDF-1.7".utf8), "PDF"),
            (Data("SQLite format 3\u{0}".utf8), "SQLite database"),
            (Data([0x00, 0x61, 0x73, 0x6D]), "WebAssembly"),
            (Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x41]), "Java class file"),
            (Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x02]), "Mach-O fat"),
        ]
        for (head, label) in magics {
            XCTAssertEqual(BinaryContentDetector.describe(head), label, label)
            XCTAssertTrue(BinaryContentDetector.looksBinary(head), label)
        }
    }

    func testTruncatedHeadsDoNotCrash() {
        let heads: [Data] = [
            Data([0x7F]),
            Data([0x7F, 0x45]),
            Data([0x7F, 0x45, 0x4C]),
            Data([0x4D]),
            Data([0x89]),
            Data([0x89, 0x50, 0x4E]),
            Data([0x50, 0x4B, 0x03]),
            Data([0x1F]),
            Data([0xCA, 0xFE, 0xBA]),
            Data([0x00, 0x61, 0x73]),
        ]
        for head in heads {
            XCTAssertNil(BinaryContentDetector.describe(head))
            _ = BinaryContentDetector.looksBinary(head)
        }
        XCTAssertTrue(BinaryContentDetector.looksBinary(Data([0x7F, 0x45, 0x4C])))
        XCTAssertFalse(BinaryContentDetector.looksBinary(Data([0x4D])))
        XCTAssertFalse(BinaryContentDetector.looksBinary(Data([0x89, 0x50, 0x4E])))
        XCTAssertTrue(BinaryContentDetector.looksBinary(Data([0x1F])))
    }

    func testUTF16StaysTextWithAndWithoutBOM() {
        let withBOM = Data([0xFF, 0xFE, 0x61, 0x00, 0x62, 0x00])
        let withoutBOM = Data([0x61, 0x00, 0x62, 0x00, 0x63, 0x00])
        let bigEndian = Data([0x00, 0x61, 0x00, 0x62, 0x00, 0x63])
        XCTAssertFalse(BinaryContentDetector.looksBinary(withBOM))
        XCTAssertFalse(BinaryContentDetector.looksBinary(withoutBOM))
        XCTAssertFalse(BinaryContentDetector.looksBinary(bigEndian))
    }

    func testUTF32BOMStaysText() {
        XCTAssertFalse(BinaryContentDetector.looksBinary(Data([0xFF, 0xFE, 0x00, 0x00, 0x61, 0x00, 0x00, 0x00])))
        XCTAssertFalse(BinaryContentDetector.looksBinary(Data([0x00, 0x00, 0xFE, 0xFF, 0x00, 0x00, 0x00, 0x61])))
    }

    func testLatin1StaysTextAndNULRules() {
        XCTAssertFalse(BinaryContentDetector.looksBinary(Data([0x63, 0x61, 0x66, 0xE9])))
        let nul = Data([0x61, 0x62, 0x00, 0x63])
        XCTAssertTrue(BinaryContentDetector.looksBinary(nul))
        XCTAssertEqual(BinaryContentDetector.classify(URL(fileURLWithPath: "/tmp/Notes.foo")), .unknown)
        XCTAssertEqual(BinaryContentDetector.classify(URL(fileURLWithPath: "/tmp/Notes.swift")), .text)
    }

    func testNamesThatAreTextWithoutASniff() {
        XCTAssertEqual(BinaryContentDetector.classify(URL(fileURLWithPath: "/tmp/LICENSE")), .text)
        XCTAssertEqual(BinaryContentDetector.classify(URL(fileURLWithPath: "/tmp/Makefile")), .text)
        XCTAssertEqual(BinaryContentDetector.classify(URL(fileURLWithPath: "/tmp/Dockerfile")), .text)
        XCTAssertEqual(BinaryContentDetector.classify(URL(fileURLWithPath: "/tmp/.gitignore")), .text)
        XCTAssertEqual(BinaryContentDetector.classify(URL(fileURLWithPath: "/tmp/.zshrc")), .text)
        XCTAssertEqual(BinaryContentDetector.classify(URL(fileURLWithPath: "/tmp/Makefile.inc")), .unknown)
        XCTAssertEqual(BinaryContentDetector.classify(URL(fileURLWithPath: "/tmp/notes.foo")), .unknown)
        XCTAssertFalse(BinaryContentDetector.looksBinary(Data()))
        XCTAssertFalse(BinaryContentDetector.looksBinary(Data("plain text\n".utf8)))
    }

    func testBinaryExtensionsAndKnownTypes() {
        for ext in BinaryContentDetector.binaryExtensions {
            XCTAssertEqual(
                BinaryContentDetector.classify(URL(fileURLWithPath: "/tmp/file.\(ext)")),
                .binary,
                ext
            )
        }
        XCTAssertEqual(BinaryContentDetector.classify(URL(fileURLWithPath: "/tmp/a.pdf")), .binary)
        XCTAssertEqual(BinaryContentDetector.classify(URL(fileURLWithPath: "/tmp/a.zip")), .binary)
        XCTAssertEqual(BinaryContentDetector.classify(URL(fileURLWithPath: "/tmp/a.txt")), .text)
        XCTAssertEqual(BinaryContentDetector.classify(URL(fileURLWithPath: "/tmp/a.json")), .text)
        XCTAssertEqual(BinaryContentDetector.classify(URL(fileURLWithPath: "/tmp/a.xml")), .text)
        XCTAssertEqual(BinaryContentDetector.classify(URL(fileURLWithPath: "/tmp/a.plist")), .text)
    }

    func testControlByteRuleAndMagicWinsOverText() {
        var mild = Data(repeating: 0x41, count: 100)
        mild[0] = 0x01
        XCTAssertFalse(BinaryContentDetector.looksBinary(mild))
        mild[1] = 0x02
        XCTAssertTrue(BinaryContentDetector.looksBinary(mild))
        XCTAssertTrue(BinaryContentDetector.looksBinary(Data("%PDF".utf8)))
        XCTAssertTrue(BinaryContentDetector.looksBinary(Data([0x4D, 0x5A, 0x20, 0x20])))
    }

    func testLoadBinarySetsContentKind() {
        let url = URL(fileURLWithPath: "/tmp/lib.dylib")
        let document = WorkbenchDocument.loadBinary(from: url)
        XCTAssertEqual(document.contentKind, .binary)
        XCTAssertEqual(document.displayName, "lib.dylib")
        XCTAssertEqual(document.text, "")
    }

    func testUnknownContentKindDecodesAsText() throws {
        let payload = """
        {"id":"\(UUID().uuidString)","documentID":"\(UUID().uuidString)","displayName":"A","text":"","isDirty":false,"selectedRangeLocation":0,"selectedRangeLength":0,"scrollOffsetX":0,"scrollOffsetY":3,"contentKind":"future-kind"}
        """.data(using: .utf8)!
        let snapshot = try JSONDecoder().decode(WorkbenchDocumentSnapshot.self, from: payload)
        XCTAssertEqual(snapshot.contentKind, .text)
        let missing = """
        {"id":"\(UUID().uuidString)","documentID":"\(UUID().uuidString)","displayName":"B","text":"hi","isDirty":false,"selectedRangeLocation":1,"selectedRangeLength":2,"scrollOffsetX":0,"scrollOffsetY":4}
        """.data(using: .utf8)!
        let older = try JSONDecoder().decode(WorkbenchDocumentSnapshot.self, from: missing)
        XCTAssertEqual(older.contentKind, .text)
        XCTAssertEqual(older.hexBookmarks, [])
        XCTAssertEqual(older.scrollOffsetY, 4)
    }
}
