import Foundation
import GitIntelligence

/// What a merge tab resolves: one conflicted file and how to title its three sides.
struct IDEMergeRequest: Equatable, Sendable {
    /// Absolute path of the file in the working tree.
    var path: String
    /// Path relative to the repository root, as git knows it.
    var relativePath: String
    var leftTitle: String
    var rightTitle: String
    var tabTitle: String

    var id: String { path }
}

/// Which side a bulk action takes.
enum IDEMergeSide: Sendable {
    case left
    case right
}

/// The state of one three-way merge: the base and both sides as git's index holds them, and the
/// result the user is building. The result is compared with each side separately (as IntelliJ's
/// viewer does), so a chunk stays "to do" until the result matches that side or the user moves on.
@MainActor
final class IDEMergeSession {
    enum State: Equatable {
        case loading
        case ready
        case binary
        case failed(String)
    }

    let request: IDEMergeRequest
    private(set) var state: State = .loading
    private(set) var base = IDEDiffText("")
    private(set) var left = IDEDiffText("")
    private(set) var right = IDEDiffText("")
    private(set) var result = IDEDiffText("")
    /// Left side against the result: `left` ranges are lines of the left pane, `right` ranges lines of the result.
    private(set) var leftChunks: [IDEDiffChunk] = []
    /// Result against the right side: `left` ranges are lines of the result, `right` ranges lines of the right pane.
    private(set) var rightChunks: [IDEDiffChunk] = []
    /// The three-way regions that conflicted when the files were loaded.
    private(set) var originalConflictCount = 0
    private(set) var isApplying = false
    private(set) var applyError: String?

    /// Reads one stage of the file (`.stage(1)` base, 2 ours, 3 theirs).
    var loadContent: ((GitRevision) async -> IDEDiffContent)?
    /// Writes the result to the working tree and stages it. Returns git's complaint, or nil.
    var applyResult: ((String) async -> String?)?
    /// Called after a successful apply, so the host can close the tab.
    var onApplied: (() -> Void)?
    var onTextsLoaded: (() -> Void)?
    var onChunksChanged: (() -> Void)?
    /// The result pane's live text.
    var currentResultText: (() -> String)?

    private var recomputeTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var generation = 0

    init(request: IDEMergeRequest) {
        self.request = request
    }

    deinit {
        recomputeTask?.cancel()
        loadTask?.cancel()
    }

    // MARK: - Loading

    func load() {
        loadTask?.cancel()
        state = .loading
        onTextsLoaded?()
        guard let loadContent else { return }
        loadTask = Task { [weak self] in
            let b = await loadContent(.stage(1))
            let l = await loadContent(.stage(2))
            let r = await loadContent(.stage(3))
            guard let self, !Task.isCancelled else { return }
            self.finishLoading(base: b, left: l, right: r)
        }
    }

    private func finishLoading(base b: IDEDiffContent, left l: IDEDiffContent, right r: IDEDiffContent) {
        if case .failed(let message) = [b, l, r].first(where: { if case .failed = $0 { true } else { false } }) ?? .binary {
            state = .failed(message)
            onTextsLoaded?()
            return
        }
        if [b, l, r].contains(where: { if case .binary = $0 { true } else { false } }) {
            state = .binary
            onTextsLoaded?()
            return
        }
        guard case .text(let baseText) = b, case .text(let leftText) = l, case .text(let rightText) = r else {
            state = .failed("The file could not be read.")
            onTextsLoaded?()
            return
        }
        base = IDEDiffText(baseText)
        left = IDEDiffText(leftText)
        right = IDEDiffText(rightText)
        let regions = IDEMergeComputer.chunks(base: base, left: left, right: right)
        originalConflictCount = IDEMergeComputer.conflictCount(regions)
        result = IDEDiffText(IDEMergeComputer.merged(base: base, left: left, right: right, chunks: regions))
        state = .ready
        recompute(immediately: true)
        onTextsLoaded?()
    }

    // MARK: - Chunks

