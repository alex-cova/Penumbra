import Foundation
import SwiftIntelligence
import XCTest

/// The refactorings on this repository's own Swift, which compiles. Every result must still parse, and
/// `SWIFT_REFACTOR_APPLY_TO=<directory>` rewrites a copy of the sources (one refactoring per file) so that
/// building it shows whether they also type-check on real code.
final class SwiftRefactoringRepositoryTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private typealias Refactoring = @Sendable (String, Int) -> SwiftRefactoringResult

    private static let refactorings: [(name: String, run: Refactoring)] = [
        ("add explicit type", { SwiftAddExplicitType.edits(in: $0, caret: $1) }),
        ("inline variable", { SwiftInlineVariable.edits(in: $0, caret: $1) }),
        ("convert if/guard", { SwiftConditionalConversion.edits(in: $0, caret: $1) }),
        ("move to extension", { SwiftMoveToExtension.edits(in: $0, caret: $1) }),
        ("optional binding shorthand", { SwiftOptionalBindingShorthand.edits(in: $0, caret: $1) }),
    ]

    private func swiftFiles(under directory: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    /// The offset of the first non-blank character of every line.
    private func lineStarts(of text: String) -> [Int] {
        var result: [Int] = []
        var offset = 0
        for line in text.utf8.split(separator: 0x0A, omittingEmptySubsequences: false) {
            if let first = line.firstIndex(where: { $0 != 0x20 && $0 != 0x09 }) {
                result.append(offset + line.distance(from: line.startIndex, to: first))
            }
            offset += line.count + 1
        }
        return result
    }

    func testEveryResultOnRealCodeStillParses() throws {
        let files = swiftFiles(under: Self.root.appendingPathComponent("Sources"))
        try XCTSkipIf(files.isEmpty, "the repository sources are not next to the tests")
        var applied = [String: Int]()
        var failures: [String] = []
        for (fileIndex, file) in files.enumerated() where fileIndex % 12 == 0 {
            guard let text = try? String(contentsOf: file, encoding: .utf8), text.utf8.count < 200_000,
                  !SwiftSyntaxDocument.parse(text).hasSyntaxErrors else { continue }
            for caret in lineStarts(of: text).enumerated().filter({ $0.offset % 4 == 0 }).map(\.element) {
                for (name, run) in Self.refactorings {
                    guard let after = SwiftRefactoringTests.apply(run(text, caret), to: text) else { continue }
                    applied[name, default: 0] += 1
                    if SwiftSyntaxDocument.parse(after).hasSyntaxErrors {
                        failures.append("\(file.lastPathComponent) @\(caret): \(name) leaves a syntax error")
                    }
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.prefix(10))")
        print("SwiftRefactoringRepositoryTests: \(applied.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
    }

    func testApplyOneRefactoringPerFileToACopy() throws {
        guard let target = ProcessInfo.processInfo.environment["SWIFT_REFACTOR_APPLY_TO"] else {
            throw XCTSkip("set SWIFT_REFACTOR_APPLY_TO to a copy of the repository")
        }
        var applied = [String: Int]()
        for (fileIndex, file) in swiftFiles(under: URL(fileURLWithPath: target)).enumerated() {
            guard let text = try? String(contentsOf: file, encoding: .utf8), text.utf8.count < 200_000,
                  !SwiftSyntaxDocument.parse(text).hasSyntaxErrors else { continue }
            let starts = lineStarts(of: text)
            // Try the kinds in a rotation that differs per file, so every kind is exercised across the tree.
            let order = (0 ..< Self.refactorings.count).map { Self.refactorings[(fileIndex + $0) % Self.refactorings.count] }
            var done = false
            for (name, run) in order where !done {
                for caret in starts {
                    guard let after = SwiftRefactoringTests.apply(run(text, caret), to: text) else { continue }
                    try after.write(to: file, atomically: true, encoding: .utf8)
                    applied[name, default: 0] += 1
                    done = true
                    break
                }
            }
        }
        print("SwiftRefactoringRepositoryTests: applied \(applied.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")) under \(target)")
    }
}
