import AppKit
import Foundation
import GitIntelligence
import Observation

enum IDEDiffLayout: String, Sendable {
    case sideBySide
    case unified
}

/// The diff viewer's options, shared by every diff tab and kept across launches.
struct IDEDiffSettings: Equatable {
    var layout: IDEDiffLayout = .sideBySide
    var whitespace: IDEDiffWhitespacePolicy = .none
    var highlight: IDEDiffHighlightMode = .words
    var collapsesUnchanged = false
    var synchronizesScrolling = true

    private static let prefix = "umbra.diff."

    static func load(from defaults: UserDefaults = .standard) -> IDEDiffSettings {
        var settings = IDEDiffSettings()
        if let raw = defaults.string(forKey: prefix + "layout"), let value = IDEDiffLayout(rawValue: raw) { settings.layout = value }
        if let raw = defaults.string(forKey: prefix + "whitespace"), let value = IDEDiffWhitespacePolicy(rawValue: raw) { settings.whitespace = value }
        if let raw = defaults.string(forKey: prefix + "highlight"), let value = IDEDiffHighlightMode(rawValue: raw) { settings.highlight = value }
        if defaults.object(forKey: prefix + "collapse") != nil { settings.collapsesUnchanged = defaults.bool(forKey: prefix + "collapse") }
        if defaults.object(forKey: prefix + "syncScroll") != nil { settings.synchronizesScrolling = defaults.bool(forKey: prefix + "syncScroll") }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(layout.rawValue, forKey: Self.prefix + "layout")
        defaults.set(whitespace.rawValue, forKey: Self.prefix + "whitespace")
        defaults.set(highlight.rawValue, forKey: Self.prefix + "highlight")
        defaults.set(collapsesUnchanged, forKey: Self.prefix + "collapse")
        defaults.set(synchronizesScrolling, forKey: Self.prefix + "syncScroll")
    }
}

/// One side as loaded.
enum IDEDiffContent: Sendable, Equatable {
    case text(String)
    /// Not text (a NUL in its first bytes): there is nothing to compare line by line.
    case binary
    case failed(String)
}

/// What one diff tab shows: the request, both texts and the chunks between them. The texts are
/// loaded and the chunks computed off the main actor; a newer load or edit drops older results.
@MainActor
@Observable
final class IDEDiffSession {
    enum State: Equatable {
        case loading
        case ready
        case binary
        case failed(String)
    }

