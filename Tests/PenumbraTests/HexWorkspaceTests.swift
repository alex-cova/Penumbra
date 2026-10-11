import AppKit
import Darwin
import Foundation
import HexKit
import Penumbra
import XCTest
@testable import Umbra

/// The shipped hex session, canvas, and workspace open/save/close path.
@MainActor
final class HexWorkspaceTests: XCTestCase {
    private var directory: URL!
    private var workspace: IDEWorkspace!
    private let settings = IDEHexSettings.shared
    private var savedThreshold: Int64 = 0
    private var savedUppercase = true
    private var savedGroupSize = 8

    override func setUp() async throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hex-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        savedThreshold = settings.largeFileEditThreshold
        savedUppercase = settings.uppercaseDigits
        savedGroupSize = settings.groupSize
        settings.largeFileEditThreshold = 256 * 1024 * 1024
        settings.groupSize = 8
        workspace = IDEWorkspace()
        workspace.bootstrap()
    }

    override func tearDown() async throws {
        settings.largeFileEditThreshold = savedThreshold
        settings.uppercaseDigits = savedUppercase
        settings.groupSize = savedGroupSize
        workspace?.teardown()
        IDEWorkspace.isSessionPersistenceEnabled = true
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testSessionEditsSelectionSearchInspectorCopyAndBookmarks() async throws {
        var bytes = [UInt8](repeating: 0x11, count: 64)
        bytes.replaceSubrange(0..<4, with: [0x00, 0x01, 0x02, 0x03])
        let url = try write("sample.bin", bytes)
        let session = try await openHex(url)
        XCTAssertEqual(workspace.statusLanguage, "Hex")
        XCTAssertFalse(session.showSniffBanner)
        XCTAssertEqual(session.document.byte(at: 0), 0x00)

        session.click(byte: 2, pane: .hex(lowNibble: true))
        XCTAssertEqual(session.caret, 2)
        XCTAssertTrue(session.lowNibble)
        session.shiftClick(byte: 6)
        XCTAssertEqual(session.selection, 2..<6)
        session.selectGroup(at: 10)
        XCTAssertEqual(session.selection, 8..<16)
        session.selectAll()
        XCTAssertEqual(session.selection, 0..<64)
        session.click(byte: 0, pane: .hex(lowNibble: false))
        session.move(by: 1, extend: false)
        XCTAssertEqual(session.caret, 1)
        session.moveByGroup(direction: 1, extend: true)
        XCTAssertEqual(session.selection.count, 8)

        XCTAssertTrue(session.goTo("0x10"))
        XCTAssertEqual(session.caret, 16)
        XCTAssertTrue(session.goTo("+4"))
        XCTAssertEqual(session.caret, 20)
        XCTAssertTrue(session.goTo("-2"))
        XCTAssertEqual(session.caret, 18)
        XCTAssertTrue(session.goTo("end"))
        XCTAssertEqual(session.caret, 64)
        XCTAssertFalse(session.goTo("nope"))

        session.click(byte: 0, pane: .hex(lowNibble: false))
        XCTAssertTrue(session.typeNibble(0xA))
        XCTAssertTrue(session.typeNibble(0xB))
        XCTAssertEqual(session.document.byte(at: 0), 0xAB)
        XCTAssertTrue(session.typeNibble(0xC))
        XCTAssertTrue(session.typeNibble(0xD))
        XCTAssertEqual(session.document.byte(at: 1), 0xCD)
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.document.byte(at: 0), 0x00)
        XCTAssertEqual(session.document.byte(at: 1), 0x01)
        XCTAssertTrue(session.redo())
        XCTAssertEqual(session.document.bytes(in: 0..<2), [0xAB, 0xCD])

        session.toggleInsertMode()
        XCTAssertTrue(session.insertMode)
        session.click(byte: 2, pane: .hex(lowNibble: false))
        XCTAssertTrue(session.typeNibble(0xE))
        XCTAssertTrue(session.typeNibble(0xF))
        XCTAssertEqual(session.document.byte(at: 2), 0xEF)
        session.deleteBackward()
        XCTAssertEqual(session.document.byte(at: 2), 0x02)
        session.toggleInsertMode()
        let before = session.caret
        session.deleteBackward()
        XCTAssertEqual(session.caret, before - 1)
        session.deleteForward()
        XCTAssertEqual(session.document.count, 64)

        session.click(byte: 4, pane: .hex(lowNibble: false))
        session.shiftClick(byte: 8)
        session.fillSelection(with: 0x7F)
        XCTAssertEqual(session.document.bytes(in: 4..<8), [0x7F, 0x7F, 0x7F, 0x7F])
        session.zeroSelection()
        XCTAssertEqual(session.document.bytes(in: 4..<8), [0, 0, 0, 0])

        session.click(byte: 0, pane: .text)
        XCTAssertTrue(session.typeCharacter("Z"))
        XCTAssertEqual(session.document.byte(at: 0), UInt8(ascii: "Z"))
        session.click(byte: 1, pane: .text)
        let beforeLambda = session.document.byte(at: 1)
        XCTAssertFalse(session.typeCharacter("λ"))
        XCTAssertEqual(session.document.byte(at: 1), beforeLambda)

        session.pasteChoiceForTest = .truncate
        session.click(byte: 60, pane: .hex(lowNibble: false))
        XCTAssertTrue(session.paste("0x10, 0x20 0x30 0x40 0x50 0x60"))
        XCTAssertEqual(session.document.bytes(in: 60..<64), [0x10, 0x20, 0x30, 0x40])
        session.click(byte: 60, pane: .hex(lowNibble: false))
        session.shiftClick(byte: 62)
        XCTAssertTrue(session.copy(style: .hex).lowercased().contains("10"))

        session.goTo("8")
        session.toggleBookmark()
        session.publish(to: try XCTUnwrap(workspace.workbench.activePane.selectedDocument))
        XCTAssertEqual(workspace.workbench.activePane.selectedDocument?.hexBookmarks, [8])

        let fields = session.inspectorFields()
        XCTAssertTrue(fields.contains { $0.name == "Int32 LE" })
        XCTAssertTrue(fields.contains { $0.name == "Int32 BE" })
        session.goTo("60")
        session.shiftClick(byte: 64)
        let short = session.inspectorFields()
        XCTAssertTrue(short.contains { $0.text == "not enough bytes" })
        session.selectAll()
        XCTAssertNotNil(session.selectionLengthText())
        let hashed = try await session.hashSelection()
        let hashes = try XCTUnwrap(hashed)
        XCTAssertEqual(hashes.md5.count, 32)
        XCTAssertEqual(hashes.sha1.count, 40)
        XCTAssertEqual(hashes.sha256.count, 64)

        session.findMode = .hex
        session.findText = "11"
        session.updateFind()
        try await waitUntil { !session.findRunning }
        XCTAssertFalse(session.matches.isEmpty)
        session.closeFindBar()
        XCTAssertFalse(session.findBarVisible)

        session.click(byte: 4, pane: .hex(lowNibble: false))
        session.findText = "00"
        session.beginFind()
        session.updateFind()
        try await waitUntil { !session.findRunning }
        let match = try XCTUnwrap(session.matches.first)
        session.replaceCurrent(with: "AB")
        XCTAssertEqual(session.document.byte(at: match.lowerBound), 0xAB)

        let opened = FileByteSource.openDescriptorCount
        await session.compareWithDisk()
        try await waitUntil { session.diskDifferences != nil }
        XCTAssertFalse(session.diskDifferences?.isEmpty ?? true)
        XCTAssertEqual(FileByteSource.openDescriptorCount, opened)

        XCTAssertTrue(session.accessibilitySummary.contains("Offset"))
        XCTAssertTrue(session.accessibilitySummary.contains("byte"))
        let canvas = IDEHexCanvasView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        canvas.session = session
        canvas.layoutSubtreeIfNeeded()
        let visible = canvas.visibleByteRange()
        XCTAssertLessThan(visible.count, 120 * 64)
        XCTAssertLessThanOrEqual(visible.upperBound, session.document.count)
        XCTAssertNotNil(canvas.hitForTesting(at: NSPoint(x: 120, y: 40)))
        XCTAssertTrue(canvas.accessibilityLabel()?.contains("Offset") == true)
    }

    func testSaveExternalChangeReopenAndLargeFileGate() async throws {
        let url = try write("edit.bin", [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        let session = try await openHex(url)
        session.click(byte: 0, pane: .hex(lowNibble: false))
        XCTAssertTrue(session.typeNibble(0x9))
        XCTAssertTrue(session.typeNibble(0x9))
        let document = try XCTUnwrap(workspace.workbench.activePane.selectedDocument)
        XCTAssertTrue(document.isDirty)
        XCTAssertTrue(workspace.unsavedPromptText().contains("edit.bin"))
        XCTAssertTrue(workspace.unsavedPromptText().contains("changed bytes"))
        let quit = IDEWindowRegistry.quitPromptText(unsavedPerWindow: [workspace.unsavedDocumentCount], details: workspace.unsavedChangeLines().filter { $0.contains("changed bytes") })
        XCTAssertTrue(quit?.contains("edit.bin") == true)
        XCTAssertEqual(
            IDEWindowRegistry.quitPromptText(unsavedPerWindow: [1]),
            "1 open editor has unsaved changes that will be lost."
        )

        let savedDocument = await workspace.saveHexDocument(document)
        XCTAssertTrue(savedDocument)
        let saved = try Data(contentsOf: url)
        XCTAssertEqual(saved.first, 0x99)
        XCTAssertFalse(document.isDirty)
        let savedMode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(savedMode, mode)

        try Data([0x10, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]).write(to: url)
        workspace.noteExternalChange(of: [url.path])
        XCTAssertEqual(session.document.byte(at: 0), 0x10)

        session.click(byte: 1, pane: .hex(lowNibble: false))
        XCTAssertTrue(session.typeNibble(0x4))
        XCTAssertTrue(session.typeNibble(0x4))
        try Data([0x10, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x09]).write(to: url)
        workspace.noteExternalChange(of: [url.path])
        XCTAssertTrue(session.externalChange)
        session.keepMine()
        XCTAssertTrue(session.saveMustOverwriteDisk)
        XCTAssertFalse(session.externalChange)

        let textURL = try write("note.txt", Array("Hello".utf8))
        await workspace.openDocument(from: textURL)
        let textDocument = try XCTUnwrap(workspace.workbench.activePane.selectedDocument)
        XCTAssertEqual(textDocument.contentKind, .text)
        let host = workspace.host(for: workspace.workbench.activePaneID)
        host.textView.text = "Hello!"
        textDocument.isDirty = true
        await workspace.reopenAsHex(textDocument)
        let hexAgain = try XCTUnwrap(workspace.activeHexSession())
        XCTAssertEqual(hexAgain.document.bytes(in: 0..<6), Array("Hello!".utf8))
        XCTAssertEqual(textDocument.contentKind, .binary)
        await workspace.reopenAsText(textDocument)
        XCTAssertEqual(textDocument.contentKind, .text)
        XCTAssertTrue(workspace.sourceText(for: textDocument).contains("Hello!"))

        settings.largeFileEditThreshold = 4
        let big = try write("wide.dat", [0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
        let gated = try await openHex(big)
        XCTAssertTrue(gated.readOnly)
        XCTAssertFalse(gated.typeNibble(1))
        gated.makeEditable(confirmed: true)
        XCTAssertFalse(gated.readOnly)
        XCTAssertTrue(gated.typeNibble(0xA))
        XCTAssertTrue(gated.typeNibble(0xA))
        XCTAssertEqual(gated.document.byte(at: 0), 0xAA)
    }

    func testRestoreKeepsScrollSelectionAndBookmarksAndSkipsDiff() async throws {
        let url = try write("restore.bin", [UInt8](repeating: 0x22, count: 128))
        let session = try await openHex(url)
        XCTAssertTrue(session.goTo("40"))
        session.topRow = 2
        session.toggleBookmark()
        session.publish(to: try XCTUnwrap(workspace.workbench.activePane.selectedDocument))
        let state = workspace.workbench.makeRestorationState()
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(EditorRestorationState.self, from: data)
        let snapshots = documents(in: decoded.layout)
        let binary = try XCTUnwrap(snapshots.first { $0.contentKind == .binary })
        XCTAssertEqual(binary.hexBookmarks, [40])
        XCTAssertEqual(binary.selectedRangeLocation, 40)
        XCTAssertEqual(binary.scrollOffsetY, CGFloat(2))
        let unknownKind = try JSONDecoder().decode(WorkbenchDocumentContentKind.self, from: Data("\"not-a-kind\"".utf8))
        XCTAssertEqual(unknownKind, .text)
        XCTAssertFalse(snapshots.contains { $0.contentKind == .diff || $0.contentKind == .diagram })

        let snapshot = IDEPreferences.shared.snapshot()
        settings.uppercaseDigits.toggle()
        let changed = settings.uppercaseDigits
        IDEPreferences.shared.restore(from: snapshot)
        XCTAssertEqual(settings.uppercaseDigits, changed)

        XCTAssertFalse(workspace.canRunMarkdownWithAgent)
        XCTAssertFalse(workspace.agentInsertAtCaret("nope"))
    }

    func testRowMappingScrollerChromeAndClose() async throws {
        func rows(for count: Int) -> Int64 {
            let document = HexDocument(bytes: [UInt8](repeating: 0x2A, count: count))
            let session = IDEHexSession(documentID: UUID(), document: document, fileURL: nil)
            session.useFixedBytesPerRow(16)
            return session.rowCount
        }
        XCTAssertEqual(rows(for: 0), 0)
        XCTAssertEqual(rows(for: 1), 1)
        XCTAssertEqual(rows(for: 15), 1)
        XCTAssertEqual(rows(for: 16), 1)
        XCTAssertEqual(rows(for: 17), 2)

        let hugeURL = directory.appendingPathComponent("huge.bin")
        let fd = Darwin.open(hugeURL.path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0)
        let huge = Int64(Int32.max) + 1
        XCTAssertEqual(ftruncate(fd, off_t(huge)), 0)
        Darwin.close(fd)
        let source = try FileByteSource(url: hugeURL)
        let session = IDEHexSession(documentID: UUID(), document: HexDocument(source: source), fileURL: hugeURL)
        session.useFixedBytesPerRow(16)
        XCTAssertEqual(session.bytesPerRow, 16)
        XCTAssertEqual(session.rowCount, (huge + 15) / 16)
        let canvas = IDEHexCanvasView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.session = session
        window.layoutIfNeeded()
        canvas.needsDisplay = true
        window.displayIfNeeded()
        let scroller = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSScroller }.first)
        XCTAssertLessThan(scroller.knobProportion, 0.01)
        XCTAssertLessThan(canvas.visibleByteRange().count, 120 * 64)
        XCTAssertLessThanOrEqual(source.cachedPageCount, 8)
        let fourGBRows = HexLayout.rowCount(byteCount: 4 << 30, bytesPerRow: 16)
        XCTAssertEqual(HexScrollerMap.topRow(fraction: 1, visibleRows: 40, totalRows: fourGBRows), fourGBRows - 40)
        XCTAssertNotNil(canvas.hitForTesting(at: NSPoint(x: 140, y: 48)))
        session.close()

        let module = IDEHexModule()
        XCTAssertTrue(module.toolbarItems(for: workspace).isEmpty)
        XCTAssertTrue(module.statusItems(for: workspace).isEmpty)
        XCTAssertTrue(module.commands(for: workspace).isEmpty)
        let sample = try write("chrome.bin", [0x01, 0x02, 0x03, 0x04])
        _ = try await openHex(sample)
        XCTAssertEqual(workspace.statusLanguage, "Hex")
        XCTAssertTrue(module.toolbarItems(for: workspace).contains { $0.id == "hex.insert" })
        XCTAssertTrue(module.statusItems(for: workspace).contains { $0.id == "hex.offset" })
        XCTAssertTrue(module.commands(for: workspace).contains { $0.id == IDEHexModule.goToOffset })
        XCTAssertFalse(module.commands(for: workspace).contains { $0.id == IDEHexModule.openAsHex })
        let note = try write("chrome.txt", Array("hello\n".utf8))
        await workspace.openDocument(from: note)
        XCTAssertEqual(workspace.workbench.activePane.selectedDocument?.contentKind, .text)
        XCTAssertNotEqual(workspace.statusLanguage, "Hex")
        XCTAssertFalse(module.toolbarItems(for: workspace).contains { $0.id == "hex.insert" })
        XCTAssertTrue(module.commands(for: workspace).contains { $0.id == IDEHexModule.openAsHex })
        XCTAssertFalse(module.viewMenuItems(for: workspace).contains { $0.id == "hex.inspector" })

        let opened = FileByteSource.openDescriptorCount
        weak var weakWorkspace: IDEWorkspace?
        do {
            let held = IDEWorkspace()
            weakWorkspace = held
            held.bootstrap()
            await held.openDocument(from: sample)
            XCTAssertNotNil(held.activeHexSession())
            held.teardown()
        }
        for _ in 0..<20 where weakWorkspace != nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(weakWorkspace)
        XCTAssertLessThanOrEqual(FileByteSource.openDescriptorCount, opened)
    }

    func testViewportReadOfASparseFileStaysInsideThePageCache() throws {
        let url = directory.appendingPathComponent("sparse.bin")
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }
        let size = Int64(32 * 1024 * 1024)
        XCTAssertEqual(ftruncate(fd, off_t(size)), 0)
        let source = try FileByteSource(url: url)
        defer { source.close() }
        let document = HexDocument(source: source)
        let session = IDEHexSession(documentID: UUID(), document: document, fileURL: url, openedBySniff: false)
        let canvas = IDEHexCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.session = session
        window.layoutIfNeeded()
        canvas.needsDisplay = true
        window.displayIfNeeded()
        let visible = canvas.visibleByteRange()
        var buffer = [UInt8](repeating: 0, count: Int(visible.count))
        if !buffer.isEmpty {
            _ = buffer.withUnsafeMutableBytes { document.read(visible, into: $0) }
        }
        XCTAssertEqual(document.count, size)
        XCTAssertLessThan(visible.count, 120 * 64)
        XCTAssertLessThanOrEqual(source.cachedPageCount, 4)
        XCTAssertTrue(session.formatLabel == nil)
        let elf = try FileByteSource(url: try write("a.elf", [0x7F, 0x45, 0x4C, 0x46, 0x02, 0x01, 0x01, 0x00]))
        defer { elf.close() }
        let elfDocument = HexDocument(source: elf)
        let elfSession = IDEHexSession(documentID: UUID(), document: elfDocument, fileURL: url, openedBySniff: true)
        XCTAssertTrue(elfSession.formatLabel?.contains("ELF") == true)
        XCTAssertTrue(elfSession.showSniffBanner)
    }

    func testGoToEndAndPageKeysKeepTheCaretInTheViewport() async throws {
        var bytes = [UInt8](repeating: 0x5A, count: 4096)
        bytes[4094] = 0xEE
        bytes[4095] = 0xEF
        let url = try write("tall.bin", bytes)
        let session = try await openHex(url)
        session.useFixedBytesPerRow(16)
        let host = workspace.host(for: workspace.workbench.activePaneID)
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 140)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        var found: IDEHexCanvasView?
        try await waitUntil {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            found = findCanvas(in: host)
            found?.layoutSubtreeIfNeeded()
            return found != nil && session.visibleRowCount > 1 && session.rowCount > session.visibleRowCount
        }
        let canvas = try XCTUnwrap(found)
        canvas.layoutSubtreeIfNeeded()
        let visible = session.visibleRowCount
        XCTAssertEqual(session.topRow, 0)

        XCTAssertTrue(session.goTo("end"))
        XCTAssertGreaterThan(session.topRow, 0)
        assertCaretRowVisible(session, rows: visible)

        XCTAssertTrue(session.goTo("0"))
        XCTAssertEqual(session.caret, 0)
        XCTAssertEqual(session.topRow, 0)

        canvas.layoutSubtreeIfNeeded()
        let pageRows = session.visibleRowCount
        let width = Int64(session.bytesPerRow)
        canvas.keyDown(with: try keyDown(121, in: window))
        XCTAssertEqual(session.caret, pageRows * width)
        XCTAssertGreaterThan(session.topRow, 0)
        assertCaretRowVisible(session, rows: pageRows)
        let pagedCaret = session.caret
        let pagedTop = session.topRow

        canvas.keyDown(with: try keyDown(116, in: window))
        XCTAssertLessThan(session.caret, pagedCaret)
        XCTAssertLessThan(session.topRow, pagedTop)
        XCTAssertEqual(session.caret, 0)
        assertCaretRowVisible(session, rows: pageRows)

        XCTAssertTrue(session.goTo("0"))
        canvas.layoutSubtreeIfNeeded()
        let arrowRows = session.visibleRowCount
        for _ in 0..<Int(arrowRows) {
            canvas.keyDown(with: try keyDown(125, in: window))
        }
        XCTAssertGreaterThan(session.topRow, 0)
        assertCaretRowVisible(session, rows: arrowRows)

        XCTAssertTrue(session.goTo("0"))
        XCTAssertEqual(session.topRow, 0)
        session.findMode = .hex
        session.findText = "EE"
        session.updateFind()
        try await waitUntil { !session.findRunning && session.matchIndex != nil }
        XCTAssertEqual(session.selection.lowerBound, 4094)
        XCTAssertGreaterThan(session.topRow, 0)
        assertCaretRowVisible(session, rows: session.visibleRowCount)
    }

    func testSaveKeepsEditsMadeDuringTheWriteAndShowsProgress() async throws {
        let url = try write("race.bin", [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        let session = try await openHex(url)
        let document = try XCTUnwrap(workspace.workbench.activePane.selectedDocument)
        session.toggleInsertMode()
        session.click(byte: 0, pane: .hex(lowNibble: false))
        XCTAssertTrue(session.typeNibble(0xA))
        XCTAssertTrue(session.typeNibble(0xA))
        XCTAssertEqual(session.document.bytes(in: 0..<3), [0xAA, 0x01, 0x02])
        session.toggleInsertMode()

        let gate = SaveGate()
        session.saveProgressHook = { written, total in
            if gate.paused { return }
            gate.paused = true
            gate.mark(written: written, total: total)
            gate.release.wait()
        }
        defer {
            session.saveProgressHook = nil
            gate.release.signal()
        }
        let task = Task { await workspace.saveHexDocument(document) }
        try await waitUntil { gate.snapshot().started }
        let reported = gate.snapshot()
        try await waitUntil {
            session.saveProgress?.written == reported.written && session.saveProgress?.total == reported.total
        }
        XCTAssertGreaterThan(reported.written, 0)
        XCTAssertLessThanOrEqual(reported.written, reported.total)
        XCTAssertEqual(reported.total, session.document.count)
        let progress = "Saving \(reported.written) / \(reported.total)"
        XCTAssertEqual(session.saveProgressText, progress)
        XCTAssertTrue(session.accessibilitySummary.contains(progress))
        XCTAssertTrue(IDEHexModule().statusItems(for: workspace).contains { $0.id == "hex.save" })

        let viewer = IDEHexViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let window = NSWindow(contentRect: viewer.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = viewer
        viewer.show(session)
        window.layoutIfNeeded()
        viewer.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        window.displayIfNeeded()
        var visited: Set<ObjectIdentifier> = []
        let labels = accessibilityStrings(from: viewer, visited: &visited)
        XCTAssertTrue(labels.contains { $0.contains(progress) }, labels.joined(separator: " | "))

        let canvas = IDEHexCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        canvas.session = session
        XCTAssertTrue(canvas.accessibilityLabel()?.contains(progress) == true)

        session.click(byte: 2, pane: .hex(lowNibble: false))
        XCTAssertTrue(session.typeNibble(0xB))
        XCTAssertTrue(session.typeNibble(0xB))
        XCTAssertEqual(session.document.byte(at: 2), 0xBB)

        gate.release.signal()
        let saved = await task.value
        XCTAssertTrue(saved)
        XCTAssertNil(session.saveProgress)
        XCTAssertEqual(session.document.bytes(in: 0..<4), [0xAA, 0x01, 0xBB, 0x03])
        XCTAssertTrue(session.isModified)
        XCTAssertTrue(document.isDirty)
        XCTAssertFalse(IDEHexModule().statusItems(for: workspace).contains { $0.id == "hex.save" })
        XCTAssertEqual([UInt8](try Data(contentsOf: url)), [0xAA, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])

        let again = await workspace.saveHexDocument(document)
        XCTAssertTrue(again)
        XCTAssertFalse(session.isModified)
        XCTAssertFalse(document.isDirty)
        XCTAssertEqual([UInt8](try Data(contentsOf: url)), [0xAA, 0x01, 0xBB, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
    }

    /// A non-coalesced keystroke at the undo limit drops the oldest step, so the snapshot log is
    /// no longer a prefix. The save must keep that step's bytes and the keystroke, and stay dirty.
    func testSaveKeepsBytesWhenUndoLimitDropsTheOldestEdit() async throws {
        let limit = HexUndoStack.limit
        let keystroke = Int64(limit) * 2 + 4
        let url = try write("limit.bin", [UInt8](repeating: 0, count: limit * 2 + 16))
        let session = try await openHex(url)
        let document = try XCTUnwrap(workspace.workbench.activePane.selectedDocument)
        XCTAssertFalse(session.insertMode)

        let refresh = session.onChange
        session.onChange = nil
        var restored = false
        defer {
            if !restored { session.onChange = refresh }
        }
        var wrote = true
        for index in 0..<limit {
            session.click(byte: Int64(index) * 2, pane: .hex(lowNibble: false))
            wrote = session.typeNibble(0x1) && wrote
            wrote = session.typeNibble(0x1) && wrote
        }
        session.onChange = refresh
        restored = true
        XCTAssertTrue(wrote)
        XCTAssertEqual(session.document.byte(at: 0), 0x11)
        XCTAssertEqual(session.document.byte(at: 1), 0x00)
        XCTAssertEqual(session.document.byte(at: Int64(limit - 1) * 2), 0x11)

        let gate = SaveGate()
        session.saveProgressHook = { written, total in
            if gate.paused { return }
            gate.paused = true
            gate.mark(written: written, total: total)
            gate.release.wait()
        }
        defer {
            session.saveProgressHook = nil
            gate.release.signal()
        }
        let task = Task { await workspace.saveHexDocument(document) }
        try await waitUntil { gate.snapshot().started }

        session.click(byte: keystroke, pane: .hex(lowNibble: false))
        XCTAssertTrue(session.typeNibble(0xA))
        XCTAssertTrue(session.typeNibble(0xB))
        XCTAssertEqual(session.document.byte(at: keystroke), 0xAB)

        gate.release.signal()
        let saved = await task.value
        XCTAssertTrue(saved)
        XCTAssertEqual(session.document.byte(at: 0), 0x11)
        XCTAssertEqual(session.document.byte(at: 1), 0x00)
        XCTAssertEqual(session.document.byte(at: keystroke), 0xAB)
        XCTAssertTrue(session.isModified)
        XCTAssertTrue(document.isDirty)
        var preimage = [UInt8](repeating: 0xFF, count: 1)
        let copied = try preimage.withUnsafeMutableBytes { buffer in
            try session.document.original.read(0..<1, into: buffer)
        }
        XCTAssertEqual(copied, 1)
        XCTAssertEqual(preimage[0], 0)
        let written = try Data(contentsOf: url)
        XCTAssertEqual(written[0], 0x11)
        XCTAssertEqual(written[Int(keystroke)], 0x00)

        let again = await workspace.saveHexDocument(document)
        XCTAssertTrue(again)
        XCTAssertFalse(session.isModified)
        XCTAssertFalse(document.isDirty)
        let rewritten = try Data(contentsOf: url)
        XCTAssertEqual(rewritten[0], 0x11)
        XCTAssertEqual(rewritten[1], 0x00)
        XCTAssertEqual(rewritten[Int(keystroke)], 0xAB)
        XCTAssertEqual(session.document.byte(at: 0), 0x11)
        XCTAssertEqual(session.document.byte(at: keystroke), 0xAB)
    }

    private func assertCaretRowVisible(_ session: IDEHexSession, rows: Int64, file: StaticString = #filePath, line: UInt = #line) {
        let row = session.caret / Int64(max(1, session.bytesPerRow))
        XCTAssertGreaterThanOrEqual(row, session.topRow, "row \(row) top \(session.topRow)", file: file, line: line)
        XCTAssertLessThan(row, session.topRow + rows, "row \(row) window \(rows)", file: file, line: line)
    }

    private func findCanvas(in view: NSView) -> IDEHexCanvasView? {
        if let canvas = view as? IDEHexCanvasView { return canvas }
        for subview in view.subviews {
            if let canvas = findCanvas(in: subview) { return canvas }
        }
        return nil
    }

    private func keyDown(_ code: UInt16, in window: NSWindow) throws -> NSEvent {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: code
        )
        return try XCTUnwrap(event)
    }

    private func accessibilityStrings(from object: AnyObject, depth: Int = 0, visited: inout Set<ObjectIdentifier>) -> [String] {
        if depth > 10 || visited.contains(ObjectIdentifier(object)) { return [] }
        visited.insert(ObjectIdentifier(object))
        var found: [String] = []
        let label: String?
        let value: Any?
        let children: [Any]?
        if let view = object as? NSView {
            label = view.accessibilityLabel()
            value = view.accessibilityValue()
            children = view.accessibilityChildren()
            for subview in view.subviews {
                found.append(contentsOf: accessibilityStrings(from: subview, depth: depth + 1, visited: &visited))
            }
        } else if let element = object as? NSAccessibilityElement {
            label = element.accessibilityLabel()
            value = element.accessibilityValue()
            children = element.accessibilityChildren()
        } else {
            label = nil
            value = nil
            children = nil
        }
        if let label, !label.isEmpty { found.append(label) }
        if let value = value as? String, !value.isEmpty { found.append(value) }
        if let field = object as? NSTextField, !field.stringValue.isEmpty { found.append(field.stringValue) }
        for case let child as AnyObject in children ?? [] {
            found.append(contentsOf: accessibilityStrings(from: child, depth: depth + 1, visited: &visited))
        }
        return found
    }

    private func documents(in layout: EditorLayoutSnapshot) -> [WorkbenchDocumentSnapshot] {
        switch layout {
        case .pane(let pane):
            return pane.documents
        case .vertical(let split), .horizontal(let split):
            return split.children.flatMap { documents(in: $0) }
        }
    }

    private func openHex(_ url: URL) async throws -> IDEHexSession {
        await workspace.openDocument(from: url)
        let session = try XCTUnwrap(workspace.activeHexSession())
        XCTAssertEqual(workspace.workbench.activePane.selectedDocument?.contentKind, .binary)
        return session
    }

    private func write(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition())
    }
}

private final class SaveGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var written: Int64 = 0
    private var total: Int64 = 0
    private var didStart = false
    var paused = false

    func mark(written: Int64, total: Int64) {
        lock.lock()
        self.written = written
        self.total = total
        didStart = true
        lock.unlock()
    }

    func snapshot() -> (started: Bool, written: Int64, total: Int64) {
        lock.lock()
        defer { lock.unlock() }
        return (didStart, written, total)
    }
}
