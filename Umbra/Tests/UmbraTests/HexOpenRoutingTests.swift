import Foundation
import Penumbra
import XCTest
@testable import Umbra

/// Open routing through the shipped `loadDocument` path. The classifier tests cover the pure
/// function; these assert what a file actually becomes.
@MainActor
final class HexOpenRoutingTests: XCTestCase {
    private var directory: URL!
    private var workspace: IDEWorkspace!
    private let settings = IDEHexSettings.shared
    private var savedOpen = true
    private var savedSniff = true
    private var savedForceText: [String] = []
    private var savedForceHex: [String] = []

    override func setUp() async throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hex-route-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        savedOpen = settings.openBinaryAsHex
        savedSniff = settings.sniffUnknownFiles
        savedForceText = settings.forceTextExtensions
        savedForceHex = settings.forceHexExtensions
        settings.openBinaryAsHex = true
        settings.sniffUnknownFiles = true
        settings.forceTextExtensions = []
        settings.forceHexExtensions = []
        workspace = IDEWorkspace()
        workspace.bootstrap()
    }

    override func tearDown() async throws {
        settings.openBinaryAsHex = savedOpen
        settings.sniffUnknownFiles = savedSniff
        settings.forceTextExtensions = savedForceText
        settings.forceHexExtensions = savedForceHex
        workspace?.teardown()
        IDEWorkspace.isSessionPersistenceEnabled = true
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testKnownTextNamesOpenAsTextEvenWhenUTF8ContainsNUL() async throws {
        let nul = [UInt8](Data("ab\u{0}c".utf8))
        for name in ["LICENSE", "Makefile", "Dockerfile", ".gitignore", ".zshrc", "Notes.swift", "page.json", "note.xml", "info.plist", "readme.txt"] {
            let url = try write(name, nul)
            let document = try await workspace.loadDocument(from: url)
            XCTAssertEqual(document.contentKind, .text, name)
        }
        let makefileInc = try write("Makefile.inc", Array("all:\n\ttrue\n".utf8))
        try await expect(makefileInc, .text)
        let unknownText = try write("notes.foo", Array("plain text\n".utf8))
        try await expect(unknownText, .text)
        let empty = try write("empty.foo", [])
        try await expect(empty, .text)
    }

    func testKnownBinaryTypesOpenAsHexWithoutUsingTheirContents() async throws {
        let text = Array("hello\n".utf8)
        for ext in ["class", "jar", "o", "a", "dylib", "so", "wasm", "bin", "dat", "db", "sqlite", "ttf", "otf", "woff", "woff2", "pdf", "zip"] {
            let url = try write("file.\(ext)", text)
            try await expect(url, .binary, ext)
        }
    }

    func testSniffKeepsDecodableTextAndSendsMagicNULAndControlsToHex() async throws {
        let cases: [(String, [UInt8], WorkbenchDocumentContentKind)] = [
            ("utf8bom.foo", [0xEF, 0xBB, 0xBF, 0x61], .text),
            ("utf16.foo", [0xFF, 0xFE, 0x61, 0x00, 0x62, 0x00], .text),
            ("utf16be.foo", [0xFE, 0xFF, 0x00, 0x61, 0x00, 0x62], .text),
            ("utf32.foo", [0xFF, 0xFE, 0x00, 0x00, 0x61, 0x00, 0x00, 0x00], .text),
            ("utf32be.foo", [0x00, 0x00, 0xFE, 0xFF, 0x00, 0x00, 0x00, 0x61], .text),
            ("utf16raw.foo", [0x61, 0x00, 0x62, 0x00, 0x63, 0x00, 0x64, 0x00], .text),
            ("latin1.foo", [0x63, 0x61, 0x66, 0xE9], .text),
            ("elf.foo", [0x7F, 0x45, 0x4C, 0x46, 0x02, 0x01], .binary),
            ("png.foo", [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], .binary),
            ("nul.foo", [0x61, 0x62, 0x00, 0x63], .binary),
        ]
        for (name, bytes, expected) in cases {
            try await expect(try write(name, bytes), expected, name)
        }
        var mild = [UInt8](repeating: 0x41, count: 100)
        mild[0] = 0x01
        try await expect(try write("one-control.foo", mild), .text)
        mild[1] = 0x02
        try await expect(try write("two-controls.foo", mild), .binary)
    }

    func testUndecodableKnownTextOpensAsHexUnlessAnEncodingWasRequested() async throws {
        let bytes: [UInt8] = [0xFF, 0x41, 0x00, 0x42, 0x43, 0x44, 0x45, 0x46]
        let url = try write("broken.txt", bytes)
        try await expect(url, .binary)
        let utf8 = try XCTUnwrap(TextFileEncoding.named("utf8"))
        do {
            _ = try await workspace.loadDocument(from: url, encoding: utf8)
            XCTFail("an explicit encoding must report the error")
        } catch DocumentLoadError.invalidEncoding {
        }
        try await expect(url, .text, openAsText: true)
        let source = try write("Ok.swift", [0x61, 0x62, 0x00, 0x63])
        try await expect(source, .text)
    }

    func testForceListsAndSwitchesComeBeforeClassification() async throws {
        let binary = [UInt8](repeating: 0xFF, count: 16) + [0x00]
        settings.openBinaryAsHex = false
        let classFile = try write("Main.class", binary)
        do {
            _ = try await workspace.loadDocument(from: classFile)
            XCTFail("known binary with the hex switch off must refuse")
        } catch DocumentLoadError.invalidEncoding {
        }
        settings.openBinaryAsHex = true

        settings.sniffUnknownFiles = false
        // Sniffing is off, so a magic head is not consulted. Valid UTF-8 stays text.
        try await expect(try write("prog.foo", [0x7F, 0x45, 0x4C, 0x46]), .text)
        // Four bytes guess as UTF-16. Eight bytes fail UTF-8 and the UTF-16 guess, so the loader throws.
        let undecodable = try write("bad.foo", [0xFF, 0x41, 0x00, 0x42, 0x43, 0x44, 0x45, 0x46])
        do {
            _ = try await workspace.loadDocument(from: undecodable)
            XCTFail("an unknown file that cannot be decoded must not fall through to hex while sniffing is off")
        } catch DocumentLoadError.invalidEncoding {
        }
        try await expect(try write("plain.foo", Array("hello\n".utf8)), .text)
        settings.sniffUnknownFiles = true

        settings.forceTextExtensions = ["class"]
        try await expect(try write("Hello.class", Array("hello\n".utf8)), .text)
        do {
            _ = try await workspace.loadDocument(from: try write("Bad.class", binary))
            XCTFail("a forced text extension that cannot be decoded stays an encoding error")
        } catch DocumentLoadError.invalidEncoding {
        }
        settings.forceTextExtensions = []
        settings.forceHexExtensions = ["txt"]
        try await expect(try write("note.txt", Array("hello\n".utf8)), .binary)
    }

    func testImagesStayImagesAndPublicDataIsAnAlternateHandler() async throws {
        let png = try write("picture.png", [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        try await expect(png, .image)
        try await expect(png, .binary, openAsHex: true)

        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plist)
        let root = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let types = try XCTUnwrap(root["CFBundleDocumentTypes"] as? [[String: Any]])
        let dataType = try XCTUnwrap(types.first { ($0["LSItemContentTypes"] as? [String])?.contains("public.data") == true })
        XCTAssertEqual(dataType["LSHandlerRank"] as? String, "Alternate")
        XCTAssertEqual(dataType["CFBundleTypeRole"] as? String, "Viewer")
        XCTAssertFalse(types.contains { ($0["LSItemContentTypes"] as? [String])?.contains("public.data") == true && $0["LSHandlerRank"] as? String == "Default" })
    }

    private func write(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func expect(
        _ url: URL,
        _ expected: WorkbenchDocumentContentKind,
        _ note: String = "",
        openAsHex: Bool = false,
        openAsText: Bool = false
    ) async throws {
        let document = try await workspace.loadDocument(from: url, openAsHex: openAsHex, openAsText: openAsText)
        XCTAssertEqual(document.contentKind, expected, note.isEmpty ? url.lastPathComponent : note)
    }
}
