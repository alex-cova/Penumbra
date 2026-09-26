import EditorIntelligence
import Foundation
@testable import Penumbra
import XCTest
import TestTreeSitterLanguages

@MainActor
final class FoldingControllerTests: XCTestCase {
    func testFullRecomputeIsSkippedForVeryLargeDocuments() async {
        let originalLimit = EditorPerformanceConstants.maxFoldRecomputeLineCount
        EditorPerformanceConstants.maxFoldRecomputeLineCount = 4
        defer { EditorPerformanceConstants.maxFoldRecomputeLineCount = originalLimit }

        let (manager, _, _) = makeFoldingStack(text: """
        func foo() {
            let x = 1
            let y = 2
        }
        let after = 3
        """)
        manager.isEnabled = true
        await recompute(manager)
        XCTAssertTrue(manager.foldingModel.regions.isEmpty)
        XCTAssertEqual(manager.lastScannedLineCount, 0)
    }

    func testIndentationProviderComputesNestedFold() async {
        let (manager, _, _) = makeFoldingStack(text: """
        func foo() {
            let x = 1
            let y = 2
        }
        let after = 3
        """)
        manager.isEnabled = true
        await recompute(manager)
        XCTAssertEqual(manager.foldingModel.regions.count, 1)
        XCTAssertEqual(manager.foldingModel.regions.first?.lineRange, 0 ... 2)
        XCTAssertEqual(manager.foldingModel.regions.first?.isCollapsed, false)
    }

    func testCollapsingHidesLinesAndZeroesTheirHeight() async {
        let (manager, lineManager, _) = makeFoldingStack(text: """
        func foo() {
            let x = 1
            let y = 2
        }
        let after = 3
        """)
        manager.isEnabled = true
        await recompute(manager)
        let fold = try! XCTUnwrap(manager.foldingModel.regions.first)
        let contentHeightBeforeCollapse = lineManager.contentHeight
        manager.foldingModel.toggleCollapse(fold)
        let hiddenLine1 = lineManager.line(atRow: 1)
        let hiddenLine2 = lineManager.line(atRow: 2)
        let headerLine = lineManager.line(atRow: 0)
        XCTAssertTrue(manager.foldingModel.isLineHidden(hiddenLine1.id))
        XCTAssertTrue(manager.foldingModel.isLineHidden(hiddenLine2.id))
        XCTAssertFalse(manager.foldingModel.isLineHidden(headerLine.id))
        XCTAssertEqual(hiddenLine1.data.lineHeight, 0)
        XCTAssertEqual(hiddenLine2.data.lineHeight, 0)
        XCTAssertGreaterThan(headerLine.data.lineHeight, 0)
        XCTAssertLessThan(lineManager.contentHeight, contentHeightBeforeCollapse)
        XCTAssertNotNil(manager.foldingModel.collapsedFold(withHeaderLineID: headerLine.id))
    }

    func testExpandingRestoresVisibilityAndPositiveHeight() async {
        let (manager, lineManager, _) = makeFoldingStack(text: """
        func foo() {
            let x = 1
            let y = 2
        }
        let after = 3
        """)
        manager.isEnabled = true
        await recompute(manager)
        let fold = try! XCTUnwrap(manager.foldingModel.regions.first)
        manager.foldingModel.toggleCollapse(fold)
        let toggledFold = try! XCTUnwrap(manager.foldingModel.regions.first)
        manager.foldingModel.toggleCollapse(toggledFold)
        let hiddenLine1 = lineManager.line(atRow: 1)
        let hiddenLine2 = lineManager.line(atRow: 2)
        XCTAssertFalse(manager.foldingModel.isLineHidden(hiddenLine1.id))
        XCTAssertFalse(manager.foldingModel.isLineHidden(hiddenLine2.id))
        XCTAssertGreaterThan(hiddenLine1.data.lineHeight, 0)
        XCTAssertGreaterThan(hiddenLine2.data.lineHeight, 0)
    }

