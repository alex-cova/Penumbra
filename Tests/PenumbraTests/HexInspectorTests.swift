import Foundation
import HexKit
import XCTest

final class HexInspectorTests: XCTestCase {
    func testIntegersFloatsTimesAndNotEnoughBytes() {
        let bytes: [UInt8] = [0x78, 0x56, 0x34, 0x12, 0x00, 0x00, 0x00, 0x00]
        let fields = Dictionary(uniqueKeysWithValues: HexInspector.fields(bytes: bytes, littleEndianFirst: true).map { ($0.name, $0) })
        XCTAssertEqual(fields["Int32 LE"]?.text, "305419896")
        XCTAssertEqual(fields["Int32 BE"]?.text, "2018915346")
        XCTAssertEqual(fields["UInt16 LE"]?.text, "22136")
        XCTAssertEqual(fields["Int8"]?.text, "120")
        XCTAssertEqual(fields["UUID"]?.available, false)
        XCTAssertEqual(fields["UUID"]?.text, HexInspector.notEnough)
        XCTAssertEqual(fields["Double LE"]?.available, true)
        let unix = fields["Unix time (s32) LE"]
        XCTAssertEqual(unix?.available, true)
        XCTAssertTrue(unix?.text.contains("1979") == true)

        let short = HexInspector.fields(bytes: [0xFF], littleEndianFirst: false)
        XCTAssertEqual(short.first { $0.name == "Int16 BE" }?.text, HexInspector.notEnough)
        XCTAssertEqual(short.first { $0.name == "Int8" }?.text, "-1")

        let floatBits = Float(1).bitPattern.littleEndian
        var floatBytes = [UInt8](repeating: 0, count: 4)
        withUnsafeBytes(of: floatBits) { raw in floatBytes = Array(raw) }
        let floatFields = HexInspector.fields(bytes: floatBytes, littleEndianFirst: true)
        XCTAssertEqual(floatFields.first { $0.name == "Float LE" }?.text, "1")
    }

    func testUUIDCharacterAndHashes() throws {
        let uuid = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        let tuple = uuid.uuid
        let bytes: [UInt8] = [
            tuple.0, tuple.1, tuple.2, tuple.3, tuple.4, tuple.5, tuple.6, tuple.7,
            tuple.8, tuple.9, tuple.10, tuple.11, tuple.12, tuple.13, tuple.14, tuple.15
        ]
        let fields = HexInspector.fields(bytes: bytes, littleEndianFirst: true)
        XCTAssertEqual(fields.first { $0.name == "UUID" }?.text, "00112233-4455-6677-8899-AABBCCDDEEFF")
        let character = HexInspector.fields(bytes: Array("A".utf8), littleEndianFirst: true)
        XCTAssertTrue(character.first { $0.name == "Character" }?.text.contains("U+41") == true)

        let source = MemoryByteSource(Array("abc".utf8))
        XCTAssertEqual(try HexDigest.md5(source, range: 0..<3), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(
            try HexDigest.sha256(source, range: 0..<3),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertFalse(try HexDigest.sha1(source, range: 0..<3).isEmpty)
    }

    func testEncodeWritesTheDisplayedValueBack() throws {
        let bytes: [UInt8] = [0x78, 0x56, 0x34, 0x12]
        let fields = HexInspector.fields(bytes: bytes, littleEndianFirst: true)
        let int32 = try XCTUnwrap(fields.first { $0.name == "Int32 LE" })
        let edit = try XCTUnwrap(int32.edit)
        XCTAssertEqual(HexInspector.encode(int32.text, edit: edit), bytes)
        XCTAssertEqual(
            HexInspector.encode("0x12345678", edit: HexInspectorEdit(kind: .unsignedInteger, width: 4, littleEndian: false)),
            [0x12, 0x34, 0x56, 0x78]
        )
        XCTAssertNil(HexInspector.encode("nope", edit: edit))
        XCTAssertNil(HexInspector.encode("", edit: edit))

        let oneByte = HexInspector.fields(bytes: [0xFF], littleEndianFirst: true)
        let signedByte = try XCTUnwrap(oneByte.first { $0.name == "Int8" })
        XCTAssertEqual(signedByte.text, "-1")
        XCTAssertEqual(HexInspector.encode("-1", edit: try XCTUnwrap(signedByte.edit)), [0xFF])
        XCTAssertNil(HexInspector.encode("128", edit: try XCTUnwrap(signedByte.edit)))
        XCTAssertNil(oneByte.first { $0.name == "Int16 LE" }?.edit)
        let unsigned = try XCTUnwrap(oneByte.first { $0.name == "UInt8" }?.edit)
        XCTAssertEqual(HexInspector.encode("255", edit: unsigned), [0xFF])

        var floatBytes = [UInt8](repeating: 0, count: 4)
        withUnsafeBytes(of: Float(1).bitPattern.littleEndian) { floatBytes = Array($0) }
        let floatFields = HexInspector.fields(bytes: floatBytes, littleEndianFirst: true)
        let floatLE = try XCTUnwrap(floatFields.first { $0.name == "Float LE" })
        XCTAssertEqual(floatLE.text, "1")
        XCTAssertEqual(HexInspector.encode(floatLE.text, edit: try XCTUnwrap(floatLE.edit)), floatBytes)
        XCTAssertNil(HexInspector.encode("1e40", edit: try XCTUnwrap(floatLE.edit)))
    }

    func testFormatLabels() {
        let machO: [UInt8] = [0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01]
        XCTAssertEqual(HexFormatDescriber.label(head: machO), "Mach-O 64-bit arm64")
        var elf = [UInt8](repeating: 0, count: 20)
        elf.replaceSubrange(0..<6, with: [0x7F, 0x45, 0x4C, 0x46, 0x02, 0x01])
        elf[18] = 183
        XCTAssertEqual(HexFormatDescriber.label(head: elf), "ELF 64-bit AArch64")
        var tail = [UInt8](repeating: 0, count: 22)
        tail.replaceSubrange(0..<4, with: [0x50, 0x4B, 0x05, 0x06])
        tail[10] = 12
        XCTAssertEqual(
            HexFormatDescriber.label(head: [0x50, 0x4B, 0x03, 0x04], tail: tail),
            "ZIP archive (12 entries)"
        )
        XCTAssertNil(HexFormatDescriber.label(head: [0x7F, 0x45, 0x4C]))
        XCTAssertNil(HexFormatDescriber.label(head: [0x4D]))
    }
}
