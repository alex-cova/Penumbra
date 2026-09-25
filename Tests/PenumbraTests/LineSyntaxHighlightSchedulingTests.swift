@preconcurrency import AppKit
import TestTreeSitterLanguages
import XCTest
@testable import Penumbra

/// Layout used to cancel the in-flight highlight on every `prepareToDisplayString`, so a viewport
/// that laid out at display refresh starved syntax coloring. These tests lock the new rule:
/// cancel only when the line string/default attributes are rebuilt; skip starting a second async
/// job while one is already running.
final class LineSyntaxHighlightSchedulingTests: XCTestCase, LineControllerStorageDelegate, LineControllerDelegate {
    private let highlighter = StickyAsyncHighlighter()

    func lineControllerStorage(_ storage: LineControllerStorage, didCreate lineController: LineController) {
        lineController.delegate = self
        lineController.constrainingWidth = 320
    }

    func lineSyntaxHighlighter(for lineController: LineController) -> LineSyntaxHighlighter? {
        highlighter
    }

    func lineControllerDidInvalidateLineWidthDuringAsyncSyntaxHighlight(_ lineController: LineController) {}

    func lineControllerDidRefreshDisplayedLineFragments(_ lineController: LineController) {}

    func testRepeatedAsyncPrepareDoesNotCancelOrRestartInFlightHighlight() {
        let controller = makeLineController(text: "let value = 42")
        controller.prepareToDisplayString(toLocation: 14, syntaxHighlightAsynchronously: true)
        XCTAssertEqual(highlighter.highlightCount, 1)
        let cancelsAfterFirstPrepare = highlighter.cancelCount

        controller.prepareToDisplayString(toLocation: 14, syntaxHighlightAsynchronously: true)
        XCTAssertEqual(highlighter.highlightCount, 1, "in-flight highlight should not be restarted")
        XCTAssertEqual(highlighter.cancelCount, cancelsAfterFirstPrepare, "in-flight highlight should not be cancelled by a layout pass")
    }

    func testAsyncHighlightCompletionNotifiesDelegateToRefreshDisplayedFragments() {
        let delegate = RefreshCountingDelegate()
        let controller = makeLineController(text: "let value = 42", delegate: delegate)
        controller.prepareToDisplayString(toLocation: 14, syntaxHighlightAsynchronously: true)
        // The completion hops to the main actor; poll instead of trusting a fixed wait under load.
        let deadline = Date().addingTimeInterval(3)
        while delegate.refreshCount == 0, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(delegate.refreshCount, 1, "async highlight completion must refresh Metal/CG paint")
    }

    func testColorOnlyInvalidationHighlightsAgainWithoutCancelling() {
        let controller = makeLineController(text: "let value = 42")
        controller.prepareToDisplayString(toLocation: 14, syntaxHighlightAsynchronously: false)
        XCTAssertEqual(highlighter.highlightCount, 1)
        let cancelsAfterSync = highlighter.cancelCount

        controller.invalidateSyntaxColorsOnly()
        controller.prepareToDisplayString(toLocation: 14, syntaxHighlightAsynchronously: true)
        XCTAssertEqual(highlighter.cancelCount, cancelsAfterSync, "a colour refresh must not rebuild the line string")
        XCTAssertEqual(highlighter.highlightCount, 2)
    }

    func testRebuildingTheLineStringCancelsInFlightHighlight() {
        let controller = makeLineController(text: "let value = 42")
        controller.prepareToDisplayString(toLocation: 14, syntaxHighlightAsynchronously: true)
        XCTAssertEqual(highlighter.highlightCount, 1)

        controller.invalidateEverything()
        controller.prepareToDisplayString(toLocation: 14, syntaxHighlightAsynchronously: true)
        XCTAssertGreaterThan(highlighter.cancelCount, 0)
        XCTAssertEqual(highlighter.highlightCount, 2, "a new highlight should start after the string is rebuilt")
    }