    func testExpandingOuterFoldKeepsCollapsedInnerFoldHidden() async {
        let (manager, lineManager, _) = makeFoldingStack(text: """
        func outer() {
            func inner() {
                let x = 1
            }
        }
        """)
        manager.isEnabled = true
        await recompute(manager)
        XCTAssertGreaterThanOrEqual(manager.foldingModel.regions.count, 2)
        let inner = manager.foldingModel.regions.max(by: { $0.depth < $1.depth })!
        manager.foldingModel.toggleCollapse(inner)
        let outer = manager.foldingModel.regions.min(by: { $0.depth < $1.depth })!
        manager.foldingModel.toggleCollapse(outer)
        let expandedOuter = manager.foldingModel.regions.min(by: { $0.depth < $1.depth })!
        manager.foldingModel.toggleCollapse(expandedOuter)
        let innerBody = lineManager.line(atRow: 2)
        XCTAssertTrue(manager.foldingModel.isLineHidden(innerBody.id))
        XCTAssertEqual(innerBody.data.lineHeight, 0)
    }

    func testDisablingFoldingExpandsEverything() async {
        let (manager, lineManager, _) = makeFoldingStack(text: """
        func foo() {
            let x = 1
            let y = 2
        }
        let after = 3
        """)
        manager.isEnabled = true
        await recompute(manager)
        let fold = try! XCTUnwrap(manager.foldingModel.regions.first)
        manager.foldingModel.toggleCollapse(fold)
        XCTAssertTrue(manager.foldingModel.isLineHidden(lineManager.line(atRow: 1).id))

        manager.isEnabled = false

        XCTAssertFalse(manager.foldingModel.isLineHidden(lineManager.line(atRow: 1).id))
        XCTAssertGreaterThan(lineManager.line(atRow: 1).data.lineHeight, 0)
    }

    func testCollapsingAdjustsSelectionInsideHiddenLines() async {
        let (manager, lineManager, _) = makeFoldingStack(text: """
        func foo() {
            let x = 1
            let y = 2
        }
        let after = 3
        """)
        manager.isEnabled = true
        await recompute(manager)
        let fold = try! XCTUnwrap(manager.foldingModel.regions.first)
        let hiddenLine = lineManager.line(atRow: 1)
        let caretInsideFold = hiddenLine.location + 1
        manager.foldingModel.toggleCollapse(fold)
        let adjusted = manager.foldingModel.adjustedSelection(NSRange(location: caretInsideFold, length: 0))
        let headerLine = lineManager.line(atRow: 0)
        XCTAssertEqual(adjusted.location, headerLine.location + headerLine.data.length)
        XCTAssertEqual(adjusted.length, 0)
    }

    func testVisibleCaretLocationUsesHeaderLineWhenInsideHiddenFold() async {
        let (manager, lineManager, stringView) = makeFoldingStack(text: """
        func foo() {
            let x = 1
        }
        """)
        manager.isEnabled = true
        await recompute(manager)
        let fold = try! XCTUnwrap(manager.foldingModel.regions.first)
        manager.foldingModel.toggleCollapse(fold)
        let caretRectService = CaretRectService(stringView: stringView,
                                                 lineManager: lineManager,
                                                 lineControllerStorage: makeLineControllerStorage(stringView: stringView, lineManager: lineManager),
                                                 gutterWidthService: GutterWidthService(lineManager: lineManager))
        caretRectService.foldingModel = manager.foldingModel
        let hiddenLine = lineManager.line(atRow: 1)
        let hiddenLocation = hiddenLine.location + 1
        let headerEndLocation = lineManager.line(atRow: 0).location + lineManager.line(atRow: 0).data.length
        let hiddenCaretRect = caretRectService.caretRect(at: hiddenLocation, allowMovingCaretToNextLineFragment: false)
        let headerCaretRect = caretRectService.caretRect(at: headerEndLocation, allowMovingCaretToNextLineFragment: false)
        XCTAssertEqual(hiddenCaretRect.origin.y, headerCaretRect.origin.y, accuracy: 0.01)
    }

