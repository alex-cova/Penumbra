import XCTest
import AppKit
@testable import Penumbra
import EditorIntelligence

/// The controller reserves room for every declaration first and fills in the numbers for what is on
/// screen after, and a click on a label goes to Find Usages or the implementations.
@MainActor
final class CodeVisionControllerTests: XCTestCase {
    private actor FakeProvider: CodeVisionProviding {
        let anchors: [Int]
        var delay: UInt64 = 0
        private(set) var requestedAnchors: [[Int]] = []

        init(anchors: [Int]) { self.anchors = anchors }

        func setDelay(_ nanoseconds: UInt64) { delay = nanoseconds }

        func codeVisionAnchors(for document: Document) async -> [Int] { anchors }

        func codeVision(for document: Document, anchors: [Int]) async -> [CodeVisionLens] {
            requestedAnchors.append(anchors)
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            return anchors.map {
                CodeVisionLens(utf16Offset: $0, entries: [CodeVisionEntry(id: "usages", text: "1 usage")])
            }
        }
    }

    private let source = (0 ..< 30).map { "func f\($0)() {}" }.joined(separator: "\n")

    private func offset(ofRow row: Int) -> Int {
        source.components(separatedBy: "\n").prefix(row).reduce(0) { $0 + $1.utf16.count + 1 }
    }

    private func makeController(provider: FakeProvider) -> (EditorIntelligenceController, TextView, NSWindow) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let textView = TextView(frame: window.contentView!.bounds)
        textView.theme = DefaultTheme()
        textView.text = source
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        textView.layoutIfNeeded()
        let controller = EditorIntelligenceController(
            textView: textView,
            completionEngine: CompletionEngine(providers: [], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: []),
            diagnosticEngine: DiagnosticEngine(providers: []),
            services: EditorIntelligenceServices(codeVisionProvider: provider)
        )
        return (controller, textView, window)
    }

    private func wait(until condition: () -> Bool, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testRoomIsReservedForEveryDeclarationAndLabelsFollowForTheOnesOnScreen() async throws {
        let anchors = [0, 3, 12, 28].map { offset(ofRow: $0) + 5 }
        let provider = FakeProvider(anchors: anchors)
        await provider.setDelay(300_000_000)
        let (controller, textView, window) = makeController(provider: provider)
        defer { window.orderOut(nil) }

        controller.codeVisionEnabled = true
        controller.refreshCodeVision(delay: 0)

        try await wait { textView.codeVisionLenses.count == anchors.count }
        XCTAssertEqual(textView.codeVisionLenses.map(\.utf16Offset), anchors, "room for every declaration")
        XCTAssertTrue(textView.codeVisionLenses.allSatisfy { $0.entries.isEmpty }, "no labels until the numbers arrive")

        try await wait { textView.codeVisionLenses.contains { !$0.entries.isEmpty } }
        let labelled = textView.codeVisionLenses.filter { !$0.entries.isEmpty }.map(\.utf16Offset)
        XCTAssertFalse(labelled.isEmpty)
        XCTAssertTrue(labelled.contains(anchors[0]), "a declaration on screen has its label")
        XCTAssertFalse(labelled.contains(anchors[3]), "one far below the viewport waits until it is scrolled to")
        let requested = await provider.requestedAnchors
        XCTAssertFalse(requested.flatMap { $0 }.contains(anchors[3]))
    }

    func testTurningItOffClearsTheLenses() async throws {
        let provider = FakeProvider(anchors: [offset(ofRow: 1) + 5])
        let (controller, textView, window) = makeController(provider: provider)
        defer { window.orderOut(nil) }
        controller.codeVisionEnabled = true
        controller.refreshCodeVision(delay: 0)
        try await wait { !textView.codeVisionLenses.isEmpty }

        controller.codeVisionEnabled = false

        XCTAssertEqual(textView.codeVisionLenses, [])
    }

    func testClickingUsagesOpensFindUsagesAtTheDeclaration() async throws {
        let provider = FakeProvider(anchors: [offset(ofRow: 1) + 5])
        let (controller, textView, window) = makeController(provider: provider)
        defer { window.orderOut(nil) }
        controller.codeVisionEnabled = true
        controller.refreshCodeVision(delay: 0)
        try await wait { textView.codeVisionLenses.contains { !$0.entries.isEmpty } }

        var other: [(String, Int)] = []
        controller.onCodeVisionClick = { entry, offset in other.append((entry.id, offset)) }
        textView.codeVisionHandler?(CodeVisionEntry(id: "custom", text: "x"), 42)

        XCTAssertEqual(other.count, 1)
        XCTAssertEqual(other.first?.0, "custom")
        XCTAssertEqual(other.first?.1, 42)
    }
}