    private func makeLineController(text: String, delegate: LineControllerDelegate? = nil) -> LineController {
        let stringView = StringView(string: text)
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        let factory = LineControllerFactory(
            stringView: stringView,
            highlightService: HighlightService(lineManager: lineManager),
            invisibleCharacterConfiguration: InvisibleCharacterConfiguration()
        )
        let storage = LineControllerStorage(stringView: stringView, lineControllerFactory: factory)
        storage.delegate = self
        let controller = storage.getOrCreateLineController(for: lineManager.line(atRow: 0))
        controller.delegate = delegate ?? self
        return controller
    }
}

/// `canHighlight` must agree with `captures(in:)`: a tree existing is not enough. Before this fix
/// a line could be marked "highlighted" after a query that silently produced zero tokens (an edit
/// forced through the async/no-reparse path), leaving it stuck at `theme.textColor` — the Metal
/// white-flash root cause.
final class TreeSitterHighlightReadinessTests: XCTestCase, LineControllerDelegate {
    func lineSyntaxHighlighter(for lineController: LineController) -> LineSyntaxHighlighter? { nil }
    func lineControllerDidInvalidateLineWidthDuringAsyncSyntaxHighlight(_ lineController: LineController) {}
    func lineControllerDidRefreshDisplayedLineFragments(_ lineController: LineController) {}

    func testCanHighlightIsFalseWhileAnEditSkipsTheSynchronousReparse() {
        let text = "let value = 1;\n"
        let stringView = StringView(string: text)
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        let language = TreeSitterLanguage(tree_sitter_javascript()).internalLanguage
        let languageMode = TreeSitterInternalLanguageMode(
            language: language,
            languageProvider: nil,
            stringView: stringView,
            lineManager: lineManager
        )
        languageMode.parse()
        XCTAssertTrue(languageMode.canHighlight, "a completed sync parse should be highlightable")

        // An edit at or above `maxSyncEditLength` skips the incremental reparse (`ts_tree_edit`
        // only) and marks the initial parse incomplete until a background parse catches up.
        let hugeInsertion = String(repeating: "x", count: TreeSitterPerformanceConstants.maxSyncEditLength + 1)
        let editHelper = TextEditHelper(stringView: stringView, lineManager: lineManager, lineEndings: .lf)
        let editResult = editHelper.replaceText(in: NSRange(location: 0, length: 0), with: hugeInsertion)
        _ = languageMode.textDidChange(editResult.textChange)

        XCTAssertFalse(languageMode.canHighlight, "must not claim highlight-readiness while the reparse is outstanding")
        let fullRange = ByteRange(from: 0, to: (stringView.string as NSString).byteCount)
        XCTAssertTrue(languageMode.captures(in: fullRange).isEmpty, "captures(in:) already returns [] in this state")
    }

