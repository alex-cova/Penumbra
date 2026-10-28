import AppKit
import JavaIntelligence
import XCTest
@testable import Penumbra
@testable import Umbra

@MainActor
final class IDEProfileLineHintsTests: XCTestCase {
    private func costs() -> JavaLineProfile {
        // A profile with two classes; `app.Order` has a hot line 12, a warm 20 and a cold 30.
        let symbols = JavaProfileSymbols()
        func frame(_ className: String, _ name: String, _ line: Int32) -> Int32 {
            symbols.internFrame(method: symbols.internMethod(className: className, name: name, parameters: ""), line: line)
        }
        var tree = JavaProfileTree()
        tree.add(stack: [frame("app.Order", "main", 5), frame("app.Order", "total", 12)], weight: 60)
        tree.add(stack: [frame("app.Order", "main", 5), frame("app.Order", "tax", 20)], weight: 30)
        tree.add(stack: [frame("app.Order", "main", 5), frame("app.Order", "log", 30)], weight: 1)
        tree.add(stack: [frame("app.Other", "run", 3)], weight: 9)
        return JavaLineProfile.build(from: tree, symbols: symbols)
    }

    private let roots = [URL(fileURLWithPath: "/p/src/main/java"), URL(fileURLWithPath: "/p/src/test/java")]

    func testFileToClassUsesTheSourceRootThatContainsIt() {
        XCTAssertEqual(
            IDEProfileLineHints.className(forFile: URL(fileURLWithPath: "/p/src/main/java/app/Order.java"), roots: roots), "app.Order"
        )
        XCTAssertEqual(
            IDEProfileLineHints.className(forFile: URL(fileURLWithPath: "/p/src/test/java/app/OrderTest.java"), roots: roots),
            "app.OrderTest"
        )
        XCTAssertNil(IDEProfileLineHints.className(forFile: URL(fileURLWithPath: "/elsewhere/Order.java"), roots: roots))
        XCTAssertNil(IDEProfileLineHints.className(forFile: URL(fileURLWithPath: "/p/src/main/java/app/notes.txt"), roots: roots))
        // The project folder as a root too (a plain folder): the nearest root wins.
        XCTAssertEqual(
            IDEProfileLineHints.className(
                forFile: URL(fileURLWithPath: "/p/src/main/java/app/Order.java"),
                roots: [URL(fileURLWithPath: "/p"), URL(fileURLWithPath: "/p/src/main/java")]
            ),
            "app.Order"
        )
    }

    func testAnnotationsLabelLinesAboveTheMinimumShareAndTintTheHottest() throws {
        let hints = IDEProfileLineHints()
        XCTAssertFalse(hints.isActive)
        hints.show(costs(), title: "run.jfr")
        XCTAssertTrue(hints.isActive)
        let file = URL(fileURLWithPath: "/p/src/main/java/app/Order.java")

        let annotations = try XCTUnwrap(hints.annotations(forFile: file, roots: roots, lineCount: 40))
        XCTAssertEqual(annotations.count, 40)
        XCTAssertEqual(annotations[4]?.text, "91.0%", "main's call lines carry everything below")
        XCTAssertEqual(annotations[11]?.text, "60.0%")
        XCTAssertEqual(annotations[19]?.text, "30.0%")
        XCTAssertEqual(annotations[29]?.text, "1.0%")
        XCTAssertNil(annotations[0])
        XCTAssertTrue(annotations[11]?.tooltip.contains("the line itself: 60.0%") == true)
        XCTAssertTrue(annotations[11]?.tooltip.contains("run.jfr") == true)
        // Neighbouring lines with the same text still each show it.
        XCTAssertNotEqual(annotations[11]?.id, annotations[19]?.id)

        let heat = hints.heat(forFile: file, roots: roots)
        XCTAssertEqual(heat.map(\.line), [12, 20, 30], "lines with at least 1% of their own samples")
        XCTAssertEqual(heat.first?.intensity, 1)
        XCTAssertEqual(try XCTUnwrap(heat.last).intensity, 1.0 / 60, accuracy: 1e-9)

        // Another file has nothing, so it is blame's.
        XCTAssertNil(hints.annotations(
            forFile: URL(fileURLWithPath: "/p/src/main/java/app/Missing.java"), roots: roots, lineCount: 10
        ))
        // A line past the end of a shorter buffer is not written.
        XCTAssertEqual(try XCTUnwrap(hints.annotations(forFile: file, roots: roots, lineCount: 15)).count, 15)
    }

    func testASwiftFileIsKeyedByItsRecordedPath() {
        // A Swift frame's class is its binary, so the hints key the file by path, not by class.
        let symbols = JavaProfileSymbols()
        let method = symbols.internMethod(className: "spin", name: "fib(_:)", parameters: "")
        symbols.setSourcePath("/proj/Sources/spin/main.swift", forMethod: method)
        var tree = JavaProfileTree()
        tree.add(stack: [symbols.internFrame(method: method, line: 1)], weight: 80)
        tree.add(stack: [symbols.internFrame(method: symbols.internMethod(className: "dyld", name: "start", parameters: ""), line: 0)], weight: 20)
        let hints = IDEProfileLineHints()
        hints.show(JavaLineProfile.build(from: tree, symbols: symbols), title: "spin.trace")
        XCTAssertTrue(hints.isActive)
        // The exact path, and the same file name alone when the recording came from elsewhere.
        let file = URL(fileURLWithPath: "/proj/Sources/spin/main.swift")
        XCTAssertNotNil(hints.annotations(forFile: file, roots: [], lineCount: 10))
        let moved = URL(fileURLWithPath: "/elsewhere/main.swift")
        XCTAssertNotNil(hints.annotations(forFile: moved, roots: [], lineCount: 10))
        XCTAssertNil(hints.annotations(forFile: URL(fileURLWithPath: "/elsewhere/other.swift"), roots: [], lineCount: 10))
    }