    func testNavigationLocationsSkipCollapsedFold() async {
        let text = """
        func foo() {
            let x = 1
            let y = 2
        }
        let after = 3
        """
        let (manager, lineManager, _) = makeFoldingStack(text: text)
        manager.isEnabled = true
        await recompute(manager)
        let fold = try! XCTUnwrap(manager.foldingModel.regions.first)
        manager.foldingModel.toggleCollapse(fold)
        let hiddenLine = lineManager.line(atRow: 1)
        let hiddenLocation = hiddenLine.location + 1
        let jumpedLocation = manager.foldingModel.visibleLocationForForwardNavigation(from: hiddenLocation)
        let firstVisibleLineAfterFold = lineManager.line(atRow: 3)
        XCTAssertEqual(jumpedLocation, firstVisibleLineAfterFold.location)
        let backwardLocation = manager.foldingModel.visibleLocationForBackwardNavigation(from: hiddenLocation)
        let headerLine = lineManager.line(atRow: 0)
        XCTAssertEqual(backwardLocation, headerLine.location + headerLine.data.length)
    }

    func testVerticalCaretMovementSkipsCollapsedFold() async {
        let text = """
        func foo() {
            let x = 1
            let y = 2
        }
        let after = 3
        """
        let (manager, lineManager, stringView) = makeFoldingStack(text: text)
        manager.isEnabled = true
        await recompute(manager)
        let fold = try! XCTUnwrap(manager.foldingModel.regions.first)
        manager.foldingModel.toggleCollapse(fold)
        let lineControllerStorage = LineControllerStorage(stringView: stringView,
                                                           lineControllerFactory: LineControllerFactory(
                                                               stringView: stringView,
                                                               highlightService: HighlightService(lineManager: lineManager),
                                                               invisibleCharacterConfiguration: InvisibleCharacterConfiguration()))
        let movementController = LineMovementController(lineManager: lineManager,
                                                         stringView: stringView,
                                                         lineControllerStorage: lineControllerStorage)
        movementController.foldingModel = manager.foldingModel
        for row in 0 ..< lineManager.lineCount {
            let line = lineManager.line(atRow: row)
            let controller = lineControllerStorage.getOrCreateLineController(for: line)
            controller.constrainingWidth = 10_000
            controller.prepareToDisplayString(in: CGRect(x: 0, y: 0, width: 10_000, height: 10_000), syntaxHighlightAsynchronously: false)
        }
        let headerLine = lineManager.line(atRow: 0)
        let locationOnHeaderLine = headerLine.location
        let newLocation = movementController.location(from: locationOnHeaderLine, in: .down, offset: 1)
        let closingBraceLine = lineManager.line(atRow: 3)
        XCTAssertNotNil(newLocation)
        XCTAssertEqual(lineManager.linePosition(at: newLocation!)?.row, closingBraceLine.index)
    }

    func testIncrementalRecomputeScansAWindowNotTheWholeDocument() async {
        var text = ""
        for index in 0..<60 {
            text += "func f\(index)() {\n    let x = \(index)\n}\n"
        }
        let (manager, lineManager, stringView) = makeFoldingStack(text: text)
        manager.isEnabled = true
        await recompute(manager)
        XCTAssertEqual(manager.lastScannedLineCount, lineManager.lineCount)
        XCTAssertGreaterThan(manager.foldingModel.regions.count, 40)

        let helper = TextEditHelper(stringView: stringView, lineManager: lineManager, lineEndings: .lf)
        let firstBody = lineManager.line(atRow: 1)
        let result = helper.replaceText(in: NSRange(location: firstBody.location, length: firstBody.data.length), with: "    let x = 99")
        let rows = try! XCTUnwrap(result.lineChangeSet.affectedRowRange(lineCount: lineManager.lineCount))
        manager.scheduleUpdate(dirtyRows: rows)
        await manager.updateSynchronously()
        XCTAssertLessThan(manager.lastScannedLineCount, 20, "a one-line edit must not rescan the whole document")
        XCTAssertGreaterThan(manager.foldingModel.regions.count, 40)
    }

