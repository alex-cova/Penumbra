import Foundation
@testable import Penumbra
import XCTest
import TestTreeSitterLanguages

final class FoldingControllerTests: XCTestCase {
    func testFullRecomputeIsSkippedForVeryLargeDocuments() {
        let originalLimit = EditorPerformanceConstants.maxFoldRecomputeLineCount
        EditorPerformanceConstants.maxFoldRecomputeLineCount = 4
        defer { EditorPerformanceConstants.maxFoldRecomputeLineCount = originalLimit }

        let (foldingController, _, _) = makeFoldingController(text: """
        func foo() {
            let x = 1
            let y = 2
        }
        let after = 3
        """)
        foldingController.isEnabled = true
        foldingController.recomputeIfNeeded()
        XCTAssertTrue(foldingController.folds.isEmpty)
        XCTAssertEqual(foldingController.lastScannedLineCount, 0)
    }

    func testIndentationProviderComputesNestedFold() {
        let (foldingController, _, _) = makeFoldingController(text: """
        func foo() {
            let x = 1
            let y = 2
        }
        let after = 3
        """)
        foldingController.isEnabled = true
        foldingController.recomputeIfNeeded()
        XCTAssertEqual(foldingController.folds.count, 1)
        XCTAssertEqual(foldingController.folds.first?.lineRange, 0 ... 2)
        XCTAssertEqual(foldingController.folds.first?.isCollapsed, false)
    }

    func testCollapsingHidesLinesAndZeroesTheirHeight() {
        let (foldingController, lineManager, _) = makeFoldingController(text: """
        func foo() {
            let x = 1
            let y = 2
        }
        let after = 3
        """)
        foldingController.isEnabled = true
        foldingController.recomputeIfNeeded()
        let fold = try! XCTUnwrap(foldingController.folds.first)
        let contentHeightBeforeCollapse = lineManager.contentHeight
        foldingController.toggleCollapse(fold)
        let hiddenLine1 = lineManager.line(atRow: 1)
        let hiddenLine2 = lineManager.line(atRow: 2)
        let headerLine = lineManager.line(atRow: 0)
        XCTAssertTrue(foldingController.isLineHidden(hiddenLine1.id))
        XCTAssertTrue(foldingController.isLineHidden(hiddenLine2.id))
        XCTAssertFalse(foldingController.isLineHidden(headerLine.id))
        XCTAssertEqual(hiddenLine1.data.lineHeight, 0)
        XCTAssertEqual(hiddenLine2.data.lineHeight, 0)
        XCTAssertGreaterThan(headerLine.data.lineHeight, 0)
        XCTAssertLessThan(lineManager.contentHeight, contentHeightBeforeCollapse)
        XCTAssertNotNil(foldingController.collapsedFold(withHeaderLineID: headerLine.id))
    }

    func testExpandingRestoresVisibilityAndPositiveHeight() {
        let (foldingController, lineManager, _) = makeFoldingController(text: """
        func foo() {
            let x = 1
            let y = 2
        }
        let after = 3
        """)
        foldingController.isEnabled = true
        foldingController.recomputeIfNeeded()
        let fold = try! XCTUnwrap(foldingController.folds.first)
        foldingController.toggleCollapse(fold)
        let toggledFold = try! XCTUnwrap(foldingController.folds.first)
        foldingController.toggleCollapse(toggledFold)
        let hiddenLine1 = lineManager.line(atRow: 1)
        let hiddenLine2 = lineManager.line(atRow: 2)
        XCTAssertFalse(foldingController.isLineHidden(hiddenLine1.id))
        XCTAssertFalse(foldingController.isLineHidden(hiddenLine2.id))
        XCTAssertGreaterThan(hiddenLine1.data.lineHeight, 0)
        XCTAssertGreaterThan(hiddenLine2.data.lineHeight, 0)
    }