    func testLineControllerLeavesHighlightPendingInsteadOfSilentlyMarkingItComplete() {
        let text = "let value = 1;\n"
        let stringView = StringView(string: text)
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        // Needs a real (if trivial) highlights query: `canEventuallyHighlight` is now
        // `false` for a language with none (so Metal doesn't hold stale glyphs waiting on a
        // highlight that can never arrive — see `TreeSitterSyntaxHighlighter.canEventuallyHighlight`),
        // and this test is specifically about the *pending while a reparse is outstanding* case,
        // which only applies when a highlight could eventually land.
        let language = TreeSitterLanguage(
            tree_sitter_javascript(),
            highlightsQuery: TreeSitterLanguage.Query(string: "(identifier) @variable")
        ).internalLanguage
        let languageMode = TreeSitterInternalLanguageMode(
            language: language,
            languageProvider: nil,
            stringView: stringView,
            lineManager: lineManager
        )
        languageMode.parse()
        let highlighter = languageMode.createLineSyntaxHighlighter()

        let factory = LineControllerFactory(
            stringView: stringView,
            highlightService: HighlightService(lineManager: lineManager),
            invisibleCharacterConfiguration: InvisibleCharacterConfiguration()
        )
        let storage = LineControllerStorage(stringView: stringView, lineControllerFactory: factory)
        let delegate = SingleHighlighterDelegate(highlighter: highlighter)
        storage.delegate = delegate
        let controller = storage.getOrCreateLineController(for: lineManager.line(atRow: 0))
        controller.delegate = delegate
        controller.constrainingWidth = 320

        controller.prepareToDisplayString(toLocation: text.utf16.count, syntaxHighlightAsynchronously: false)
        XCTAssertFalse(controller.isSyntaxHighlightPending, "a completed parse should highlight synchronously and not stay pending")

        let hugeInsertion = String(repeating: "x", count: TreeSitterPerformanceConstants.maxSyncEditLength + 1)
        let editHelper = TextEditHelper(stringView: stringView, lineManager: lineManager, lineEndings: .lf)
        let editResult = editHelper.replaceText(in: NSRange(location: 0, length: 0), with: hugeInsertion)
        // Mirror `TextInputView.replaceText`: the language mode observes the edit, then the line
        // controller is invalidated and asked to redisplay synchronously (`redisplayLines`'s
        // contract), exactly the sequence a keystroke drives.
        _ = languageMode.textDidChange(editResult.textChange)
        controller.invalidateEverything()
        controller.prepareToDisplayString(toLocation: 0, syntaxHighlightAsynchronously: false)

        XCTAssertTrue(
            controller.isSyntaxHighlightPending,
            "must stay pending (not silently 'highlighted white') until the background reparse completes"
        )
    }
}

private final class SingleHighlighterDelegate: LineControllerStorageDelegate, LineControllerDelegate {
    private let highlighter: LineSyntaxHighlighter

    init(highlighter: LineSyntaxHighlighter) {
        self.highlighter = highlighter
    }

    func lineControllerStorage(_ storage: LineControllerStorage, didCreate lineController: LineController) {
        lineController.delegate = self
        lineController.constrainingWidth = 320
    }

    func lineSyntaxHighlighter(for lineController: LineController) -> LineSyntaxHighlighter? {
        highlighter
    }

    func lineControllerDidInvalidateLineWidthDuringAsyncSyntaxHighlight(_ lineController: LineController) {}
    func lineControllerDidRefreshDisplayedLineFragments(_ lineController: LineController) {}
}

private final class RefreshCountingDelegate: LineControllerDelegate {
    var refreshCount = 0

    func lineSyntaxHighlighter(for lineController: LineController) -> LineSyntaxHighlighter? {
        CompletingAsyncHighlighter()
    }

    func lineControllerDidInvalidateLineWidthDuringAsyncSyntaxHighlight(_ lineController: LineController) {}

    func lineControllerDidRefreshDisplayedLineFragments(_ lineController: LineController) {
        refreshCount += 1
    }
}

private final class CompletingAsyncHighlighter: LineSyntaxHighlighter {
    var theme: Theme = DefaultTheme()
    var canHighlight: Bool { true }
    var isHighlighting: Bool { false }

    func syntaxHighlight(_ input: LineSyntaxHighlighterInput) {}

    func syntaxHighlight(_ input: LineSyntaxHighlighterInput, completion: @escaping AsyncCallback) {
        input.attributedString.addAttribute(.foregroundColor, value: NSColor.systemPink, range: NSRange(location: 0, length: input.attributedString.length))
        completion(.success(()))
    }

    func cancel() {}
}

private final class StickyAsyncHighlighter: LineSyntaxHighlighter {
    var theme: Theme = DefaultTheme()
    var canHighlight: Bool { true }
    var isHighlighting: Bool {
        highlightCount > 0 && pendingCompletion != nil
    }
    var highlightCount = 0
    var cancelCount = 0
    private var pendingCompletion: AsyncCallback?

    func syntaxHighlight(_ input: LineSyntaxHighlighterInput) {
        highlightCount += 1
    }

    func syntaxHighlight(_ input: LineSyntaxHighlighterInput, completion: @escaping AsyncCallback) {
        highlightCount += 1
        pendingCompletion = completion
    }

    func cancel() {
        cancelCount += 1
        pendingCompletion = nil
    }
}
