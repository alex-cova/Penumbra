import AppKit
import Foundation
import GitIntelligence
import Observation
import Penumbra

/// What the blame column shows for a file: the annotation of every line, from `git blame`.
enum IDEBlamePresentation {
    /// One entry per line, with consecutive lines of one commit sharing an id so the column
    /// shows their text once. Lines that are not committed (unsaved or unstaged-new text) get
    /// ``edited``, the same annotation the editor gives a line typed after the blame was taken.
    static func annotations(
        for lines: [GitBlameLine],
        now: Date = Date(),
        locale: Locale = .current
    ) -> [GutterAnnotation?] {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = locale
        var idByHash: [String: Int] = [:]
        var built: [String: GutterAnnotation] = [:]
        return lines.map { line in
            if line.isUncommitted { return edited }
            if let existing = built[line.hash] { return existing }
            let id = idByHash[line.hash] ?? idByHash.count
            idByHash[line.hash] = id
            let age = formatter.localizedString(for: line.date, relativeTo: now)
            let annotation = GutterAnnotation(
                id: id,
                text: "\(line.author), \(age)",
                tooltip: "\(line.shortHash) \(line.summary)\n\(line.author), \(line.date.formatted(date: .abbreviated, time: .shortened))"
            )
            built[line.hash] = annotation
            return annotation
        }
    }

    /// Shown for lines that are not in any commit. Its id cannot collide with a commit's.
    static let edited = GutterAnnotation(id: -1, text: "Not Committed Yet", tooltip: "This line is not committed yet.")
}

/// Git blame in the editor gutter (Git ▸ Show Git Blame). Blame is on per file, for the session;
/// the workspace calls ``refresh`` whenever an editor for such a file loads, is saved, or the
/// repository changes underneath it.
///
/// Blame runs off the main actor against the live buffer. One request per editor is in flight; a
/// result computed for text the user has since changed is dropped and computed again, so the
/// column never shows rows that belong to another version of the file.
@MainActor
@Observable
final class IDEBlameController {
    private(set) var enabledPaths: Set<String> = []
    /// What the column was last filled for, per editor: skips a repeat when nothing changed.
    @ObservationIgnored private var stamps: [ObjectIdentifier: Stamp] = [:]
    @ObservationIgnored private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    private struct Stamp: Equatable {
        let path: String
        let contentGeneration: UInt64
        let status: IDEGitFileStatus?
    }

    func isEnabled(for url: URL?) -> Bool {
        guard let path = url?.standardizedFileURL.path else { return false }
        return enabledPaths.contains(path)
    }

    /// The window is closing: stop every blame run still going.
    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        stamps.removeAll()
    }

    /// Turns blame on or off for `url`. Returns the new state.
    @discardableResult
    func toggle(for url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if enabledPaths.remove(path) != nil { return false }
        enabledPaths.insert(path)
        return true
    }

    /// Fills the column of `textView` (showing `url`) when blame is on for that file, and hides it
    /// otherwise. `force` skips the "nothing changed" check.
    func refresh(
        textView: TextView,
        url: URL?,
        git: IDEGitStatusModel,
        force: Bool = false,
        onUnavailable: @escaping @MainActor () -> Void = {}
    ) {
        let key = ObjectIdentifier(textView)
        guard let url, isEnabled(for: url), git.isRepository else {
            tasks[key]?.cancel()
            tasks[key] = nil
            stamps[key] = nil
            textView.clearGutterAnnotations()
            return
        }
        let path = url.standardizedFileURL.path
        let stamp = Stamp(path: path, contentGeneration: textView.contentGeneration,
                          status: git.status(for: url, isDirectory: false))
        if !force, stamps[key] == stamp, textView.hasGutterAnnotations { return }
        tasks[key]?.cancel()
        tasks[key] = Task { [weak self, weak textView] in
            while let self, let textView, !Task.isCancelled {
                let generation = textView.contentGeneration
                let status = git.status(for: url, isDirectory: false)
                // The whole buffer is copied here, once per request, never on a keystroke.
                let contents = Data(textView.text.utf8)
                let lines = await git.blame(path: path, contents: contents)
                guard !Task.isCancelled else { return }
                guard self.isEnabled(for: url) else { return }
                guard let lines else {
                    // Untracked or not yet committed: nothing to annotate.
                    self.enabledPaths.remove(path)
                    self.stamps[key] = nil
                    textView.clearGutterAnnotations()
                    onUnavailable()
                    return
                }
                if textView.contentGeneration != generation {
                    // Edited while git ran: these rows belong to older text. Try again once typing eases.
                    try? await Task.sleep(for: .milliseconds(400))
                    continue
                }
                textView.setGutterAnnotations(
                    IDEBlamePresentation.annotations(for: lines),
                    edited: IDEBlamePresentation.edited
                )
                self.stamps[key] = Stamp(path: path, contentGeneration: generation, status: status)
                self.tasks[key] = nil
                return
            }
        }
    }
}
