import AppKit
import GitIntelligence
import JavaIntelligence
import XCTest
@testable import Umbra

/// Arrow-key and type-select through sidebar lists, and the Browser ⌘L matcher that must not steal Go to Line.
@MainActor
final class IDEListKeyboardTests: XCTestCase {
    func testAListMovesFromNoneAndStopsAtTheEnds() {
        let names = ["lint", "test", "build"]
        XCTAssertEqual(IDEListNeighbor.move(nil, in: names, by: 1), "lint")
        XCTAssertEqual(IDEListNeighbor.move(nil, in: names, by: -1), "build")
        XCTAssertEqual(IDEListNeighbor.move("test", in: names, by: 1), "build")
        XCTAssertEqual(IDEListNeighbor.move("build", in: names, by: 1), "build")
        XCTAssertEqual(IDEListNeighbor.move("lint", in: names, by: -1), "lint")
        XCTAssertNil(IDEListNeighbor.move(nil as String?, in: [], by: 1))
    }

    func testArrowKeysMoveTheChangeSelectionAndStopAtTheEnds() {
        let model = IDEGitStatusModel()
        let visible = ["/a", "/b", "/c"]
        model.moveChangeSelection(by: 1, in: visible)
        XCTAssertEqual(model.selectedChangePath, "/a")
        model.moveChangeSelection(by: 1, in: visible)
        XCTAssertEqual(model.selectedChangePath, "/b")
        model.moveChangeSelection(by: 1, in: visible)
        XCTAssertEqual(model.selectedChangePath, "/c")
        model.moveChangeSelection(by: 1, in: visible)
        XCTAssertEqual(model.selectedChangePath, "/c")
        model.moveChangeSelection(by: -1, in: visible)
        XCTAssertEqual(model.selectedChangePath, "/b")
        model.selectChange(nil)
        model.moveChangeSelection(by: -1, in: visible)
        XCTAssertEqual(model.selectedChangePath, "/c")
        model.moveChangeSelection(by: 1, in: [] as [String])
        XCTAssertEqual(model.selectedChangePath, "/c")
    }

    func testHistoryKeyboardOrderFollowsThePaintedRows() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        func event(_ path: String, _ seconds: Double, group: UUID? = nil) -> IDELocalHistoryEvent {
            IDELocalHistoryEvent(
                time: t0.addingTimeInterval(seconds), path: path, before: "b", after: "a",
                source: group == nil ? .save : .agent(tab: "T", prompt: "p"), group: group
            )
        }
        let a = event("A.java", 3)
        let b = event("B.java", 2)
        XCTAssertEqual(IDELocalHistoryPresentation.keyboardEventIDs(fileEvents: [a, b]), [a.id, b.id])

