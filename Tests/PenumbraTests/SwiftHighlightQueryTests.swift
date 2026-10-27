import Foundation
import XCTest
import PenumbraLanguages
import TreeSitterSwiftPenumbra
@testable import Penumbra

/// The SwiftUI overlay query lists specific patterns (view types, property wrappers) that must
/// win over the generic fallbacks (`(simple_identifier) @variable`, `(call_expression ...) @function.call`,
/// `(type_identifier) @type`). On a tie the earlier pattern is the one applied last.
final class SwiftHighlightQueryTests: XCTestCase {
    private let source = #"""
    import SwiftUI

    struct Demo: View {
        @Bindable var settings = settings

        var body: some View {
            Form {
                Picker("Provider", selection: $settings.provider) {
                    ForEach(IDEAgentProvider.allCases) { Text($0.title).tag($0) }
                }
                Section("Header") {
                    Text("Hello \(settings.name)")
                    refreshModelsIfOllama()
                }
            }
        }
    }
    """#

    func testSwiftUIViewTypesAreTypes() {
        for word in ["Form", "Picker", "ForEach", "Section", "Text"] {
            XCTAssertEqual(winningCapture(for: word), "type.builtin", word)
        }
    }

    func testPlainCallsStayFunctions() {
        XCTAssertEqual(winningCapture(for: "refreshModelsIfOllama"), "function.call")
    }

    func testPropertyWrapperIsAttribute() {
        XCTAssertEqual(winningCapture(for: "Bindable"), "attribute")
    }

    func testMemberAccessIsMember() {
        XCTAssertEqual(winningCapture(for: "provider"), "variable.member")
    }

    /// Identifier-shaped captures must land on whole words of the real file: a capture that starts
    /// or ends inside a word (`has|Endpoint`) paints the wrong characters.
    func testCapturesCoverWholeWordsInTheAgentSettingsFixture() {
        let text = AgentSettingsFixture.source
        let stringView = StringView(string: text)
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        let mode = TreeSitterInternalLanguageMode(
            language: TreeSitterLanguage.swift.internalLanguage,
            languageProvider: nil,
            stringView: stringView,
            lineManager: lineManager
        )
        mode.parse()
        let ns = text as NSString
        func isWordUnit(_ unit: unichar) -> Bool {
            guard let scalar = Unicode.Scalar(unit) else { return false }
            return scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
        }
        let wordNames = ["variable", "function", "type", "property", "attribute", "parameter"]
        var broken: [String] = []
        for capture in mode.captures(in: ByteRange(from: 0, to: stringView.byteCount)) {
            let name = capture.name
            guard wordNames.contains(where: { name == $0 || name.hasPrefix($0 + ".") }) else { continue }
            let range = NSRange(location: capture.byteRange.location.utf16Length, length: capture.byteRange.length.utf16Length)
            guard range.length > 0, range.upperBound <= ns.length else { continue }
            let word = ns.substring(with: range)
            // A member or call capture may cover `a.b`; only its edges need to sit on word edges.
            let before = range.location > 0 ? ns.character(at: range.location - 1) : 0x20
            let after = range.upperBound < ns.length ? ns.character(at: range.upperBound) : 0x20
            if (isWordUnit(before) && isWordUnit(ns.character(at: range.location)))
                || (isWordUnit(after) && isWordUnit(ns.character(at: range.upperBound - 1))) {
                let line = ns.substring(to: range.location).components(separatedBy: "\n").count
                broken.append("line \(line): \(name) '\(word)'")
            }
        }
        XCTAssertTrue(broken.isEmpty, broken.prefix(20).joined(separator: "\n"))
    }

    /// Name of the capture applied last (the one that paints) at the `occurrence`th `word`.
    private func winningCapture(for word: String, occurrence: Int = 0) -> String? {
        let stringView = StringView(string: source)
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        let mode = TreeSitterInternalLanguageMode(
            language: TreeSitterLanguage.swift.internalLanguage,
            languageProvider: nil,
            stringView: stringView,
            lineManager: lineManager
        )
        mode.parse()
        let ns = source as NSString
        var searchRange = NSRange(location: 0, length: ns.length)
        var found = NSRange(location: NSNotFound, length: 0)
        for _ in 0 ... occurrence {
            found = ns.range(of: word, options: [], range: searchRange)
            guard found.location != NSNotFound else { return nil }
            searchRange = NSRange(location: found.upperBound, length: ns.length - found.upperBound)
        }
        let start = ByteCount(utf16Length: found.location)
        let captures = mode.captures(in: ByteRange(from: 0, to: stringView.byteCount))
        return captures.last { $0.byteRange.location == start && $0.byteRange.length == ByteCount(utf16Length: found.length) }?.name
    }
}