    func testExpandingOuterFoldKeepsCollapsedInnerFoldHidden() {
        let (foldingController, lineManager, _) = makeFoldingController(text: """
        func outer() {
            func inner() {
                let x = 1
            }
        }
        """)
        foldingController.isEnabled = true
        foldingController.recomputeIfNeeded()
        XCTAssertGreaterThanOrEqual(foldingController.folds.count, 2)
        let inner = foldingController.folds.max(by: { $0.depth < $1.depth })!
        foldingController.toggleCollapse(inner)
        let outer = foldingController.folds.min(by: { $0.depth < $1.depth })!
        foldingController.toggleCollapse(outer)
        let expandedOuter = foldingController.folds.min(by: { $0.depth < $1.depth })!
        foldingController.toggleCollapse(expandedOuter)
        let innerBody = lineManager.line(atRow: 2)
        XCTAssertTrue(foldingController.isLineHidden(innerBody.id))
        XCTAssertEqual(innerBody.data.lineHeight, 0)
    }

    func testDisablingFoldingExpandsEverything() {
        let (foldingController, lineManager, _) = makeFoldingController(text: """
        func foo() {
            let x = 1
            let y = 2
        }
        let after = 3
        """)
        foldingController.isEnabled = true
        foldingController.recomputeIfNeeded()
        let fold = try! XCTUnwrap(foldingController.folds.first)
        foldingController.toggleCollapse(fold)
        XCTAssertTrue(foldingController.isLineHidden(lineManager.line(atRow: 1).id))

        foldingController.isEnabled = false

        XCTAssertFalse(foldingController.isLineHidden(lineManager.line(atRow: 1).id))
        XCTAssertGreaterThan(lineManager.line(atRow: 1).data.lineHeight, 0)
    }

    func testCollapsingAdjustsSelectionInsideHiddenLines() {
        let (foldingController, lineManager, _) = makeFoldingController(text: """
        func foo() {
            let x = 1
            let y = 2
        }
        let after = 3
        """)
        foldingController.isEnabled = true
        foldingController.recomputeIfNeeded()
        let fold = try! XCTUnwrap(foldingController.folds.first)
        let hiddenLine = lineManager.line(atRow: 1)
        let caretInsideFold = hiddenLine.location + 1
        foldingController.toggleCollapse(fold)
        let adjusted = foldingController.adjustedSelection(NSRange(location: caretInsideFold, length: 0))
        let headerLine = lineManager.line(atRow: 0)
        XCTAssertEqual(adjusted.location, headerLine.location + headerLine.data.length)
        XCTAssertEqual(adjusted.length, 0)
    }

    func testVisibleCaretLocationUsesHeaderLineWhenInsideHiddenFold() {
        let (foldingController, lineManager, stringView) = makeFoldingController(text: """
        func foo() {
            let x = 1
        }
        """)
        foldingController.isEnabled = true
        foldingController.recomputeIfNeeded()
        let fold = try! XCTUnwrap(foldingController.folds.first)
        foldingController.toggleCollapse(fold)
        let hiddenLine = lineManager.line(atRow: 1)
        let caretRectService = CaretRectService(stringView: stringView,
                                                 lineManager: lineManager,
                                                 lineControllerStorage: makeLineControllerStorage(stringView: stringView, lineManager: lineManager),
                                                 gutterWidthService: GutterWidthService(lineManager: lineManager))
        caretRectService.foldingController = foldingController
        let hiddenLocation = hiddenLine.location + 1
        let headerEndLocation = lineManager.line(atRow: 0).location + lineManager.line(atRow: 0).data.length
        let hiddenCaretRect = caretRectService.caretRect(at: hiddenLocation, allowMovingCaretToNextLineFragment: false)
        let headerCaretRect = caretRectService.caretRect(at: headerEndLocation, allowMovingCaretToNextLineFragment: false)
        XCTAssertEqual(hiddenCaretRect.origin.y, headerCaretRect.origin.y, accuracy: 0.01)
    }