        let run = UUID()
        let g1 = event("A.java", 10, group: run)
        let g2 = event("B.java", 9, group: run)
        let lone = event("C.java", 1)
        XCTAssertEqual(
            IDELocalHistoryPresentation.keyboardEventIDs(projectEvents: [g1, g2, lone]),
            [g1.id, g2.id, lone.id]
        )
    }

    func testTypeaheadMatchesAPrefixAndCyclesARepeatedLetter() {
        let items = ["Apple.swift", "Apricot.ts", "Banana.swift", "aardvark.rs"]
        func match(_ query: String, selected: String?) -> String? {
            IDEListTypeahead.match(query: query, in: items, selected: selected, title: { $0 })
        }
        XCTAssertEqual(match("a", selected: nil), "Apple.swift")
        XCTAssertEqual(match("a", selected: "Apple.swift"), "Apricot.ts")
        XCTAssertEqual(match("aa", selected: "Apricot.ts"), "aardvark.rs")
        XCTAssertEqual(match("ap", selected: "Apple.swift"), "Apple.swift")
        XCTAssertEqual(match("apr", selected: "Apple.swift"), "Apricot.ts")
        XCTAssertEqual(match("a", selected: "aardvark.rs"), "Apple.swift")
        XCTAssertEqual(match("B", selected: nil), "Banana.swift")
        XCTAssertNil(match("zzz", selected: nil))
        XCTAssertNil(match("", selected: nil))
        XCTAssertNil(IDEListTypeahead.match(query: "a", in: [String](), selected: nil, title: { $0 }))
    }

    func testTypeaheadBufferStartsANewQueryAfterIdle() {
        var buffer = IDETypeaheadBuffer()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(buffer.typed("a", now: t0), "a")
        XCTAssertEqual(buffer.typed("p", now: t0.addingTimeInterval(0.2)), "ap")
        XCTAssertEqual(buffer.typed("x", now: t0.addingTimeInterval(0.2 + IDEListTypeahead.timeout)), "x")
        buffer.reset()
        XCTAssertEqual(buffer.query, "")
        XCTAssertEqual(buffer.typed("s", now: t0.addingTimeInterval(10)), "s")
    }

    func testFlattenedTestRowsFollowCollapse() {
        let groups = [
            IDETestResultGroup(className: "app.CalcTest", cases: [
                IDETestCaseResult(className: "app.CalcTest", name: "adds", status: .passed),
                IDETestCaseResult(className: "app.CalcTest", name: "fails", status: .failed)
            ])
        ]
        let open = IDETestResultsTree.flatten(groups: groups, collapsed: [])
        XCTAssertEqual(open.map(\.title), ["CalcTest", "adds", "fails"])
        XCTAssertEqual(open.map(\.id), [
            IDETestResultsTree.groupKey("app.CalcTest"),
            "app.CalcTest.adds",
            "app.CalcTest.fails"
        ])
        XCTAssertTrue(open[0].isExpanded)
        let shut = IDETestResultsTree.flatten(groups: groups, collapsed: ["app.CalcTest"])
        XCTAssertEqual(shut.map(\.title), ["CalcTest"])
        XCTAssertFalse(shut[0].isExpanded)
        XCTAssertEqual(
            IDEListNeighbor.move(open[0].id, in: open.map(\.id), by: 1),
            "app.CalcTest.adds"
        )
    }

    func testFlattenedDebugValueRowsStayLazyUntilExpanded() {
        let child = JavaDebugValue(name: "size", type: "int", value: "2", expression: "list.size")
        let parent = JavaDebugValue(
            name: "list", type: "ArrayList", value: "size=2", expression: "list", hasChildren: true
        )
        let sibling = JavaDebugValue(name: "count", type: "int", value: "1", expression: "count")
        let closed = IDEDebugValueTree.flatten(
            roots: [parent, sibling], expanded: [], loaded: [:], loading: [], errors: [:]
        )
        XCTAssertEqual(closed.map(\.title), ["list", "count"])
        XCTAssertTrue(closed[0].canDisclose)
        XCTAssertFalse(closed[0].isExpanded)
        let stillLazy = IDEDebugValueTree.flatten(
            roots: [parent, sibling], expanded: [parent.id], loaded: [:], loading: [parent.id], errors: [:]
        )
        XCTAssertEqual(stillLazy.map(\.title), ["list", "count"], "children are not invented before the adapter answers")
        XCTAssertTrue(stillLazy[0].isLoading)
        let open = IDEDebugValueTree.flatten(
            roots: [parent, sibling], expanded: [parent.id], loaded: [parent.id: [child]], loading: [], errors: [:]
        )
        XCTAssertEqual(open.map(\.title), ["list", "size", "count"])
        XCTAssertEqual(open[1].depth, 1)
        XCTAssertEqual(
            IDEListNeighbor.move(open[0].id, in: open.map(\.id), by: 1),
            child.id
        )
        let watchOpen = IDEDebugValueTree.flatten(
            groups: [
                .init(idPrefix: "watch:", isWatch: true, roots: [parent]),
                .init(roots: [sibling])
            ],
            expanded: ["watch:" + parent.id],
            loaded: ["watch:" + parent.id: [child]],
            loading: [],
            errors: [:]
        )
        XCTAssertEqual(watchOpen.map(\.id), ["watch:" + parent.id, "watch:" + child.id, sibling.id])
        XCTAssertTrue(watchOpen[0].isWatch)
        XCTAssertFalse(watchOpen[1].isWatch)
        XCTAssertFalse(watchOpen[2].isWatch)
    }

    func testArrowKeysMoveTheCommitSelectionAndStopAtTheEnds() {
        let model = IDEGitStatusModel()
        let visible = ["aaa", "bbb", "ccc"]
        model.moveCommitSelection(by: 1, in: visible)
        XCTAssertEqual(model.selectedCommitHash, "aaa")
        model.moveCommitSelection(by: 1, in: visible)
        XCTAssertEqual(model.selectedCommitHash, "bbb")
        model.moveCommitSelection(by: 1, in: visible)
        XCTAssertEqual(model.selectedCommitHash, "ccc")
        model.moveCommitSelection(by: 1, in: visible)
        XCTAssertEqual(model.selectedCommitHash, "ccc")
        model.moveCommitSelection(by: -1, in: visible)
        XCTAssertEqual(model.selectedCommitHash, "bbb")
        model.selectCommit(nil)
        model.moveCommitSelection(by: -1, in: visible)
        XCTAssertEqual(model.selectedCommitHash, "ccc")
        model.moveCommitSelection(by: 1, in: [])
        XCTAssertEqual(model.selectedCommitHash, "ccc")
    }

    func testArrowKeysMoveTheStashSelectionAndStopAtTheEnds() {
        let model = IDEGitStatusModel()
        let visible = ["s1", "s2"]
        model.moveStashSelection(by: 1, in: visible)
        XCTAssertEqual(model.selectedStashHash, "s1")
        model.moveStashSelection(by: 1, in: visible)
        XCTAssertEqual(model.selectedStashHash, "s2")
        model.moveStashSelection(by: 1, in: visible)
        XCTAssertEqual(model.selectedStashHash, "s2")
        model.moveStashSelection(by: -1, in: visible)
        XCTAssertEqual(model.selectedStashHash, "s1")
        model.selectStash(nil)
        model.moveStashSelection(by: -1, in: visible)
        XCTAssertEqual(model.selectedStashHash, "s2")
    }

    func testArrowKeysMoveTheCommitFileSelectionThroughAllChanges() {
        let model = IDEGitStatusModel()
        let paths = ["src/A.java", "src/B.java"]
        XCTAssertNil(model.selectedCommitFile)
        model.moveCommitFileSelection(by: 1, in: paths)
        XCTAssertEqual(model.selectedCommitFile, "src/A.java")
        model.moveCommitFileSelection(by: 1, in: paths)
        XCTAssertEqual(model.selectedCommitFile, "src/B.java")
        model.moveCommitFileSelection(by: 1, in: paths)
        XCTAssertEqual(model.selectedCommitFile, "src/B.java")
        model.moveCommitFileSelection(by: -1, in: paths)
        XCTAssertEqual(model.selectedCommitFile, "src/A.java")
        model.moveCommitFileSelection(by: -1, in: paths)
        XCTAssertNil(model.selectedCommitFile, "up from the first file lands on All Changes")
        model.moveCommitFileSelection(by: -1, in: paths)
        XCTAssertNil(model.selectedCommitFile)
    }

    func testBranchPopupOrderPutsActionsFirstUntilSearchFilters() {
        let empty = IDEGitBranchPopupKeyboard.order(
            showingActions: true, localIDs: ["heads/main"], remoteIDs: ["remotes/origin/main"], tagNames: ["v1"]
        )
        XCTAssertEqual(Array(empty.prefix(IDEGitBranchPopupKeyboard.Action.allCases.count)), IDEGitBranchPopupKeyboard.Action.allCases.map(\.id))
        XCTAssertEqual(Array(empty.suffix(3)), ["heads/main", "remotes/origin/main", "tag/v1"])
        XCTAssertEqual(
            IDEGitBranchPopupKeyboard.order(
                showingActions: false, localIDs: ["heads/main"], remoteIDs: [], tagNames: ["v1"]
            ),
            ["heads/main", "tag/v1"]
        )
        XCTAssertEqual(IDEGitBranchPopupKeyboard.Action(id: "action:fetch"), .fetch)
        XCTAssertNil(IDEGitBranchPopupKeyboard.Action(id: "heads/main"))
    }

    func testAISidebarOrderIsOpenChatsThenSavedRowsPerGroup() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        XCTAssertEqual(
            IDEAISidebarKeyboard.chatOrder(openIDs: [a, b], savedIDs: [c]),
            [.open(a), .open(b), .saved(c)]
        )
        XCTAssertEqual(
            IDEAISidebarKeyboard.codeOrder(groups: [
                (openIDs: [a], savedIDs: [b]),
                (openIDs: [], savedIDs: [c, d])
            ]),
            [.open(a), .saved(b), .saved(c), .saved(d)]
        )
        XCTAssertEqual(
            IDEListNeighbor.move(.open(a), in: IDEAISidebarKeyboard.chatOrder(openIDs: [a], savedIDs: [c]), by: 1),
            .saved(c)
        )
    }

    func testStreamTraceArrowsStayInAStageThenHopKeepingTheRow() {
        let counts = [2, 1, 2]
        func cell(_ stage: Int, _ index: Int) -> IDEStreamTraceKeyboard.Cell { .init(stage: stage, index: index) }
        let first = IDEStreamTraceKeyboard.move(nil, stageCounts: counts, dStage: 0, dIndex: 1)
        XCTAssertEqual(first, cell(0, 0))
        let down = IDEStreamTraceKeyboard.move(first, stageCounts: counts, dStage: 0, dIndex: 1)
        XCTAssertEqual(down, cell(0, 1))
        XCTAssertEqual(IDEStreamTraceKeyboard.move(down, stageCounts: counts, dStage: 0, dIndex: 1), cell(0, 1))
        let right = IDEStreamTraceKeyboard.move(down, stageCounts: counts, dStage: 1, dIndex: 0)
        XCTAssertEqual(right, cell(1, 0), "the middle stage has only one row")
        XCTAssertEqual(IDEStreamTraceKeyboard.move(right, stageCounts: counts, dStage: 1, dIndex: 0), cell(2, 0))
        XCTAssertEqual(
            IDEStreamTraceKeyboard.move(cell(2, 1), stageCounts: counts, dStage: -1, dIndex: 0),
            cell(1, 0)
        )
        XCTAssertNil(IDEStreamTraceKeyboard.move(nil, stageCounts: [0, 0], dStage: 0, dIndex: 1))
    }

    func testGradleTaskPickerPutsApplicationFirstThenFilters() {
        typealias Task = JavaGradleProjectModel.GradleTask
        let tasks = [
            Task(path: ":build", name: "build", group: "build"),
            Task(path: ":test", name: "test", group: "verification"),
            Task(path: ":bootRun", name: "bootRun", group: "application"),
            Task(path: ":app:run", name: "run", group: "application"),
        ]
        XCTAssertEqual(
            IDEGradleTaskPickerOrder.keyboardIDs(IDEGradleTaskPickerOrder.groups(tasks: tasks, query: "")),
            ["run", "bootRun", "build", "test"]
        )
        XCTAssertEqual(
            IDEGradleTaskPickerOrder.keyboardIDs(IDEGradleTaskPickerOrder.groups(tasks: tasks, query: "run")),
            ["run", "bootRun"]
        )
        XCTAssertEqual(
            IDEGradleTaskPickerOrder.keyboardIDs(IDEGradleTaskPickerOrder.groups(tasks: tasks, query: "verif")),
            ["test"]
        )
        let ids = IDEGradleTaskPickerOrder.keyboardIDs(IDEGradleTaskPickerOrder.groups(tasks: tasks, query: ""))
        XCTAssertEqual(IDEListNeighbor.move(nil, in: ids, by: 1), "run")
        XCTAssertEqual(IDEListNeighbor.move("run", in: ids, by: 1), "bootRun")
        XCTAssertEqual(IDEListNeighbor.move("test", in: ids, by: 1), "test")
    }

    func testInspectionByNameIsTitleSortedThenFilteredByWords() {
        let rules = IDEInspectionLanguage.java.rules
        let empty = IDEInspectionByNameOrder.matches(rules: rules, query: "")
        XCTAssertEqual(empty.map(\.title), empty.map(\.title).sorted())
        XCTAssertEqual(empty.count, rules.count)

        let imports = IDEInspectionByNameOrder.matches(rules: rules, query: "import")
        XCTAssertTrue(imports.contains { $0.code == JavaInspectionRule.unusedImport.code })
        XCTAssertFalse(imports.contains { $0.code == JavaInspectionRule.missingOverride.code })
        XCTAssertTrue(imports.allSatisfy { rule in
            (rule.title + " " + rule.code + " " + rule.groupTitle).lowercased().contains("import")
        })

        let ids = IDEInspectionByNameOrder.visible(empty).map(\.id)
        XCTAssertEqual(IDEListNeighbor.move(nil, in: ids, by: 1), ids.first)
        XCTAssertLessThanOrEqual(ids.count, IDEInspectionByNameOrder.visibleLimit)
    }

    func testProjectTaskListWalksPaintedTaskPaths() {
        let tasks = [
            IDEProjectTask(path: "build", name: "build", module: ":", group: "build", summary: ""),
            IDEProjectTask(path: "run:App", name: "run App", module: ":", group: "run", summary: ""),
            IDEProjectTask(path: "clean", name: "clean", module: ":", group: "package", summary: ""),
        ]
        let ids = IDEProjectTaskKeyboard.ids(tasks)
        XCTAssertEqual(ids, ["build", "run:App", "clean"])
        XCTAssertEqual(IDEListNeighbor.move(nil, in: ids, by: 1), "build")
        XCTAssertEqual(IDEListNeighbor.move("build", in: ids, by: 1), "run:App")
        XCTAssertEqual(
            IDEListTypeahead.match(
                query: "r", in: ids, selected: nil,
                title: { id in tasks.first { $0.path == id }?.name ?? "" }
            ),
            "run:App"
        )
    }

    func testGitPushKeyboardInsertsFilesUnderTheExpandedCommit() {
        func commit(_ hash: String, _ subject: String) -> GitCommit {
            GitCommit(hash: hash, parents: [], author: "A", email: "a@b", date: .distantPast, refs: [], subject: subject)
        }
        let first = commit("aaa", "Add login")
        let second = commit("bbb", "Fix tests")
        let file = GitChangedFile(status: "M", path: "src/A.java", oldPath: nil)
        let closed = IDEGitPushKeyboard.flatten(commits: [first, second], expanded: nil, files: [:])
        XCTAssertEqual(closed, [.commit("aaa"), .commit("bbb")])
        let open = IDEGitPushKeyboard.flatten(
            commits: [first, second], expanded: "aaa", files: ["aaa": [file]]
        )
        XCTAssertEqual(open, [
            .commit("aaa"), .file(commit: "aaa", path: "src/A.java"), .commit("bbb")
        ])
        XCTAssertEqual(
            IDEListNeighbor.move(.commit("aaa"), in: open, by: 1),
            .file(commit: "aaa", path: "src/A.java")
        )
        XCTAssertEqual(IDEGitPushKeyboard.title(.commit("aaa"), commits: [first, second]), "Add login")
        XCTAssertEqual(
            IDEListTypeahead.match(
                query: "f", in: closed, selected: nil,
                title: { IDEGitPushKeyboard.title($0, commits: [first, second]) }
            ),
            .commit("bbb")
        )
    }

    func testCommandLIsTheAddressShortcutOnlyWithBareCommand() {
        let commandL = keyEvent(keyCode: TestKeyCode.letterL, characters: "l", flags: .command)
        XCTAssertTrue(IDEAIBrowserChromeKeys.isFocusAddress(commandL))
        XCTAssertFalse(IDEAIBrowserChromeKeys.isFocusAddress(keyEvent(keyCode: TestKeyCode.letterL, characters: "l")))
        XCTAssertFalse(IDEAIBrowserChromeKeys.isFocusAddress(
            keyEvent(keyCode: TestKeyCode.letterL, characters: "l", flags: [.command, .shift])
        ))
        XCTAssertFalse(IDEAIBrowserChromeKeys.isWebKitFirstResponder(nil))
        XCTAssertFalse(IDEAIBrowserChromeKeys.isWebKitFirstResponder(NSView()))
    }
}