    func testStaleUpdatesAreDropped() {
        let hints = IDEProfileLineHints()
        let first = hints.beginUpdate()
        let second = hints.beginUpdate()
        XCTAssertFalse(hints.finishUpdate(ticket: first, profile: costs(), title: "old"))
        XCTAssertFalse(hints.isActive)
        XCTAssertTrue(hints.finishUpdate(ticket: second, profile: costs(), title: "new"))
        XCTAssertEqual(hints.title, "new")
        hints.clear()
        XCTAssertFalse(hints.isActive)
        let third = hints.beginUpdate()
        hints.clear()
        XCTAssertFalse(hints.finishUpdate(ticket: third, profile: costs(), title: "late"), "clear supersedes a pending update")
    }
}

/// The hints in a real editor: the annotation column, the tint, and blame staying out of the way.
@MainActor
final class IDEProfileLineHintsEditorTests: XCTestCase {
    private var workspace: IDEWorkspace!
    private var base: URL!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        base = FileManager.default.temporaryDirectory.appendingPathComponent("hints-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("app"), withIntermediateDirectories: true)
        workspace = IDEWorkspace()
        workspace.bootstrap()
        workspace.project.setRoot(base)
        IDEPreferences.shared.javaProfileLineHints = true
    }

    override func tearDownWithError() throws {
        workspace.teardown()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: base)
    }

    private func costs() -> JavaLineProfile {
        let symbols = JavaProfileSymbols()
        func frame(_ name: String, _ line: Int32) -> Int32 {
            symbols.internFrame(method: symbols.internMethod(className: "app.Order", name: name, parameters: ""), line: line)
        }
        var tree = JavaProfileTree()
        tree.add(stack: [frame("main", 3), frame("total", 6)], weight: 80)
        tree.add(stack: [frame("main", 3), frame("tax", 9)], weight: 20)
        return JavaLineProfile.build(from: tree, symbols: symbols)
    }

    func testHintsFillTheAnnotationColumnAndTintTheHotLineThenGoAway() async throws {
        let file = base.appendingPathComponent("app/Order.java")
        let source = (1...12).map { "// line \($0)" }.joined(separator: "\n") + "\n"
        try source.write(to: file, atomically: true, encoding: .utf8)
        await workspace.openDocument(from: file)
        let textView = workspace.host(for: workspace.workbench.activePaneID).textView
        XCTAssertFalse(textView.hasGutterAnnotations)

        workspace.profileHints.show(costs(), title: "run.jfr")
        XCTAssertTrue(workspace.profileHintsOwnAnnotations(of: file))
        workspace.refreshAnnotationColumnsInOpenEditors()
        XCTAssertTrue(textView.hasGutterAnnotations)
        XCTAssertEqual(textView.gutterAnnotationForTesting(atRow: 5)?.text, "80.0%")
        XCTAssertEqual(textView.gutterAnnotationForTesting(atRow: 8)?.text, "20.0%")
        XCTAssertEqual(textView.gutterAnnotationForTesting(atRow: 2)?.text, "100.0%")
        XCTAssertNil(textView.gutterAnnotationForTesting(atRow: 0))
        XCTAssertTrue(textView.lineBackgrounds.contains { $0.line == 6 }, "the hottest line is tinted")
        XCTAssertTrue(textView.lineBackgrounds.contains { $0.line == 9 })

        // The preference off: the column and the tint go, with no profile change.
        IDEPreferences.shared.javaProfileLineHints = false
        workspace.refreshAnnotationColumnsInOpenEditors()
        XCTAssertFalse(textView.hasGutterAnnotations)
        XCTAssertTrue(textView.lineBackgrounds.isEmpty)
        IDEPreferences.shared.javaProfileLineHints = true

        workspace.profileHints.clear()
        workspace.refreshAnnotationColumnsInOpenEditors()
        XCTAssertFalse(textView.hasGutterAnnotations)
        XCTAssertFalse(workspace.profileHintsOwnAnnotations(of: file))
    }

    func testAFileWithNoCostsIsLeftToBlame() async throws {
        let other = base.appendingPathComponent("app/Other.java")
        try "class Other {}\n".write(to: other, atomically: true, encoding: .utf8)
        await workspace.openDocument(from: other)
        workspace.profileHints.show(costs(), title: "run.jfr")
        XCTAssertFalse(workspace.profileHintsOwnAnnotations(of: other))
        workspace.refreshAnnotationColumnsInOpenEditors()
        let textView = workspace.host(for: workspace.workbench.activePaneID).textView
        XCTAssertFalse(textView.hasGutterAnnotations)
    }
}