    func testIncrementalRecomputePreservesADistantCollapsedFold() async {
        var text = ""
        for index in 0..<40 {
            text += "func f\(index)() {\n    let x = \(index)\n}\n"
        }
        let (manager, lineManager, stringView) = makeFoldingStack(text: text)
        manager.isEnabled = true
        await recompute(manager)
        let lastFold = try! XCTUnwrap(manager.foldingModel.regions.max(by: { $0.lineRange.lowerBound < $1.lineRange.lowerBound }))
        manager.foldingModel.toggleCollapse(lastFold)
        let collapsedHeaderID = lineManager.line(atRow: lastFold.lineRange.lowerBound).id
        XCTAssertNotNil(manager.foldingModel.collapsedFold(withHeaderLineID: collapsedHeaderID))

        let helper = TextEditHelper(stringView: stringView, lineManager: lineManager, lineEndings: .lf)
        let firstBody = lineManager.line(atRow: 1)
        let result = helper.replaceText(in: NSRange(location: firstBody.location, length: firstBody.data.length), with: "    let x = 99")
        let rows = try! XCTUnwrap(result.lineChangeSet.affectedRowRange(lineCount: lineManager.lineCount))
        manager.scheduleUpdate(dirtyRows: rows)
        await recompute(manager)
        XCTAssertNotNil(manager.foldingModel.collapsedFold(withHeaderLineID: collapsedHeaderID))
        XCTAssertTrue(manager.foldingModel.isLineHidden(lineManager.line(atRow: lastFold.lineRange.lowerBound + 1).id))
    }

    func testRecomputeWithoutCollapsedFoldsCreatesNoLineHandlesForFoldBodies() async {
        var text = "class Outer {\n"
        for index in 0..<200 {
            text += "  f\(index)() {\n    let x = \(index)\n    let y = x\n  }\n"
        }
        text += "}\n"
        let (manager, lineManager, stringView, languageMode) = makeTreeSitterFoldingStack(text: text)
        lineManager.rebuild()
        manager.isEnabled = true
        lineManager.resetHandleCounters()
        await recompute(manager)
        XCTAssertGreaterThan(manager.foldingModel.regions.count, 200)
        XCTAssertLessThan(lineManager.handlesCreated, 16, "full recompute")

        let helper = TextEditHelper(stringView: stringView, lineManager: lineManager, lineEndings: .lf)
        let body = lineManager.line(atRow: 2)
        let result = helper.replaceText(in: NSRange(location: body.location, length: body.data.length), with: "    let x = 99")
        _ = languageMode.textDidChange(result.textChange)
        manager.invalidateTreeSitterProviderForEdit(
            changedRows: result.lineChangeSet.affectedRowRange(lineCount: lineManager.lineCount),
            lineCount: lineManager.lineCount,
            previousLineCount: lineManager.lineCount,
            spliceRow: result.lineChangeSet.spliceRow ?? 0
        )
        let rows = try! XCTUnwrap(result.lineChangeSet.affectedRowRange(lineCount: lineManager.lineCount))
        lineManager.resetHandleCounters()
        manager.scheduleUpdate(dirtyRows: rows)
        await recompute(manager)
        XCTAssertGreaterThan(manager.foldingModel.regions.count, 200)
        XCTAssertLessThan(lineManager.handlesCreated, 16, "incremental recompute after an edit")
    }

    func testAdjustedSelectionCreatesNoLineHandles() async {
        var text = "class Outer {\n"
        for index in 0..<200 {
            text += "    func f\(index)() {\n        let x = \(index)\n    }\n"
        }
        text += "}\n"
        let (manager, lineManager, _) = makeFoldingStack(text: text)
        lineManager.rebuild()
        manager.isEnabled = true
        await recompute(manager)
        let fold = try! XCTUnwrap(manager.foldingModel.regions.first { $0.lineRange.lowerBound == 1 })
        manager.foldingModel.toggleCollapse(fold)
        lineManager.resetHandleCounters()
        for row in stride(from: 10, to: 600, by: 3) {
            let location = lineManager.location(ofRow: row)
            _ = manager.foldingModel.adjustedSelection(NSRange(location: location, length: 2))
        }
        XCTAssertEqual(lineManager.handlesCreated, 0)

        let hidden = lineManager.location(ofRow: 2) + 3
        let headerEnd = lineManager.contentRange(atRow: 1).upperBound
        XCTAssertEqual(manager.foldingModel.adjustedSelection(NSRange(location: hidden, length: 0)), NSRange(location: headerEnd, length: 0))
    }