    /// The result text changed (an edit, or a chunk accepted): compare again after a short pause.
    func resultTextDidChange() {
        recompute(immediately: false)
    }

    private func recompute(immediately: Bool) {
        recomputeTask?.cancel()
        generation += 1
        let token = generation
        let current = currentResultText?() ?? result.string
        let leftText = left
        let rightText = right
        recomputeTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: .milliseconds(120)) }
            guard !Task.isCancelled else { return }
            let resultText = IDEDiffText(current)
            let (leftChunks, rightChunks) = await Task.detached(priority: .userInitiated) {
                (
                    IDEDiffComputer.lineChunks(left: leftText, right: resultText, maximumMiddle: IDEMergeComputer.defaultMaximumMiddle),
                    IDEDiffComputer.lineChunks(left: resultText, right: rightText, maximumMiddle: IDEMergeComputer.defaultMaximumMiddle)
                )
            }.value
            guard let self, !Task.isCancelled, token == self.generation else { return }
            self.result = resultText
            self.leftChunks = leftChunks
            self.rightChunks = rightChunks
            self.onChunksChanged?()
        }
    }

    /// Whether `chunk` (a left-vs-result chunk) and some right-vs-result chunk both want the same
    /// result lines: that is a conflict somebody has to decide.
    func isConflicting(leftChunkAt index: Int) -> Bool {
        guard leftChunks.indices.contains(index) else { return false }
        let range = leftChunks[index].right
        return rightChunks.contains { Self.overlaps(range, $0.left) }
    }

    func isConflicting(rightChunkAt index: Int) -> Bool {
        guard rightChunks.indices.contains(index) else { return false }
        let range = rightChunks[index].left
        return leftChunks.contains { Self.overlaps($0.right, range) }
    }

    /// Conflicts still open: left changes that overlap a right change in the result.
    var unresolvedCount: Int {
        leftChunks.indices.filter { isConflicting(leftChunkAt: $0) }.count
    }

    static func overlaps(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
        if a.isEmpty && b.isEmpty { return a.lowerBound == b.lowerBound }
        if a.isEmpty { return b.lowerBound <= a.lowerBound && a.lowerBound <= b.upperBound }
        if b.isEmpty { return a.lowerBound <= b.lowerBound && b.lowerBound <= a.upperBound }
        return a.lowerBound < b.upperBound && b.lowerBound < a.upperBound
    }

    /// Result lines (0-based) where each open change starts, in order: where F7 and ⇧F7 go.
    var changeStartLines: [Int] {
        let starts = leftChunks.map(\.right.lowerBound) + rightChunks.map(\.left.lowerBound)
        return Array(Set(starts)).sorted()
    }

    // MARK: - Text for the viewer

    /// The result text a chunk of the left or right pane would put in place of `resultRange`.
    func replacement(forLeftChunkAt index: Int) -> (range: NSRange, text: String)? {
        guard leftChunks.indices.contains(index) else { return nil }
        let chunk = leftChunks[index]
        let text = (left.string as NSString).substring(with: left.range(ofLines: chunk.left))
        return (result.range(ofLines: chunk.right), text)
    }

    func replacement(forRightChunkAt index: Int) -> (range: NSRange, text: String)? {
        guard rightChunks.indices.contains(index) else { return nil }
        let chunk = rightChunks[index]
        let text = (right.string as NSString).substring(with: right.range(ofLines: chunk.right))
        return (result.range(ofLines: chunk.left), text)
    }

    // MARK: - Apply

    func apply() {
        guard state == .ready, !isApplying, let applyResult else { return }
        isApplying = true
        applyError = nil
        let text = currentResultText?() ?? result.string
        Task { [weak self] in
            let error = await applyResult(text)
            guard let self else { return }
            self.isApplying = false
            self.applyError = error
            if error == nil {
                self.onApplied?()
            } else {
                self.onChunksChanged?()
            }
        }
    }

    func cancel() {
        recomputeTask?.cancel()
        loadTask?.cancel()
    }
}