    private(set) var request: IDEDiffRequest
    /// The files Previous/Next File step through (the Changes list or a commit's files).
    let siblings: [IDEDiffRequest]
    var settings: IDEDiffSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            if settings.whitespace != oldValue.whitespace || settings.highlight != oldValue.highlight {
                recompute()
            } else {
                onPresentationChanged?()
            }
        }
    }
    private(set) var state: State = .loading
    private(set) var left = IDEDiffText("")
    private(set) var right = IDEDiffText("")
    private(set) var chunks: [IDEDiffChunk] = []
    /// The chunk the caret is in or was last moved to, for the "2 of 5" counter.
    var currentChunkIndex: Int?
    /// Set when the right side is the working tree but cannot be edited here (its editor tab
    /// holds unsaved changes).
    private(set) var readOnlyReason: String?
    /// The right side has edits not yet written to disk.
    private(set) var isRightDirty = false
    /// The right text changed and the chunks have not caught up yet: hunk buttons wait.
    private(set) var isStale = false
    private(set) var isBusy = false
    /// A git or save failure to show above the texts.
    private(set) var message: String?

    var isRightEditable: Bool {
        request.isRightEditable && readOnlyReason == nil && state == .ready
    }

    var siblingIndex: Int? {
        siblings.firstIndex { $0.id == request.id }
    }

    // MARK: Host hooks

    /// Reads one side. Supplied by the workspace (git, disk, open editors).
    @ObservationIgnored var loadContent: (@MainActor (IDEDiffSource) async -> IDEDiffContent)?
    /// Why the working tree cannot be edited right now, or nil.
    @ObservationIgnored var readOnlyReasonProvider: (@MainActor (String) -> String?)?
    /// Applies a hunk patch to git's index; the closure reports the failure message, or nil.
    @ObservationIgnored var applyIndexPatch: (@MainActor (String, Bool) async -> String?)?
    /// Called after the right side was written to disk.
    @ObservationIgnored var onSaved: (@MainActor (String) -> Void)?
    /// Called when Previous/Next File swapped the request, so the tab can retitle.
    @ObservationIgnored var onRequestChanged: (@MainActor () -> Void)?
    /// The viewer's hooks: new texts to show, new chunks to paint, options to apply.
    @ObservationIgnored var onTextsLoaded: (() -> Void)?
    @ObservationIgnored var onChunksChanged: (() -> Void)?
    @ObservationIgnored var onPresentationChanged: (() -> Void)?
    /// The viewer's current right text, read when the session needs it (save, stage).
    @ObservationIgnored var currentRightText: (() -> String)?

    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var computeGeneration = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var computeTask: Task<Void, Never>?
    @ObservationIgnored private var editTask: Task<Void, Never>?

    init(request: IDEDiffRequest, siblings: [IDEDiffRequest], settings: IDEDiffSettings = .load()) {
        self.request = request
        self.siblings = siblings.isEmpty ? [request] : siblings
        self.settings = settings
    }

    func cancel() {
        loadTask?.cancel()
        computeTask?.cancel()
        editTask?.cancel()
    }

    // MARK: Loading

    func reload() {
        loadTask?.cancel()
        editTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        let request = request
        if chunks.isEmpty { state = .loading }
        loadTask = Task { [weak self] in
            guard let self, let loadContent = self.loadContent else { return }
            async let leftContent = loadContent(request.left.source)
            async let rightContent = loadContent(request.right.source)
            let (leftLoaded, rightLoaded) = await (leftContent, rightContent)
            guard !Task.isCancelled, generation == self.loadGeneration else { return }
            switch (leftLoaded, rightLoaded) {
            case (.failed(let message), _), (_, .failed(let message)):
                self.state = .failed(message)
                self.chunks = []
                self.onTextsLoaded?()
            case (.binary, _), (_, .binary):
                self.state = .binary
                self.chunks = []
                self.onTextsLoaded?()
            case (.text(let leftText), .text(let rightText)):
                let readOnlyReason = request.workingTreePath.flatMap { self.readOnlyReasonProvider?($0) }
                if self.state == .ready, leftText == self.left.string, rightText == self.right.string {
                    // Nothing moved (a refresh after an unrelated change): keep the views as they are.
                    if readOnlyReason != self.readOnlyReason {
                        self.readOnlyReason = readOnlyReason
                        self.onPresentationChanged?()
                    }
                    return
                }
                self.left = IDEDiffText(leftText)
                self.right = IDEDiffText(rightText)
                self.isRightDirty = false
                self.readOnlyReason = readOnlyReason
                self.state = .ready
                self.onTextsLoaded?()
                self.recompute()
            }
        }
    }

    /// The right text view changed. The chunks follow after a short pause, so typing never waits
    /// for a diff.
    func rightTextDidChange() {
        isRightDirty = true
        isStale = true
        editTask?.cancel()
        editTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled, let text = self.currentRightText?() else { return }
            self.right = IDEDiffText(text)
            self.recompute()
        }
    }

    private func recompute() {
        guard state == .ready else { return }
        computeTask?.cancel()
        computeGeneration += 1
        let generation = computeGeneration
        let left = left
        let right = right
        let whitespace = settings.whitespace
        let highlight = settings.highlight
        computeTask = Task { [weak self] in
            let chunks = await Task.detached(priority: .userInitiated) {
                IDEDiffComputer.chunks(left: left, right: right, whitespace: whitespace, highlight: highlight)
            }.value
            guard let self, !Task.isCancelled, generation == self.computeGeneration else { return }
            self.chunks = chunks
            self.isStale = false
            if let current = self.currentChunkIndex, current >= chunks.count {
                self.currentChunkIndex = chunks.isEmpty ? nil : chunks.count - 1
            }
            self.onChunksChanged?()
        }
    }

    // MARK: Files

    func canMoveToFile(by step: Int) -> Bool {
        guard let index = siblingIndex else { return false }
        return siblings.indices.contains(index + step)
    }

    /// Previous/Next File: shows the neighbouring request in this tab. Unsaved edits are saved
    /// first, as IntelliJ does.
    func moveToFile(by step: Int) {
        guard let index = siblingIndex, siblings.indices.contains(index + step) else { return }
        save()
        request = siblings[index + step]
        state = .loading
        currentChunkIndex = nil
        chunks = []
        message = nil
        onRequestChanged?()
        reload()
    }

    // MARK: Hunks

    /// Stages (or, for HEAD ↔ index, unstages) one chunk through `git apply --cached`.
    func applyToIndex(chunkAt index: Int) {
        guard let action = request.indexAction, chunks.indices.contains(index),
              let path = request.repositoryRelativePath, let applyIndexPatch else { return }
        if isRightDirty, let text = currentRightText?() {
            right = IDEDiffText(text)
        }
        guard let patch = IDEDiffPatchBuilder.patch(for: chunks[index], left: left, right: right, path: path) else {
            message = "Only a final line break changed here; stage the whole file instead."
            return
        }
        isBusy = true
        Task { [weak self] in
            let failure = await applyIndexPatch(patch, action == .unstage)
            guard let self else { return }
            self.isBusy = false
            self.message = failure
            if failure == nil { self.reload() }
        }
    }

    /// Writes the right side to disk when it was edited here.
    func save() {
        guard isRightDirty, let path = request.workingTreePath, let text = currentRightText?() else { return }
        do {
            try text.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
            isRightDirty = false
            message = nil
            onSaved?(path)
        } catch {
            message = "Could not save \((path as NSString).lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: Navigation

    /// The chunk to go to from `line` (0-based, on `rightSide` or the left), or nil past the end.
    func chunkIndex(after line: Int, onRight rightSide: Bool) -> Int? {
        chunks.firstIndex { (rightSide ? $0.right.lowerBound : $0.left.lowerBound) > line }
    }

    func chunkIndex(before line: Int, onRight rightSide: Bool) -> Int? {
        chunks.lastIndex { (rightSide ? $0.right.lowerBound : $0.left.lowerBound) < line }
    }

    /// The chunk covering `line`, or nil.
    func chunkIndex(containing line: Int, onRight rightSide: Bool) -> Int? {
        chunks.firstIndex { chunk in
            let range = rightSide ? chunk.right : chunk.left
            return range.isEmpty ? range.lowerBound == line : range.contains(line)
        }
    }

    /// Maps a line on one side to the other: unchanged lines one to one, a line inside a change
    /// proportionally into the other side's lines. Used for synchronized scrolling and F4.
    func mapLine(_ line: Double, fromRight: Bool) -> Double {
        var delta = 0.0
        for chunk in chunks {
            let from = fromRight ? chunk.right : chunk.left
            let to = fromRight ? chunk.left : chunk.right
            if line < Double(from.lowerBound) {
                return line + delta
            }
            if line < Double(from.upperBound) {
                let fraction = (line - Double(from.lowerBound)) / Double(max(from.count, 1))
                return Double(to.lowerBound) + fraction * Double(to.count)
            }
            delta = Double(to.upperBound) - Double(from.upperBound)
        }
        return line + delta
    }

    func clearMessage() {
        message = nil
    }
}
