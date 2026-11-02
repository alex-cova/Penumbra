import AgentKit
import AppKit
import Foundation
import XCTest

@testable import Umbra

@MainActor
final class IDEAgentImageInputTests: XCTestCase {
    private func makeSettings() -> IDEAgentSettings {
        IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.images.\(UUID().uuidString)")!,
            keyStore: IDEAgentMemoryKeyStore())
    }

    private func makeConversation(settings: IDEAgentSettings) -> IDEAgentConversation {
        IDEAgentConversation(settings: settings, store: nil, clientFactory: { _ in MockLLMClient(turns: []) })
    }

    /// A small readable PNG on disk, as a screenshot drop would be.
    private func makePNGFile() throws -> URL {
        let size = NSSize(width: 64, height: 64)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let rep = try XCTUnwrap(NSBitmapImageRep(data: image.tiffRepresentation!))
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString).png")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testVisionFlagsFollowTheProvider() {
        let settings = makeSettings()
        let factory = settings.clientFactory()
        settings.provider = .anthropic
        XCTAssertTrue(factory.supportsImages(for: settings.currentChoice))
        settings.provider = .mlx
        XCTAssertFalse(factory.supportsImages(for: settings.currentChoice))
        settings.provider = .ollama
        XCTAssertFalse(factory.supportsImages(for: settings.currentChoice), "no model list means no vision claim")
    }

    func testAnImageDropWithAVisionModelBecomesAPendingChip() throws {
        let settings = makeSettings()
        settings.provider = .anthropic
        let conversation = makeConversation(settings: settings)
        let insertion = conversation.droppedFilesInsertion([try makePNGFile()])
        XCTAssertEqual(insertion, "")
        XCTAssertEqual(conversation.pendingImages.count, 1)
        XCTAssertEqual(conversation.pendingImages[0].mediaType, "image/png")
    }

    func testAnImageDropWithANonVisionModelKeepsTheMentionPathAndSaysWhy() throws {
        let settings = makeSettings()
        settings.provider = .mlx
        let conversation = makeConversation(settings: settings)
        let url = try makePNGFile()
        let insertion = conversation.droppedFilesInsertion([url])
        XCTAssertEqual(insertion, "", "no host means no project root for a mention, but nothing attaches either")
        XCTAssertTrue(conversation.pendingImages.isEmpty)
        let notice = try XCTUnwrap(conversation.entries.last(where: { $0.kind == .notice }))
        XCTAssertTrue(notice.text.contains("cannot see images"), "\(notice.text)")
    }

    func testPasteWithANonVisionModelIsRefused() {
        let settings = makeSettings()
        settings.provider = .mlx
        let conversation = makeConversation(settings: settings)
        XCTAssertFalse(conversation.pasteImage(Data([0x01, 0x02])))
        XCTAssertTrue(conversation.pendingImages.isEmpty)
    }
}
