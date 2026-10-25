import Foundation
import XCTest

/// Architectural boundary guardrail: the intelligence stack must not depend on the editor engine
/// or on UI frameworks. `EditorIntelligence` is the zero-dependency core; `JavaIntelligence`
/// builds on it (plus `LanguageSyntax`/grammars/`SubprocessKit`). Only the Penumbra-side adapter
/// and the Umbra host may reference `Penumbra`, and only Umbra touches AppKit/SwiftUI.
///
/// Scans the module sources directly so a new `import` that violates the layering fails the suite
/// instead of silently re-coupling the layers.
final class ModuleBoundaryTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ModuleBoundaryTests.swift
            .deletingLastPathComponent() // PenumbraTests
            .deletingLastPathComponent() // Tests
    }

    private func swiftFiles(under relativeDir: String) throws -> [URL] {
        let dir = repoRoot.appendingPathComponent(relativeDir, isDirectory: true)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dir.path),
            "Expected source directory at \(dir.path); update the test if the layout moved."
        )
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private func forbiddenImports(in relativeDir: String, forbidden: Set<String>) throws -> [String] {
        var offenders: [String] = []
        for file in try swiftFiles(under: relativeDir) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.components(separatedBy: .newlines) where line.hasPrefix("import ") {
                let module = line
                    .dropFirst("import ".count)
                    .split(separator: " ", maxSplits: 1)
                    .first
                    .map(String.init) ?? ""
                if forbidden.contains(module) {
                    offenders.append("\(file.lastPathComponent): \(line)")
                }
            }
        }
        return offenders.sorted()
    }

    func testEditorIntelligenceHasNoEngineOrUIDependency() throws {
        let offenders = try forbiddenImports(
            in: "Sources/EditorIntelligence",
            forbidden: ["Penumbra", "AppKit", "SwiftUI", "Umbra", "JavaIntelligence"]
        )
        XCTAssertTrue(
            offenders.isEmpty,
            "Sources/EditorIntelligence must stay engine- and UI-free; found:\n\(offenders.joined(separator: "\n"))"
        )
    }

    func testJavaIntelligenceHasNoEngineOrUIDependency() throws {
        let offenders = try forbiddenImports(
            in: "Sources/JavaIntelligence",
            forbidden: ["Penumbra", "AppKit", "SwiftUI", "Umbra"]
        )
        XCTAssertTrue(
            offenders.isEmpty,
            "Sources/JavaIntelligence must stay engine- and UI-free; found:\n\(offenders.joined(separator: "\n"))"
        )
    }
}
