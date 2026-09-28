import AppKit
import XCTest
import EditorIntelligence
@testable import Penumbra

@MainActor
final class EditorIntelligenceParameterInfoTests: XCTestCase {
    private final class RecordingProvider: SignatureHelpProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var positions: [Int] = []
        var model: ParameterHintsModel?

        init(model: ParameterHintsModel?) {
            self.model = model
        }

        var requestedOffsets: [Int] {
            lock.withLock { positions }
        }

        func signatureHelp(for document: Document, at position: TextPosition) async -> ParameterHintsModel? {
            lock.withLock { positions.append(position.utf16Offset) }
            return model
        }
    }

    private func makeController(provider: SignatureHelpProviding?) async throws -> (EditorIntelligenceController, TextView) {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.theme = DefaultTheme()
        textView.text = "call(one, two)"
        textView.selectedRange = NSRange(location: 8, length: 0)
        let controller = EditorIntelligenceController(
            textView: textView,
            completionEngine: CompletionEngine(providers: [], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: []),
            diagnosticEngine: DiagnosticEngine(providers: []),
            services: EditorIntelligenceServices(signatureHelpProvider: provider)
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        return (controller, textView)
    }

    func testParameterInfoAsksTheProviderAtTheCaret() async throws {
        let provider = RecordingProvider(model: ParameterHintsModel(signatures: ["void call(int a, int b)"],
                                                                     activeSignature: 0, activeParameter: 1))
        let (controller, textView) = try await makeController(provider: provider)
        withExtendedLifetime(controller) {
            XCTAssertTrue(textView.perform(.showParameterInfo), "The controller handles the action")
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(provider.requestedOffsets, [8])
    }

    func testParameterInfoIsNotHandledWithoutAProvider() async throws {
        let (controller, textView) = try await makeController(provider: nil)
        withExtendedLifetime(controller) {
            XCTAssertFalse(textView.perform(.showParameterInfo))
        }
    }

    func testAnEmptyAnswerDoesNotCrash() async throws {
        let provider = RecordingProvider(model: nil)
        let (controller, textView) = try await makeController(provider: provider)
        withExtendedLifetime(controller) {
            XCTAssertTrue(textView.perform(.showParameterInfo))
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(provider.requestedOffsets, [8])
    }

    func testCommandPIsBoundOnlyInTheIntelliJKeymap() {
        XCTAssertEqual(Keymap.intelliJ.action(for: KeyStroke(KeyChord("p", .command))), .showParameterInfo)
        XCTAssertNil(Keymap.default_.action(for: KeyStroke(KeyChord("p", .command))))
        XCTAssertEqual(Keymap.sublime.action(for: KeyStroke(KeyChord("p", .command))), .quickOpenFile)
    }
}
