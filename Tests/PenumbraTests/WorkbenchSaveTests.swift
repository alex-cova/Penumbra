import AppKit
import XCTest
@testable import Penumbra

@MainActor
final class WorkbenchSaveTests: XCTestCase {
    func testSaveFromLoadedDocumentMatchesFileAndClearsDirty() async throws {
        let url = try writeTempFile("hello save\n")
        let document = try await WorkbenchDocument.load(contentsOf: url)
        let prepared = try makePreparedView(from: document)
        document.isDirty = true
        let materializeBefore = prepared.stringView.materializeCount
        let result = try await document.save(from: prepared.textView)
        XCTAssertTrue(result.generationMatched)
        XCTAssertTrue(result.compacted)
        XCTAssertFalse(document.isDirty)
        XCTAssertEqual(try Data(contentsOf: url), Data("hello save\n".utf8))
        XCTAssertEqual(prepared.stringView.materializeCount, materializeBefore)
        XCTAssertEqual(prepared.stringView.pieceCount, 1)
        XCTAssertEqual(prepared.stringView.addBufferByteCount, 0)
        XCTAssertEqual(document.url, url)
    }

    func testProgressCallbackGenerationBumpLeavesDirty() async throws {
        let url = try writeTempFile(String(repeating: "generation-bump-\n", count: 8_000))
        let document = try await WorkbenchDocument.load(contentsOf: url)
        let prepared = try makePreparedView(from: document)
        document.isDirty = false
        let stringViewBox = StringViewBox(prepared.stringView)
        let bumpBox = FlagBox()
        let result = try await document.save(from: prepared.textView, progress: { written, _ in
            guard written > 0 else { return }
            bumpBox.lock.lock()
            let shouldBump = !bumpBox.flag
            bumpBox.flag = true
            bumpBox.lock.unlock()
            guard shouldBump else { return }
            stringViewBox.stringView.replaceText(in: NSRange(location: 0, length: 0), with: "!")
        })
        XCTAssertFalse(result.generationMatched)
        XCTAssertFalse(result.compacted)
        XCTAssertTrue(document.isDirty)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).hasPrefix("generation-bump-"))
        XCTAssertGreaterThan(prepared.stringView.pieceCount, 1)
    }

    func testFileBackedSaveWithoutViewThrowsBufferUnavailable() async throws {
        let url = try writeTempFile("no view\n")
        let document = try await WorkbenchDocument.load(contentsOf: url)
        document.pendingState = nil
        do {
            _ = try await document.save()
            XCTFail("expected bufferUnavailable")
        } catch DocumentWriteError.bufferUnavailable {
            // expected
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "no view\n")
    }

    func testUntitledSaveWritesTextAndUpdatesURL() async throws {
        let document = WorkbenchDocument(displayName: "Untitled", text: "hello untitled")
        let dest = try uniqueDest(named: "untitled.txt")
        let result = try await document.save(to: dest)
        XCTAssertFalse(result.compacted)
        XCTAssertTrue(result.generationMatched)
        XCTAssertFalse(document.isDirty)
        XCTAssertEqual(document.url, dest)
        XCTAssertEqual(document.displayName, "untitled.txt")
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "hello untitled")
        XCTAssertFalse(document.isFileBacked)
    }

    func testSaveAsUpdatesURL() async throws {
        let source = try writeTempFile("original body\n")
        let document = try await WorkbenchDocument.load(contentsOf: source)
        let prepared = try makePreparedView(from: document)
        let dest = try uniqueDest(named: "renamed.txt")
        let result = try await document.save(from: prepared.textView, to: dest)
        XCTAssertTrue(result.generationMatched)
        XCTAssertEqual(document.url, dest)
        XCTAssertEqual(document.displayName, "renamed.txt")
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "original body\n")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original body\n")
        XCTAssertTrue(document.isFileBacked)
    }

    func testCancelPublicTextViewWriteLeavesDestUnchanged() async throws {
        let dest = try uniqueDest(named: "cancel.txt")
        let original = "do-not-replace-me"
        try original.write(to: dest, atomically: true, encoding: .utf8)
        let source = try writeTempFile(String(repeating: "cancel-me-\n", count: 20_000))
        let state = try await TextViewState.load(contentsOf: source)
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.setState(state)
        let viewBox = TextViewBox(textView)
        let destBox = URLBox(dest)
        let box = TaskBox()
        let task = Task {
            try await viewBox.textView.write(to: destBox.url, progress: { written, _ in
                if written > 0 {
                    box.task?.cancel()
                }
            })
        }
        box.task = task
        do {
            _ = try await task.value
            XCTFail("expected cancelled")
        } catch DocumentWriteError.cancelled {
            // expected
        }
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), original)
        assertNoWriterTemps(in: dest.deletingLastPathComponent())
    }

    func testSetStateDuringWriteDoesNotCompactTheNewBuffer() async throws {
        let urlA = try writeTempFile(String(repeating: "file-a-\n", count: 8_000))
        let urlB = try writeTempFile("file B different\n")
        let stateA = try await TextViewState.load(contentsOf: urlA)
        let stateB = try await TextViewState.load(contentsOf: urlB)
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.setState(stateA)
        let viewBox = TextViewBox(textView)
        let stateBox = TextViewStateBox(stateB)
        let bumpBox = FlagBox()
        let dest = try uniqueDest(named: "a.txt")
        let result = try await textView.write(to: dest, progress: { written, _ in
            guard written > 0 else { return }
            bumpBox.lock.lock()
            let shouldSwap = !bumpBox.flag
            bumpBox.flag = true
            bumpBox.lock.unlock()
            guard shouldSwap else { return }
            DispatchQueue.main.sync {
                viewBox.textView.setState(stateBox.state)
            }
        })
        XCTAssertFalse(result.generationMatched)
        XCTAssertFalse(result.compacted)
        XCTAssertEqual(stateB.stringView.substring(in: NSRange(location: 0, length: 17)), "file B different\n")
        XCTAssertEqual(stateB.stringView.addBufferByteCount, 0)
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8).hasPrefix("file-a-"), true)
    }

    func testSaveDoesNotRebindRangeReaderAfterSetState() async throws {
        let urlA = try writeTempFile(String(repeating: "alpha-\n", count: 8_000))
        let urlB = try writeTempFile("beta document\n")
        let documentA = try await WorkbenchDocument.load(contentsOf: urlA)
        let documentB = try await WorkbenchDocument.load(contentsOf: urlB)
        let preparedA = try makePreparedView(from: documentA)
        let originalSlice = documentA.rangeReader?.substring(utf16Offset: 0, length: 7)
        XCTAssertEqual(originalSlice, "alpha-\n")
        let viewBox = TextViewBox(preparedA.textView)
        let stateBox = TextViewStateBox(documentB.pendingState!)
        let bumpBox = FlagBox()
        documentA.isDirty = false
        let result = try await documentA.save(from: preparedA.textView, progress: { written, _ in
            guard written > 0 else { return }
            bumpBox.lock.lock()
            let shouldSwap = !bumpBox.flag
            bumpBox.flag = true
            bumpBox.lock.unlock()
            guard shouldSwap else { return }
            DispatchQueue.main.sync {
                viewBox.textView.setState(stateBox.state)
            }
        })
        XCTAssertFalse(result.generationMatched)
        XCTAssertFalse(result.compacted)
        XCTAssertTrue(documentA.isDirty)
        XCTAssertEqual(documentA.rangeReader?.substring(utf16Offset: 0, length: 7), originalSlice)
        XCTAssertEqual(documentB.pendingState?.stringView.substring(in: NSRange(location: 0, length: 14)), "beta document\n")
    }

    func testCancelledQueuedWriteDoesNotAcquireLock() async throws {
        let source = try writeTempFile(String(repeating: "first-write-\n", count: 20_000))
        let state = try await TextViewState.load(contentsOf: source)
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.setState(state)
        let viewBox = TextViewBox(textView)
        let dest1 = try uniqueDest(named: "first.txt")
        let dest2 = try uniqueDest(named: "second.txt")
        try "keep-second".write(to: dest2, atomically: true, encoding: .utf8)
        let started = FlagBox()
        let first = Task {
            try await viewBox.textView.write(to: dest1, progress: { written, _ in
                if written > 0 {
                    started.lock.lock()
                    started.flag = true
                    started.lock.unlock()
                }
            })
        }
        while !started.flag {
            await Task.yield()
        }
        let second = Task {
            try await viewBox.textView.write(to: dest2)
        }
        second.cancel()
        do {
            _ = try await second.value
            XCTFail("expected cancelled")
        } catch DocumentWriteError.cancelled {
            // expected
        }
        let firstResult = try await first.value
        XCTAssertTrue(firstResult.generationMatched)
        XCTAssertEqual(try String(contentsOf: dest2, encoding: .utf8), "keep-second")
        assertNoWriterTemps(in: dest2.deletingLastPathComponent())
    }

    private func makePreparedView(from document: WorkbenchDocument) throws -> (textView: TextView, stringView: StringView) {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        if let state = document.pendingState {
            textView.setState(state)
            document.pendingState = nil
            return (textView, state.stringView)
        }
        textView.text = document.text
        return (textView, StringView(string: document.text))
    }

    private func writeTempFile(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try text.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func uniqueDest(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent(name)
    }

    private func assertNoWriterTemps(in directory: URL, file: StaticString = #filePath, line: UInt = #line) {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let leftovers = items.filter {
            $0.lastPathComponent.contains(".penumbra-") && $0.pathExtension == "tmp"
        }
        XCTAssertTrue(leftovers.isEmpty, "leftover temps: \(leftovers)", file: file, line: line)
    }
}

private final class TextViewBox: @unchecked Sendable {
    let textView: TextView
    init(_ textView: TextView) {
        self.textView = textView
    }
}

private final class StringViewBox: @unchecked Sendable {
    let stringView: StringView
    init(_ stringView: StringView) {
        self.stringView = stringView
    }
}

private final class FlagBox: @unchecked Sendable {
    let lock = NSLock()
    var flag = false
}

private final class TaskBox: @unchecked Sendable {
    var task: Task<DocumentWriteResult, Error>?
}

private final class URLBox: @unchecked Sendable {
    let url: URL
    init(_ url: URL) {
        self.url = url
    }
}

private final class TextViewStateBox: @unchecked Sendable {
    let state: TextViewState
    init(_ state: TextViewState) {
        self.state = state
    }
}