    func testIndentationProviderRecomputeCreatesNoLineHandles() async {
        var text = "class Outer {\n"
        for index in 0..<200 {
            text += "    func f\(index)() {\n        let x = \(index)\n\n        let y = x\n    }\n"
        }
        text += "}\n"
        let (manager, lineManager, _) = makeFoldingStack(text: text)
        lineManager.rebuild()
        manager.isEnabled = true
        lineManager.resetHandleCounters()
        await recompute(manager)
        XCTAssertEqual(manager.foldingModel.regions.count, 201)
        XCTAssertLessThan(lineManager.handlesCreated, 16)
    }

    func testNewlineInsideAFoldShiftsLaterFolds() async {
        let text = """
        func first() {
            let x = 1
        }
        func second() {
            let y = 2
        }
        """
        let (manager, lineManager, stringView) = makeFoldingStack(text: text)
        manager.isEnabled = true
        await recompute(manager)
        XCTAssertEqual(manager.foldingModel.regions.count, 2)
        let secondStart = manager.foldingModel.regions[1].lineRange.lowerBound
        let helper = TextEditHelper(stringView: stringView, lineManager: lineManager, lineEndings: .lf)
        let firstBody = lineManager.line(atRow: 1)
        let result = helper.replaceText(in: NSRange(location: firstBody.location + firstBody.data.length, length: 0), with: "\n    let z = 3")
        manager.applyLineDelta(at: result.lineChangeSet.spliceRow ?? 1, delta: result.lineChangeSet.insertedLines.count)
        let rows = try! XCTUnwrap(result.lineChangeSet.affectedRowRange(lineCount: lineManager.lineCount))
        manager.scheduleUpdate(dirtyRows: rows)
        await recompute(manager)
        XCTAssertEqual(manager.foldingModel.regions.count, 2)
        XCTAssertEqual(manager.foldingModel.regions[1].lineRange.lowerBound, secondStart + 1)
    }

    func testTreeSitterProviderEditDoesNotDropDistantFolds() async {
        let text = """
        function foo() {
          let x = 1
        }
        function bar() {
          let y = 2
        }
        """
        let (manager, lineManager, stringView, languageMode) = makeTreeSitterFoldingStack(text: text)
        XCTAssertNotNil(languageMode.rootSyntaxNode)
        manager.isEnabled = true
        await recompute(manager)
        XCTAssertGreaterThanOrEqual(manager.foldingModel.regions.count, 2)

        let helper = TextEditHelper(stringView: stringView, lineManager: lineManager, lineEndings: .lf)
        let fooBody = lineManager.line(atRow: 1)
        let result = helper.replaceText(in: NSRange(location: fooBody.location, length: fooBody.data.length), with: "  let x = 99")
        _ = languageMode.textDidChange(result.textChange)
        manager.invalidateTreeSitterProviderForEdit(
            changedRows: result.lineChangeSet.affectedRowRange(lineCount: lineManager.lineCount),
            lineCount: lineManager.lineCount,
            previousLineCount: lineManager.lineCount,
            spliceRow: result.lineChangeSet.spliceRow ?? 0
        )
        let rows = try! XCTUnwrap(result.lineChangeSet.affectedRowRange(lineCount: lineManager.lineCount))
        manager.scheduleUpdate(dirtyRows: rows)
        await manager.updateSynchronously()
        XCTAssertGreaterThanOrEqual(manager.foldingModel.regions.count, 2)
        XCTAssertLessThan(manager.lastScannedLineCount, lineManager.lineCount)
    }

