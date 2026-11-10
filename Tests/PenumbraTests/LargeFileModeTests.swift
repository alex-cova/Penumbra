import AppKit
import PenumbraLanguages
import SwiftIntelligence
import XCTest
@testable import Penumbra

/// F25: file size picks a tier; a degraded file opens as plain text, a read-only one cannot be
/// edited, and the index says which files it skipped for size.
@MainActor
final class LargeFileModeTests: XCTestCase {
    nonisolated(unsafe) private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LargeFileMode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String, bytes: Int) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let line = "let value = compute(items) // padding\n"
        var text = ""
        while text.utf8.count < bytes { text += line }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Policy

    func testStandardTiersAre50And500Megabytes() {
        let policy = LargeFilePolicy.standard
        XCTAssertEqual(policy.tier(forByteCount: 0), .normal)
        XCTAssertEqual(policy.tier(forByteCount: 50 * 1_048_576 - 1), .normal)
        XCTAssertEqual(policy.tier(forByteCount: 50 * 1_048_576), .degraded)
        XCTAssertEqual(policy.tier(forByteCount: 500 * 1_048_576 - 1), .degraded)
        XCTAssertEqual(policy.tier(forByteCount: 500 * 1_048_576), .readOnly)
        XCTAssertEqual(LargeFilePolicy.disabled.tier(forByteCount: .max - 1), .normal, "enable anyway")
    }

    func testTheReadOnlyTierNeverStartsBelowTheDegradedOne() {
        let policy = LargeFilePolicy(degradeBytes: 100, readOnlyBytes: 10)
        XCTAssertEqual(policy.tier(forByteCount: 50), .normal)
        XCTAssertEqual(policy.tier(forByteCount: 100), .readOnly)
    }

    func testTheNoticeNamesWhatIsOff() {
        let degraded = LargeFileNotice(tier: .degraded, byteCount: 120 * 1_048_576)
        XCTAssertEqual(degraded.disabledFeatures, [.syntaxHighlighting, .folding, .intelligence])
        XCTAssertTrue(degraded.message.contains("syntax highlighting"), degraded.message)
        XCTAssertTrue(degraded.message.contains("code folding"), degraded.message)
        XCTAssertFalse(degraded.message.contains("read-only"), degraded.message)
        let readOnly = LargeFileNotice(tier: .readOnly, byteCount: 600 * 1_048_576)
        XCTAssertTrue(readOnly.disabledFeatures.contains(.editing))
        XCTAssertTrue(readOnly.message.contains("read-only"), readOnly.message)
    }

    // MARK: - Open

    func testADegradedFileOpensWithoutALanguageAndANormalOneKeepsIt() async throws {
        let policy = LargeFilePolicy(degradeBytes: 2_000, readOnlyBytes: 20_000)
        let language = TreeSitterLanguage.bundled(forIdentifier: "swift")
        let small = try await WorkbenchDocument.load(
            contentsOf: write("small.swift", bytes: 500), language: language, languageIdentifier: "swift", largeFilePolicy: policy
        )
        XCTAssertNil(small.largeFileNotice)
        XCTAssertNotNil(small.language)

        let big = try await WorkbenchDocument.load(
            contentsOf: write("big.swift", bytes: 5_000), language: language, languageIdentifier: "swift", largeFilePolicy: policy
        )
        XCTAssertEqual(big.largeFileNotice?.tier, .degraded)
        XCTAssertNil(big.language, "no tree-sitter language: no parse, no highlight, no fold scan")
        XCTAssertEqual(big.languageIdentifier, "swift", "the host still knows what the file is")

        let huge = try await WorkbenchDocument.load(
            contentsOf: write("huge.swift", bytes: 30_000), language: language, languageIdentifier: "swift", largeFilePolicy: policy
        )
        XCTAssertEqual(huge.largeFileNotice?.tier, .readOnly)

        let enabled = try await WorkbenchDocument.load(
            contentsOf: write("again.swift", bytes: 30_000), language: language, languageIdentifier: "swift", largeFilePolicy: .disabled
        )
        XCTAssertNil(enabled.largeFileNotice, "enable anyway")
        XCTAssertNotNil(enabled.language)
    }

    /// The shipped thresholds on a real file: 52 MB is over the 50 MB line and opens quickly as plain text.
    func testTheStandardPolicyDegradesARealFileOver50Megabytes() async throws {
        let url = directory.appendingPathComponent("generated.swift")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        let chunk = Data(String(repeating: "let value = compute(items) // padding padding\n", count: 22_000).utf8) // ~1 MB
        for _ in 0..<52 { try handle.write(contentsOf: chunk) }
        try handle.close()

        let start = CFAbsoluteTimeGetCurrent()
        let document = try await WorkbenchDocument.load(
            contentsOf: url, language: TreeSitterLanguage.bundled(forIdentifier: "swift"), languageIdentifier: "swift",
            largeFilePolicy: .standard
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertEqual(document.largeFileNotice?.tier, .degraded)
        XCTAssertNil(document.language)
        XCTAssertTrue(document.isFileBacked)
        XCTAssertLessThan(elapsed, 5, "opening 52 MB as plain text took \(elapsed)s")
    }

    func testHostsThatHaveNotOptedInKeepFullServiceOnAnyFile() async throws {
        let document = try await WorkbenchDocument.load(
            contentsOf: write("plain.swift", bytes: 30_000), language: TreeSitterLanguage.bundled(forIdentifier: "swift"),
            languageIdentifier: "swift"
        )
        XCTAssertNil(document.largeFileNotice)
        XCTAssertNotNil(document.language)
    }

    /// Opt-in measurement of the acceptance criterion: `LARGE_FILE_MEASURE_MB=520 swift test --filter testMeasureOpen`.
    func testMeasureOpen() async throws {
        guard let megabytes = ProcessInfo.processInfo.environment["LARGE_FILE_MEASURE_MB"].flatMap(Int.init) else {
            throw XCTSkip("set LARGE_FILE_MEASURE_MB to measure a real open")
        }
        let url = directory.appendingPathComponent("measure.swift")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        let chunk = Data(String(repeating: "let value = compute(items) // padding padding\n", count: 22_000).utf8)
        for _ in 0..<megabytes { try handle.write(contentsOf: chunk) }
        try handle.close()

        let start = CFAbsoluteTimeGetCurrent()
        let document = try await WorkbenchDocument.load(
            contentsOf: url, language: TreeSitterLanguage.bundled(forIdentifier: "swift"), languageIdentifier: "swift",
            largeFilePolicy: .standard
        )
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        textView.largeFileTier = document.largeFileNotice?.tier ?? .normal
        if let state = document.pendingState { textView.setState(state) }
        textView.layoutSubtreeIfNeeded()
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        print("LARGEFILE \(megabytes) MB: tier \(String(describing: document.largeFileNotice?.tier)) open+setState+layout \(String(format: "%.2f", elapsed)) s, RSS \(info.resident_size / 1_048_576) MB, editable \(textView.isEditable)")
        XCTAssertEqual(document.largeFileNotice?.tier, .readOnly)
        XCTAssertFalse(textView.isEditable)
    }

    // MARK: - TextView

    func testTheTierTurnsFoldingOffAndReadOnlyHoldsAgainstTheHost() {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.isLineFoldingEnabled = true
        textView.isEditable = true

        textView.largeFileTier = .degraded
        XCTAssertFalse(textView.isLineFoldingEnabled)
        XCTAssertTrue(textView.isEditable, "degraded is still editable")
        textView.isLineFoldingEnabled = true // the host applying its preferences after setState
        XCTAssertFalse(textView.isLineFoldingEnabled, "the tier wins")

        textView.largeFileTier = .readOnly
        XCTAssertFalse(textView.isEditable)
        textView.isEditable = true
        XCTAssertFalse(textView.isEditable, "read-only holds against the host")

        textView.largeFileTier = .normal
        XCTAssertTrue(textView.isLineFoldingEnabled, "what the host asked for comes back")
        XCTAssertTrue(textView.isEditable)
    }

    func testANormalTierLeavesTheHostsSettingsAlone() {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.isLineFoldingEnabled = false
        textView.isEditable = false
        textView.largeFileTier = .degraded
        textView.largeFileTier = .normal
        XCTAssertFalse(textView.isLineFoldingEnabled)
        XCTAssertFalse(textView.isEditable)
    }

    // MARK: - Index

    func testTheSwiftIndexReportsFilesItSkippedForSize() async throws {
        _ = try write("Small.swift", bytes: 200)
        let big = try write("Big.swift", bytes: SwiftPaths.maxBytes + 1_000)
        let index = SwiftIndex()
        await index.setRoot(directory)
        let oversized = await index.oversizedFiles
        XCTAssertEqual(oversized.map(\.lastPathComponent), [big.lastPathComponent])
        await index.setRoot(nil)
        let cleared = await index.oversizedFiles
        XCTAssertTrue(cleared.isEmpty)
    }
}
