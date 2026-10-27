import Foundation
import SwiftIntelligence
import XCTest

/// The inspections against this repository's own Swift, which compiles and is the largest valid corpus at
/// hand: no finding may claim a compile error, every fix must leave code that still parses, and a fix must
/// remove the finding it came from. `SWIFT_INSPECTION_APPLY_FIXES_TO=<directory>` rewrites a copy of the
/// sources with every fix applied, so a build of that copy shows whether the fixes also type-check.
final class SwiftInspectionRepositoryTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func everyRuleOptions(except skipped: Set<SwiftInspectionRule> = []) -> SwiftInspectionOptions {
        var options = SwiftInspectionOptions()
        options.enabled = Set(SwiftInspectionRule.allCases.filter { !$0.isEnabledByDefault && !skipped.contains($0) }.map(\.code))
        options.disabled = Set(skipped.map(\.code))
        return options
    }

    private func swiftFiles(under directory: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    private func apply(_ edits: [SwiftInspectionFix.Edit], to bytes: inout [UInt8]) {
        for edit in edits.sorted(by: { $0.bytes.lowerBound > $1.bytes.lowerBound }) {
            bytes.replaceSubrange(edit.bytes, with: Array(edit.replacement.utf8))
        }
    }

    func testNoFindingOnValidCodeIsAnError() throws {
        let sources = swiftFiles(under: Self.root.appendingPathComponent("Sources"))
        try XCTSkipIf(sources.isEmpty, "the repository sources are not next to the tests")
        let options = Self.everyRuleOptions()
        var errors: [String] = []
        for file in sources {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for finding in SwiftInspectionPipeline.analyze(text: text, options: options, cache: SwiftSyntaxParseCache(capacity: 1)).findings
            where finding.severity == .error {
                errors.append("\(file.lastPathComponent): \(finding.id)")
            }
        }
        XCTAssertTrue(errors.isEmpty, "inspections must not report a compile error on code that compiles: \(errors.prefix(10))")
    }

    func testEveryFixLeavesParseableCodeWithoutTheFinding() throws {
        let sources = swiftFiles(under: Self.root.appendingPathComponent("Sources"))
        try XCTSkipIf(sources.isEmpty, "the repository sources are not next to the tests")
        let options = Self.everyRuleOptions()
        var checked = 0
        var failures: [String] = []
        for file in sources {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  !SwiftSyntaxDocument.parse(text).hasSyntaxErrors else { continue }
            let analysis = SwiftInspectionPipeline.analyze(text: text, options: options, cache: SwiftSyntaxParseCache(capacity: 1))
            for finding in analysis.findings {
                for fix in finding.fixes {
                    var bytes = Array(text.utf8)
                    apply(fix.edits, to: &bytes)
                    let fixed = String(decoding: bytes, as: UTF8.self)
                    checked += 1
                    if SwiftSyntaxDocument.parse(fixed).hasSyntaxErrors {
                        failures.append("\(file.lastPathComponent): '\(fix.title)' (\(finding.id)) leaves a syntax error")
                    }
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.prefix(10)) of \(checked) fixes")
        print("SwiftInspectionRepositoryTests: \(checked) fixes parsed")
    }

    /// Not a test of its own: with the variable set, writes the fixed sources so they can be compiled.
    func testApplyEveryFixToACopy() throws {
        guard let target = ProcessInfo.processInfo.environment["SWIFT_INSPECTION_APPLY_FIXES_TO"] else {
            throw XCTSkip("set SWIFT_INSPECTION_APPLY_FIXES_TO to a copy of the repository")
        }
        let copy = URL(fileURLWithPath: target)
        // `count-is-zero` is opt-in because its fix does not compile for a type with a `count` and no
        // `isEmpty` declared in another file (this repository has two); the others' fixes must build.
        let options = Self.everyRuleOptions(except: [.countIsZero])
        var applied = 0
        for file in swiftFiles(under: copy) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let findings = SwiftInspectionPipeline.analyze(text: text, options: options, cache: SwiftSyntaxParseCache(capacity: 1)).findings
            // One fix per finding, last in the file first, skipping any that touches an earlier-applied range.
            var bytes = Array(text.utf8)
            var taken: [Range<Int>] = []
            for finding in findings.reversed() {
                guard let fix = finding.fixes.first else { continue }
                let span = (fix.edits.map(\.bytes.lowerBound).min() ?? 0) ..< (fix.edits.map(\.bytes.upperBound).max() ?? 0)
                guard !taken.contains(where: { $0.overlaps(span) || $0.contains(span.lowerBound) || span.contains($0.lowerBound) }) else { continue }
                apply(fix.edits, to: &bytes)
                taken.append(span)
                applied += 1
            }
            if !taken.isEmpty { try Data(bytes).write(to: file) }
        }
        print("SwiftInspectionRepositoryTests: applied \(applied) fixes under \(copy.path)")
    }
}
