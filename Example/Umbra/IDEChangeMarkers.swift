import Foundation
import GitIntelligence
import Observation
import Penumbra

/// Which lines of a buffer differ from `HEAD`, as gutter change marks.
///
/// Pure. A missing `HEAD` blob (a new file) is one added span. A NUL in the first 8 KB of either
/// side is treated as binary and draws nothing. The line diff is ``IDEDiffComputer/lineChunks``,
/// which skips Myers when the uncommon middle is longer than ``maximumMiddleLineCount``.
enum IDEChangeMarkerPresentation {
    static let maximumMiddleLineCount = 20_000
    private static let binaryPrefix = 8 * 1024

    static func changes(head: Data?, buffer: String, maximumMiddle: Int = maximumMiddleLineCount) -> [GutterChange] {
        if containsNUL(buffer.utf8.prefix(binaryPrefix)) { return [] }
        if let head, containsNUL(head.prefix(binaryPrefix)) { return [] }
        guard let head else {
            let count = IDEDiffText(buffer).lineCount
            return count > 0 ? [GutterChange(line: 1, lineCount: count, kind: .added)] : []
        }
        let chunks = IDEDiffComputer.lineChunks(
            left: IDEDiffText(String(decoding: head, as: UTF8.self)),
            right: IDEDiffText(buffer),
            maximumMiddle: maximumMiddle
        )
        return coalesce(chunks.map(change(from:)))
    }

    private static func change(from chunk: IDEDiffChunk) -> GutterChange {
        switch chunk.kind {
        case .inserted:
            return GutterChange(line: chunk.right.lowerBound + 1, lineCount: chunk.right.count, kind: .added)
        case .deleted:
            return GutterChange(line: chunk.right.lowerBound + 1, lineCount: 0, kind: .deleted, deletedLineCount: chunk.left.count)
        case .modified:
            return GutterChange(line: chunk.right.lowerBound + 1, lineCount: chunk.right.count, kind: .modified)
        }
    }

    private static func coalesce(_ changes: [GutterChange]) -> [GutterChange] {
        var result: [GutterChange] = []
        for change in changes {
            guard let last = result.last else {
                result.append(change)
                continue
            }
            if change.kind != .deleted, last.kind == change.kind, change.line == last.line + last.lineCount {
                result[result.count - 1] = GutterChange(line: last.line, lineCount: last.lineCount + change.lineCount, kind: last.kind)
            } else {
                result.append(change)
            }
        }
        return result
    }

    private static func containsNUL<S: Sequence>(_ bytes: S) -> Bool where S.Element == UInt8 {
        bytes.contains(0)
    }
}

/// The gutter stripe of lines that differ from `HEAD` (Git ▸ Highlight Changed Lines).
///
/// On by default inside a repository. One diff per editor runs after typing pauses, off the main
/// actor, against a cached `HEAD` blob. A result for a buffer the user has since changed is
/// dropped. Edits mark the touched lines in the stripe immediately; the diff replaces that guess.
@MainActor
@Observable
final class IDEChangeMarkerController {
    static let defaultsKey = "umbra.editor.highlightChangedLines"
    static let typingDelay: Duration = .milliseconds(400)

    private(set) var isEnabled: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    @ObservationIgnored private var stamps: [ObjectIdentifier: Stamp] = [:]
    @ObservationIgnored private var headCache: [String: CachedHead] = [:]

    private struct Stamp: Equatable {
        let path: String
        let generation: UInt64
    }

    private enum CachedHead {
        case missing
        case blob(Data)
    }

    private struct HeadRead: Sendable {
        var data: Data?
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.defaultsKey) == nil {
            isEnabled = true
        } else {
            isEnabled = defaults.bool(forKey: Self.defaultsKey)
        }
    }

    func toggle() {
        isEnabled.toggle()
        defaults.set(isEnabled, forKey: Self.defaultsKey)
        stamps.removeAll()
    }

    /// `HEAD` moved (commit, checkout, pull): the cached blobs no longer match.
    func invalidateHeadCache() {
        headCache.removeAll()
        stamps.removeAll()
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        stamps.removeAll()
    }

    /// Hides the stripe and drops any diff still running for `textView`.
    func hide(on textView: TextView) {
        let key = ObjectIdentifier(textView)
        tasks[key]?.cancel()
        tasks[key] = nil
        stamps[key] = nil
        textView.showsGutterChangeStripe = false
        textView.clearGutterChanges()
    }

    /// Fills the stripe of `textView` (showing `url`) when the feature is on and the file is in
    /// the repository. `force` skips the "nothing changed" check. `delay` waits before reading the
    /// buffer, so a burst of keystrokes starts one diff.
    func refresh(
        textView: TextView,
        url: URL?,
        git: IDEGitStatusModel,
        force: Bool = false,
        delay: Duration = typingDelay
    ) {
        let key = ObjectIdentifier(textView)
        guard isEnabled, let url, git.isRepository,
              let relative = git.repositoryRelativePath(for: url.path),
              git.status(for: url, isDirectory: false) != .ignored
        else {
            hide(on: textView)
            return
        }
        let generation = textView.contentGeneration
        if !force, stamps[key] == Stamp(path: relative, generation: generation), textView.showsGutterChangeStripe {
            return
        }
        tasks[key]?.cancel()
        textView.showsGutterChangeStripe = true
        tasks[key] = Task { [weak self, weak textView] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let self, let textView else { return }
            guard self.isEnabled, git.isRepository, git.repositoryRelativePath(for: url.path) == relative,
                  git.status(for: url, isDirectory: false) != .ignored
            else {
                self.hide(on: textView)
                return
            }
            let generation = textView.contentGeneration
            // Captured here, materialized off the main actor. Never `textView.text`.
            let export = textView.exportDocumentText()
            guard let head = await self.readHead(relativePath: relative, git: git) else { return }
            guard !Task.isCancelled, textView.contentGeneration == generation else { return }
            let blob = head.data
            let changes = await Task.detached {
                IDEChangeMarkerPresentation.changes(head: blob, buffer: export.materializeUTF16Text())
            }.value
            guard !Task.isCancelled, textView.contentGeneration == generation, self.isEnabled else { return }
            textView.setGutterChanges(changes)
            self.stamps[key] = Stamp(path: relative, generation: generation)
            self.tasks[key] = nil
        }
    }

    private func readHead(relativePath: String, git: IDEGitStatusModel) async -> HeadRead? {
        if let cached = headCache[relativePath] {
            switch cached {
            case .missing: return HeadRead(data: nil)
            case .blob(let data): return HeadRead(data: data)
            }
        }
        let read = await git.headContents(relativePath: relativePath)
        guard read.found else { return nil }
        headCache[relativePath] = read.data.map { CachedHead.blob($0) } ?? .missing
        return HeadRead(data: read.data)
    }
}