    func testNavigationLocationsSkipCollapsedFold() {
        let text = """
        func foo() {
            let x = 1
            let y = 2
        }
        let after = 3
        """
        let (foldingController, lineManager, _) = makeFoldingController(text: text)
        foldingController.isEnabled = true
        foldingController.recomputeIfNeeded()
        let fold = try! XCTUnwrap(foldingController.folds.first)
        foldingController.toggleCollapse(fold)
        let hiddenLine = lineManager.line(atRow: 1)
        let hiddenLocation = hiddenLine.location + 1
        let jumpedLocation = foldingController.visibleLocationForForwardNavigation(from: hiddenLocation)
        let firstVisibleLineAfterFold = lineManager.line(atRow: 3)
        XCTAssertEqual(jumpedLocation, firstVisibleLineAfterFold.location)
        let backwardLocation = foldingController.visibleLocationForBackwardNavigation(from: hiddenLocation)
        let headerLine = lineManager.line(atRow: 0)
        XCTAssertEqual(backwardLocation, headerLine.location + headerLine.data.length)
    }

    func testVerticalCaretMovementSkipsCollapsedFold() {
        let text = """
        func foo() {
            let x = 1
            let y = 2
        }
        let after = 3
        """
        let (foldingController, lineManager, stringView) = makeFoldingController(text: text)
        foldingController.isEnabled = true
        foldingController.recomputeIfNeeded()
        let fold = try! XCTUnwrap(foldingController.folds.first)
        foldingController.toggleCollapse(fold)
        let lineControllerStorage = LineControllerStorage(stringView: stringView,
                                                           lineControllerFactory: LineControllerFactory(
                                                               stringView: stringView,
                                                               highlightService: HighlightService(lineManager: lineManager),
                                                               invisibleCharacterConfiguration: InvisibleCharacterConfiguration()))
        let movementController = LineMovementController(lineManager: lineManager,
                                                         stringView: stringView,
                                                         lineControllerStorage: lineControllerStorage)
        movementController.foldingController = foldingController
        // Force layout of every line so line-fragment-dependent vertical movement has real data.
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

    func testIncrementalRecomputeScansAWindowNotTheWholeDocument() {
        var text = ""
        for index in 0..<60 {
            text += "func f\(index)() {\n    let x = \(index)\n}\n"
        }
        let (foldingController, lineManager, stringView) = makeFoldingController(text: text)
        foldingController.isEnabled = true
        foldingController.recomputeIfNeeded()
        XCTAssertEqual(foldingController.lastScannedLineCount, lineManager.lineCount)
        XCTAssertGreaterThan(foldingController.folds.count, 40)

        let helper = TextEditHelper(stringView: stringView, lineManager: lineManager, lineEndings: .lf)
        let firstBody = lineManager.line(atRow: 1)
        let result = helper.replaceText(in: NSRange(location: firstBody.location, length: firstBody.data.length), with: "    let x = 99")
        let rows = try! XCTUnwrap(result.lineChangeSet.affectedRowRange(lineCount: lineManager.lineCount))
        foldingController.setNeedsRecompute(rows: rows)
        foldingController.recomputeIfNeeded()
        XCTAssertLessThan(foldingController.lastScannedLineCount, 20, "a one-line edit must not rescan the whole document")
        XCTAssertGreaterThan(foldingController.folds.count, 40)
    }

    func testIncrementalRecomputePreservesADistantCollapsedFold() {
        var text = ""
        for index in 0..<40 {
            text += "func f\(index)() {\n    let x = \(index)\n}\n"
        }
        let (foldingController, lineManager, stringView) = makeFoldingController(text: text)
        foldingController.isEnabled = true
        foldingController.recomputeIfNeeded()
        let lastFold = try! XCTUnwrap(foldingController.folds.max(by: { $0.lineRange.lowerBound < $1.lineRange.lowerBound }))
        foldingController.toggleCollapse(lastFold)
        let collapsedHeaderID = lineManager.line(atRow: lastFold.lineRange.lowerBound).id
        XCTAssertNotNil(foldingController.collapsedFold(withHeaderLineID: collapsedHeaderID))

        let helper = TextEditHelper(stringView: stringView, lineManager: lineManager, lineEndings: .lf)
        let firstBody = lineManager.line(atRow: 1)
        let result = helper.replaceText(in: NSRange(location: firstBody.location, length: firstBody.data.length), with: "    let x = 99")
        let rows = try! XCTUnwrap(result.lineChangeSet.affectedRowRange(lineCount: lineManager.lineCount))
        foldingController.setNeedsRecompute(rows: rows)
        foldingController.recomputeIfNeeded()
        XCTAssertNotNil(foldingController.collapsedFold(withHeaderLineID: collapsedHeaderID))
        XCTAssertTrue(foldingController.isLineHidden(lineManager.line(atRow: lastFold.lineRange.lowerBound + 1).id))
    }

    /// Recomputing with nothing collapsed used to create a line handle for every hidden row of
    /// every (nested) fold on each edit: ~10 ms per Enter in a 20k-line Java file. Uses the
    /// tree-sitter provider, as Umbra does for code.
    func testRecomputeWithoutCollapsedFoldsCreatesNoLineHandlesForFoldBodies() {
        var text = "class Outer {\n"
        for index in 0..<200 {
            text += "  f\(index)() {\n    let x = \(index)\n    let y = x\n  }\n"
        }
        text += "}\n"
        let (foldingController, lineManager, stringView, languageMode) = makeTreeSitterFoldingController(text: text)
        // Like an opened document: `insert` made a handle per line, a rebuild starts clean.
        lineManager.rebuild()
        foldingController.isEnabled = true
        lineManager.resetHandleCounters()
        foldingController.recomputeIfNeeded()
        XCTAssertGreaterThan(foldingController.folds.count, 200)
        XCTAssertLessThan(lineManager.handlesCreated, 16, "full recompute")

        let helper = TextEditHelper(stringView: stringView, lineManager: lineManager, lineEndings: .lf)
        let body = lineManager.line(atRow: 2)
        let result = helper.replaceText(in: NSRange(location: body.location, length: body.data.length), with: "    let x = 99")
        _ = languageMode.textDidChange(result.textChange)
        foldingController.foldProvider.invalidateForEdit(
            changedRows: result.lineChangeSet.affectedRowRange(lineCount: lineManager.lineCount),
            lineCount: lineManager.lineCount,
            previousLineCount: lineManager.lineCount,
            spliceRow: result.lineChangeSet.spliceRow ?? 0
        )
        let rows = try! XCTUnwrap(result.lineChangeSet.affectedRowRange(lineCount: lineManager.lineCount))
        lineManager.resetHandleCounters()
        foldingController.setNeedsRecompute(rows: rows)
        foldingController.recomputeIfNeeded()
        XCTAssertGreaterThan(foldingController.folds.count, 200)
        XCTAssertLessThan(lineManager.handlesCreated, 16, "incremental recompute after an edit")
    }

    /// The indentation provider (plain text and languages without a tree-sitter fold provider)
    /// used to read every scanned row through a line handle.
    func testIndentationProviderRecomputeCreatesNoLineHandles() {
        var text = "class Outer {\n"
        for index in 0..<200 {
            text += "    func f\(index)() {\n        let x = \(index)\n\n        let y = x\n    }\n"
        }
        text += "}\n"
        let (foldingController, lineManager, _) = makeFoldingController(text: text)
        lineManager.rebuild()
        foldingController.isEnabled = true
        lineManager.resetHandleCounters()
        foldingController.recomputeIfNeeded()
        XCTAssertEqual(foldingController.folds.count, 201)
        XCTAssertLessThan(lineManager.handlesCreated, 16)
    }

    func testNewlineInsideAFoldShiftsLaterFolds() {
        let text = """
        func first() {
            let x = 1
        }
        func second() {
            let y = 2
        }
        """
        let (foldingController, lineManager, stringView) = makeFoldingController(text: text)
        foldingController.isEnabled = true
        foldingController.recomputeIfNeeded()
        XCTAssertEqual(foldingController.folds.count, 2)
        let secondStart = foldingController.folds[1].lineRange.lowerBound
        let helper = TextEditHelper(stringView: stringView, lineManager: lineManager, lineEndings: .lf)
        let firstBody = lineManager.line(atRow: 1)
        let result = helper.replaceText(in: NSRange(location: firstBody.location + firstBody.data.length, length: 0), with: "\n    let z = 3")
        foldingController.applyLineDelta(at: result.lineChangeSet.spliceRow ?? 1, delta: result.lineChangeSet.insertedLines.count)
        let rows = try! XCTUnwrap(result.lineChangeSet.affectedRowRange(lineCount: lineManager.lineCount))
        foldingController.setNeedsRecompute(rows: rows)
        foldingController.recomputeIfNeeded()
        XCTAssertEqual(foldingController.folds.count, 2)
        XCTAssertEqual(foldingController.folds[1].lineRange.lowerBound, secondStart + 1)
    }

    func testTreeSitterProviderEditDoesNotDropDistantFolds() {
        let text = """
        function foo() {
          let x = 1
        }
        function bar() {
          let y = 2
        }
        """
        let (foldingController, lineManager, stringView, languageMode) = makeTreeSitterFoldingController(text: text)
        XCTAssertNotNil(languageMode.rootSyntaxNode)
        foldingController.isEnabled = true
        foldingController.recomputeIfNeeded()
        XCTAssertGreaterThanOrEqual(foldingController.folds.count, 2)

        let helper = TextEditHelper(stringView: stringView, lineManager: lineManager, lineEndings: .lf)
        let fooBody = lineManager.line(atRow: 1)
        let result = helper.replaceText(in: NSRange(location: fooBody.location, length: fooBody.data.length), with: "  let x = 99")
        _ = languageMode.textDidChange(result.textChange)
        foldingController.foldProvider.invalidateForEdit(
            changedRows: result.lineChangeSet.affectedRowRange(lineCount: lineManager.lineCount),
            lineCount: lineManager.lineCount,
            previousLineCount: lineManager.lineCount,
            spliceRow: result.lineChangeSet.spliceRow ?? 0
        )
        let rows = try! XCTUnwrap(result.lineChangeSet.affectedRowRange(lineCount: lineManager.lineCount))
        foldingController.setNeedsRecompute(rows: rows)
        foldingController.recomputeIfNeeded()
        XCTAssertGreaterThanOrEqual(foldingController.folds.count, 2)
        XCTAssertLessThan(foldingController.lastScannedLineCount, lineManager.lineCount)
    }
}

private extension FoldingControllerTests {
    private func makeLineControllerStorage(stringView: StringView, lineManager: LineManager) -> LineControllerStorage {
        LineControllerStorage(stringView: stringView,
                              lineControllerFactory: LineControllerFactory(stringView: stringView,
                                                                           highlightService: HighlightService(lineManager: lineManager),
                                                                           invisibleCharacterConfiguration: InvisibleCharacterConfiguration()))
    }

    private func makeFoldingController(text: String) -> (FoldingController, LineManager, StringView) {
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
        let foldingController = FoldingController(lineManager: lineManager,
                                                   stringView: stringView,
                                                   lineControllerStorage: lineControllerStorage,
                                                   contentSizeService: contentSizeService)
        return (foldingController, lineManager, stringView)
    }

    private func makeTreeSitterFoldingController(text: String) -> (FoldingController, LineManager, StringView, TreeSitterInternalLanguageMode) {
        let (foldingController, lineManager, stringView) = makeFoldingController(text: text)
        let language = TreeSitterLanguage(tree_sitter_javascript())
        let languageMode = TreeSitterInternalLanguageMode(
            language: language.internalLanguage,
            languageProvider: nil,
            stringView: stringView,
            lineManager: lineManager
        )
        languageMode.parse()
        let provider = TreeSitterLineFoldProvider()
        provider.languageMode = languageMode
        foldingController.foldProvider = provider
        return (foldingController, lineManager, stringView, languageMode)
    }
}
