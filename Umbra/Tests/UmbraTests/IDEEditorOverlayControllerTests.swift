import EditorIntelligence
import Penumbra
import XCTest
@testable import Umbra

@MainActor
final class IDEEditorOverlayControllerTests: XCTestCase {
    private struct FakeMarkers: LineMarkerProviding {
        var markers: [LineMarker]
        var delay: Duration = .zero
        func lineMarkers(source: String, fileURL: URL?, kinds: Set<LineMarkerKind>) async -> [LineMarker]? {
            if delay > .zero { try? await Task.sleep(for: delay) }
            return markers
        }
        func siblingTargets(of marker: LineMarker, source: String, fileURL: URL?, documentID: DocumentID) async -> [Location] { [] }
    }

    private let overriding = LineMarker(kind: .overriding, line: 1, anchorUTF16Offset: 4, tooltip: "overrides")

    private func makeTextView(_ text: String = "class A {}\n") -> TextView {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        textView.text = text
        return textView
    }

    private func waitFor(_ message: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), message)
    }

    func testTheMarkerColumnIsReservedPerLanguage() {
        XCTAssertEqual(IDEEditorOverlayController.reservedLineMarkerSlots(languageIdentifier: "java", hasMarkerProvider: true), TextView.maximumLineMarkerSlots)
        XCTAssertEqual(IDEEditorOverlayController.reservedLineMarkerSlots(languageIdentifier: "http", hasMarkerProvider: false), 1)
        XCTAssertEqual(IDEEditorOverlayController.reservedLineMarkerSlots(languageIdentifier: "swift", hasMarkerProvider: false), 0)
    }

    func testMarkersArePaintedAndAClickReachesTheCaller() async {
        let controller = IDEEditorOverlayController()
        let textView = makeTextView()
        var clicked: [LineMarker] = []
        controller.scheduleLineMarkers(
            for: textView, provider: FakeMarkers(markers: [overriding]), kinds: [.overriding],
            languageIdentifier: "java", delay: .zero
        ) { clicked.append($0) }
        XCTAssertEqual(textView.reservedLineMarkerSlots, TextView.maximumLineMarkerSlots, "reserved at once, before the icons arrive")
        await waitFor("painted") { textView.lineMarkerHandler != nil }

        let gutter = GutterLineMarker(id: 0, line: 1, icon: LineMarkerKind.overriding.gutterIcon, tooltip: "")
        XCTAssertEqual(controller.marker(for: gutter, in: textView)?.anchorUTF16Offset, 4)
        textView.lineMarkerHandler?(gutter, .zero)
        XCTAssertEqual(clicked.count, 1)
        XCTAssertEqual(clicked.first?.kind, .overriding)
    }

    func testAResultForTextThatChangedMeanwhileIsDropped() async {
        let controller = IDEEditorOverlayController()
        let textView = makeTextView()
        controller.scheduleLineMarkers(
            for: textView, provider: FakeMarkers(markers: [overriding], delay: .milliseconds(150)), kinds: [.overriding],
            languageIdentifier: "java", delay: .zero
        ) { _ in }
        try? await Task.sleep(for: .milliseconds(30))
        textView.text = "class B {}\n"
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(textView.lineMarkerHandler, "markers computed for the old text were not painted")
        let gutter = GutterLineMarker(id: 0, line: 1, icon: LineMarkerKind.overriding.gutterIcon, tooltip: "")
        XCTAssertNil(controller.marker(for: gutter, in: textView))
    }

    func testAClickOnMarkersOlderThanTheBufferIsIgnored() async {
        let controller = IDEEditorOverlayController()
        let textView = makeTextView()
        controller.scheduleLineMarkers(
            for: textView, provider: FakeMarkers(markers: [overriding]), kinds: [.overriding],
            languageIdentifier: "java", delay: .zero
        ) { _ in }
        await waitFor("painted") { textView.lineMarkerHandler != nil }
        textView.text = "class B {}\n"
        let gutter = GutterLineMarker(id: 0, line: 1, icon: LineMarkerKind.overriding.gutterIcon, tooltip: "")
        XCTAssertNil(controller.marker(for: gutter, in: textView), "their offsets are stale")
    }

    func testWithoutAProviderTheMarkersAreCleared() async {
        let controller = IDEEditorOverlayController()
        let textView = makeTextView()
        controller.scheduleLineMarkers(
            for: textView, provider: FakeMarkers(markers: [overriding]), kinds: [.overriding],
            languageIdentifier: "java", delay: .zero
        ) { _ in }
        await waitFor("painted") { textView.lineMarkerHandler != nil }
        controller.scheduleLineMarkers(
            for: textView, provider: nil, kinds: [.overriding], languageIdentifier: "java", delay: .zero
        ) { _ in }
        XCTAssertNil(textView.lineMarkerHandler)
        XCTAssertEqual(textView.reservedLineMarkerSlots, 0)
    }

    func testTheNameIndexOverlayReceivesTheFileAndItsCurrentText() async {
        let controller = IDEEditorOverlayController()
        let textView = makeTextView("class A {}\n")
        let url = URL(fileURLWithPath: "/p/A.java")
        textView.documentURL = url
        var received: [(URL, String)] = []
        controller.scheduleNameIndexOverlay(for: textView, delay: .milliseconds(30)) { received.append(($0, $1)) }
        textView.text = "class A { int x; }\n"
        await waitFor("applied") { !received.isEmpty }
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.0, url)
        XCTAssertEqual(received.first?.1, "class A { int x; }\n", "the text as it is when the pause ends")
    }
}