    func testCollapseAndExpandActions() async {
        let (manager, _, _) = makeFoldingStack(text: """
        func foo() {
            let x = 1
        }
        """)
        manager.isEnabled = true
        await recompute(manager)
        let caret = 0
        manager.foldingModel.collapseRegion(atCaret: caret)
        XCTAssertTrue(manager.foldingModel.regions.first?.isCollapsed == true)
        manager.foldingModel.expandRegion(atCaret: caret)
        XCTAssertTrue(manager.foldingModel.regions.first?.isExpanded == true)
    }

    func testCollapseAllAction() async {
        let (manager, _, _) = makeFoldingStack(text: """
        func foo() {
            let x = 1
        }
        func bar() {
            let y = 2
        }
        """)
        manager.isEnabled = true
        await recompute(manager)
        manager.foldingModel.collapseAllRegions()
        XCTAssertTrue(manager.foldingModel.regions.allSatisfy { $0.isCollapsed })
        manager.foldingModel.expandAllRegions()
        XCTAssertTrue(manager.foldingModel.regions.allSatisfy { $0.isExpanded })
    }

    func testTreeSitterPlaceholderUsesBlockStyle() async {
        let (manager, _, _, languageMode) = makeTreeSitterFoldingStack(text: """
        function foo() {
          let x = 1;
        }
        """)
        _ = languageMode
        manager.isEnabled = true
        await recompute(manager)
        let placeholder = try! XCTUnwrap(manager.foldingModel.regions.first?.placeholder)
        XCTAssertEqual(placeholder, "{...}")
    }
}

private extension FoldingControllerTests {
    private func recompute(_ manager: CodeFoldingManager) async {
        manager.scheduleUpdate(full: true)
        await manager.updateSynchronously()
    }

    private func makeLineControllerStorage(stringView: StringView, lineManager: LineManager) -> LineControllerStorage {
        LineControllerStorage(stringView: stringView,
                              lineControllerFactory: LineControllerFactory(stringView: stringView,
                                                                           highlightService: HighlightService(lineManager: lineManager),
                                                                           invisibleCharacterConfiguration: InvisibleCharacterConfiguration()))
    }

    private func makeFoldingStack(text: String) -> (CodeFoldingManager, LineManager, StringView) {
        let stringView = StringView(string: text)
        let lineManager = LineManager(stringView: stringView)
        lineManager.insert(text as NSString, at: 0)
        let gutterWidthService = GutterWidthService(lineManager: lineManager)
        let lineControllerFactory = LineControllerFactory(stringView: stringView,
                                                           highlightService: HighlightService(lineManager: lineManager),
                                                           invisibleCharacterConfiguration: InvisibleCharacterConfiguration())
        let lineControllerStorage = LineControllerStorage(stringView: stringView, lineControllerFactory: lineControllerFactory)
        let contentSizeService = ContentSizeService(lineManager: lineManager,
                                                    lineControllerStorage: lineControllerStorage,
                                                    gutterWidthService: gutterWidthService,
                                                    invisibleCharacterConfiguration: InvisibleCharacterConfiguration())
        let foldingModel = FoldingModel(lineManager: lineManager,
                                        stringView: stringView,
                                        lineControllerStorage: lineControllerStorage,
                                        contentSizeService: contentSizeService)
        let manager = CodeFoldingManager(foldingModel: foldingModel)
        manager.setProviders(primary: nil)
        return (manager, lineManager, stringView)
    }

    private func makeTreeSitterFoldingStack(text: String) -> (CodeFoldingManager, LineManager, StringView, TreeSitterInternalLanguageMode) {
        let (manager, lineManager, stringView) = makeFoldingStack(text: text)
        let language = TreeSitterLanguage(tree_sitter_javascript())
        let languageMode = TreeSitterInternalLanguageMode(
            language: language.internalLanguage,
            languageProvider: nil,
            stringView: stringView,
            lineManager: lineManager
        )
        languageMode.parse()
        let provider = TreeSitterFoldingProvider()
        provider.languageMode = languageMode
        manager.treeSitterFoldingProvider = provider
        manager.setProviders(primary: provider)
        return (manager, lineManager, stringView, languageMode)
    }
}
