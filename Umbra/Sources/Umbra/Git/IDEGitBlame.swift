import AppKit
import Foundation
import GitIntelligence
import Observation
import Penumbra

/// What the blame column asks the window to do. The controller knows the annotation and the file;
/// the workspace knows the diff viewer, the History tab and the pasteboard.
enum IDEBlameAction {
    case showDiff(GitBlameLine, file: URL)
    case showInLog(GitBlameLine, file: URL)
    case copyRevision(String)
    case openOnWeb(String)
    /// The file as it was after the commit that introduced the line.
    case annotateRevision(GitBlameLine, file: URL)
    /// The file as it was before that commit (the line's `previous`).
    case annotatePreviousRevision(GitBlameLine, file: URL)
    case showLineHistory(file: URL, line: Int)
}

/// Git blame in the editor gutter (Git ▸ Annotate with Git Blame). Blame is on per file, for the
/// session; the workspace calls ``refresh`` whenever an editor for such a file loads, is saved, or
/// the repository changes underneath it.
///
/// Blame runs off the main actor against the live buffer. One request per editor is in flight; a
/// result computed for text the user has since changed is dropped and computed again, so the
/// column never shows rows that belong to another version of the file. A tab that shows a past
/// revision (``IDEGitRevisionFiles``) is blamed at that revision instead.
@MainActor
@Observable
final class IDEBlameController {
    private(set) var enabledPaths: Set<String> = []
    private(set) var settings: IDEBlameSettings
    /// Revisions the user hid from a file's annotations, by file path (`--ignore-rev`).
    private(set) var hiddenRevisions: [String: [String]] = [:]

    /// What the column was last filled for, per editor: skips a repeat when nothing changed.
    @ObservationIgnored private var stamps: [ObjectIdentifier: Stamp] = [:]
    @ObservationIgnored private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// What each editor's column shows now, for hover, click and a change of presentation.
    @ObservationIgnored private var blamed: [ObjectIdentifier: [GitBlameLine]] = [:]
    @ObservationIgnored private var presented: [ObjectIdentifier: IDEBlameAnnotations] = [:]
    @ObservationIgnored private var files: [ObjectIdentifier: URL] = [:]
    @ObservationIgnored private var views: [ObjectIdentifier: WeakTextView] = [:]
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private weak var highlightedTextView: TextView?
    @ObservationIgnored private let popover = IDEBlameCommitPopover()
    @ObservationIgnored private let defaults: UserDefaults

    private struct WeakTextView {
        weak var value: TextView?
    }

    private struct Stamp: Equatable {
        let path: String
        let contentGeneration: UInt64
        let status: IDEGitFileStatus?
        let gitFlags: [Bool]
        let hidden: [String]
    }

    /// Set by the workspace: a file the profiler's line hints are showing in the annotation column,
    /// which blame then leaves alone.
    @ObservationIgnored var yieldsAnnotations: ((URL) -> Bool)?
    /// Set by the workspace: what an annotation's actions do.
    @ObservationIgnored var onAction: ((IDEBlameAction) -> Void)?
    /// Set by the workspace: the commit message below its subject, for the popover.
    @ObservationIgnored var loadMessageBody: ((String) async -> String?)?
    /// Set by the workspace: a setting or the hidden revisions changed what git must answer, so
    /// every blamed editor asks again.
    @ObservationIgnored var onNeedsBlame: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = IDEBlameSettings.load(from: defaults)
        popover.onClose = { [weak self] in self?.clearHighlight() }
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
        hoverTask?.cancel()
        popover.close(notify: false)
    }

    /// Turns blame on or off for `url`. Returns the new state.
    @discardableResult
    func toggle(for url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if enabledPaths.remove(path) != nil { return false }
        enabledPaths.insert(path)
        return true
    }

    func enable(_ url: URL) {
        enabledPaths.insert(url.standardizedFileURL.path)
    }

    func disable(_ url: URL) {
        let path = url.standardizedFileURL.path
        enabledPaths.remove(path)
        hiddenRevisions[path] = nil
    }

    // MARK: - Settings and hidden revisions

    /// Changes the shared settings. A change to what git is asked (whitespace, moves) re-blames
    /// every blamed editor; a change to how the lines read re-presents what was already read.
    func updateSettings(_ change: (inout IDEBlameSettings) -> Void) {
        var updated = settings
        change(&updated)
        guard updated != settings else { return }
        let flagsChanged = updated.gitFlags != settings.gitFlags
        settings = updated
        settings.save(to: defaults)
        if flagsChanged {
            onNeedsBlame?()
        } else {
            representAll()
        }
    }

    func hiddenRevisionCount(for url: URL?) -> Int {
        guard let path = url?.standardizedFileURL.path else { return 0 }
        return hiddenRevisions[path]?.count ?? 0
    }

    /// Hide Revision: the file's annotations skip over `hash` (git's `--ignore-rev`).
    func hideRevision(_ hash: String, in url: URL) {
        let path = url.standardizedFileURL.path
        var hidden = hiddenRevisions[path] ?? []
        guard !hidden.contains(hash) else { return }
        hidden.append(hash)
        hiddenRevisions[path] = hidden
        onNeedsBlame?()
    }

    func restoreHiddenRevisions(in url: URL) {
        let path = url.standardizedFileURL.path
        guard hiddenRevisions.removeValue(forKey: path) != nil else { return }
        onNeedsBlame?()
    }

    // MARK: - Filling the column

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
        if let url, yieldsAnnotations?(url) == true {
            tasks[key]?.cancel()
            tasks[key] = nil
            stamps[key] = nil
            return
        }
        guard let url, isEnabled(for: url), git.isRepository else {
            tasks[key]?.cancel()
            tasks[key] = nil
            stamps[key] = nil
            forget(key, textView: textView)
            return
        }
        install(on: textView, key: key)
        let path = url.standardizedFileURL.path
        let hidden = hiddenRevisions[path] ?? []
        let options = settings.options(hiding: hidden)
        let snapshot = IDEGitRevisionFiles.source(for: url)
        let stamp = Stamp(path: path, contentGeneration: textView.contentGeneration,
                          status: git.status(for: url, isDirectory: false), gitFlags: settings.gitFlags, hidden: hidden)
        if !force, stamps[key] == stamp, textView.hasGutterAnnotations { return }
        tasks[key]?.cancel()
        tasks[key] = Task { [weak self, weak textView] in
            while let self, let textView, !Task.isCancelled {
                let generation = textView.contentGeneration
                let status = git.status(for: url, isDirectory: false)
                let lines: [GitBlameLine]?
                if let snapshot {
                    lines = await git.blame(revision: snapshot.hash, relativePath: snapshot.relativePath,
                                            repositoryRoot: snapshot.repositoryRoot, options: options)
                } else {
                    // The whole buffer is copied here, once per request, never on a keystroke.
                    let contents = Data(textView.text.utf8)
                    lines = await git.blame(path: path, contents: contents, options: options)
                }
                guard !Task.isCancelled else { return }
                guard self.isEnabled(for: url) else { return }
                guard let lines else {
                    // Untracked or not yet committed: nothing to annotate.
                    self.enabledPaths.remove(path)
                    self.stamps[key] = nil
                    self.forget(key, textView: textView)
                    onUnavailable()
                    return
                }
                if textView.contentGeneration != generation {
                    // Edited while git ran: these rows belong to older text. Try again once typing eases.
                    try? await Task.sleep(for: .milliseconds(400))
                    continue
                }
                self.blamed[key] = lines
                self.files[key] = url
                self.present(key: key, textView: textView)
                self.stamps[key] = Stamp(path: path, contentGeneration: generation, status: status,
                                         gitFlags: self.settings.gitFlags, hidden: hidden)
                self.tasks[key] = nil
                return
            }
        }
    }

    /// Re-presents the lines already read (a View or Color change, the appearance changing).
    func representAll() {
        views = views.filter { $0.value.value != nil }
        for (key, holder) in views {
            guard let textView = holder.value, blamed[key] != nil else { continue }
            present(key: key, textView: textView)
        }
    }

    private func present(key: ObjectIdentifier, textView: TextView) {
        guard let lines = blamed[key] else { return }
        let annotations = IDEBlamePresentation.build(for: lines, settings: settings, isDark: IDEAppearance.scheme.isDark)
        presented[key] = annotations
        textView.setGutterAnnotations(annotations.rows, edited: IDEBlamePresentation.edited)
    }

    private func forget(_ key: ObjectIdentifier, textView: TextView) {
        blamed[key] = nil
        presented[key] = nil
        files[key] = nil
        if highlightedTextView === textView { popover.close() }
        textView.clearGutterAnnotations()
    }

    // MARK: - Pointer

    private func install(on textView: TextView, key: ObjectIdentifier) {
        views[key] = WeakTextView(value: textView)
        guard textView.gutterAnnotationClickHandler == nil else { return }
        textView.gutterAnnotationClickHandler = { [weak self, weak textView] click in
            guard let self, let textView else { return false }
            return self.handleClick(click, textView: textView)
        }
        textView.gutterAnnotationHoverHandler = { [weak self, weak textView] click in
            guard let self, let textView else { return }
            self.handleHover(click, textView: textView)
        }
    }

    private func commit(for click: GutterAnnotationClick, key: ObjectIdentifier) -> (line: GitBlameLine, file: URL)? {
        guard let line = presented[key]?.linesByID[click.annotation.id], let file = files[key] else { return nil }
        return (line, file)
    }

    private func handleClick(_ click: GutterAnnotationClick, textView: TextView) -> Bool {
        let key = ObjectIdentifier(textView)
        guard let file = files[key] else { return false }
        let commit = commit(for: click, key: key)
        if click.isSecondary {
            popover.close()
            let menu = makeMenu(for: commit?.line, clickedLine: click.line, file: file, textView: textView)
            if let event = click.event {
                NSMenu.popUpContextMenu(menu, with: event, for: click.anchorView)
            }
            return true
        }
        // A plain click goes to the commit in the log, as in IntelliJ.
        guard let commit else { return false }
        popover.close()
        onAction?(.showInLog(commit.line, file: commit.file))
        return true
    }

    private var tooltipDelay: Duration {
        .milliseconds(defaults.object(forKey: "com.umbra.editor.tooltipDelayMilliseconds") as? Int ?? 500)
    }

    private func handleHover(_ click: GutterAnnotationClick?, textView: TextView) {
        hoverTask?.cancel()
        let key = ObjectIdentifier(textView)
        guard let click, let commit = commit(for: click, key: key) else {
            if popover.isShown {
                popover.scheduleClose()
            } else {
                clearHighlight()
            }
            return
        }
        // The commit's rows light up at once; the popover follows after the tooltip delay, or
        // straight away while another commit's is already open.
        highlightedTextView = textView
        textView.highlightedGutterAnnotationID = click.annotation.id
        let delay = popover.isShown ? Duration.zero : tooltipDelay
        let rect = click.rect
        let anchor = click.anchorView
        let line = commit.line
        let file = commit.file
        hoverTask = Task { [weak self, weak anchor] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self, let anchor else { return }
            self.popover.present(
                line: line, rect: rect, of: anchor,
                actions: IDEBlameCommitActions(
                    showDiff: { [weak self] in self?.perform(.showDiff(line, file: file)) },
                    showInLog: { [weak self] in self?.perform(.showInLog(line, file: file)) },
                    copyRevision: { [weak self] in self?.perform(.copyRevision(line.hash)) },
                    openOnWeb: { [weak self] in self?.perform(.openOnWeb(line.hash)) }
                ),
                loadBody: { [weak self] in await self?.loadMessageBody?(line.hash) }
            )
        }
    }

    private func perform(_ action: IDEBlameAction) {
        popover.close()
        onAction?(action)
    }

    private func clearHighlight() {
        highlightedTextView?.highlightedGutterAnnotationID = nil
        highlightedTextView = nil
    }

    // MARK: - Menu

    private func makeMenu(for line: GitBlameLine?, clickedLine: Int, file: URL, textView: TextView) -> NSMenu {
        let menu = NSMenu()
        if let line {
            menu.addItem(IDEClosureMenuItem(title: "Show Diff") { [weak self] in self?.perform(.showDiff(line, file: file)) })
            menu.addItem(IDEClosureMenuItem(title: "Show in Log") { [weak self] in self?.perform(.showInLog(line, file: file)) })
            menu.addItem(IDEClosureMenuItem(title: "Copy Revision") { [weak self] in self?.perform(.copyRevision(line.hash)) })
            menu.addItem(IDEClosureMenuItem(title: "Open on Web") { [weak self] in self?.perform(.openOnWeb(line.hash)) })
            menu.addItem(.separator())
            menu.addItem(IDEClosureMenuItem(title: "Annotate Revision \(line.shortHash)") { [weak self] in
                self?.perform(.annotateRevision(line, file: file))
            })
            let previous = IDEClosureMenuItem(title: "Annotate Previous Revision") { [weak self] in
                self?.perform(.annotatePreviousRevision(line, file: file))
            }
            previous.isEnabled = line.previous != nil
            menu.addItem(previous)
            // A snapshot's line numbers are the old revision's, not the working file's.
            if !IDEGitRevisionFiles.isSnapshot(file) {
                menu.addItem(IDEClosureMenuItem(title: "Show History for This Line") { [weak self] in
                    self?.perform(.showLineHistory(file: file, line: clickedLine))
                })
            }
            menu.addItem(.separator())
            menu.addItem(IDEClosureMenuItem(title: "Hide Revision \(line.shortHash)") { [weak self] in
                self?.hideRevision(line.hash, in: file)
            })
        }
        let hidden = hiddenRevisionCount(for: file)
        if hidden > 0 {
            menu.addItem(IDEClosureMenuItem(title: "Restore Hidden Revisions (\(hidden))") { [weak self] in
                self?.restoreHiddenRevisions(in: file)
            })
        }
        if line != nil || hidden > 0 { menu.addItem(.separator()) }
        menu.addItem(submenu("View", viewItems()))
        menu.addItem(submenu("Color", IDEBlameSettings.Coloring.allCases.map { coloring in
            item(coloring.title, on: settings.coloring == coloring) { $0.coloring = coloring }
        }))
        menu.addItem(submenu("Options", [
            item("Ignore Whitespace", on: settings.ignoresWhitespace) { $0.ignoresWhitespace.toggle() },
            item("Detect Movements Within File", on: settings.detectsMovesWithinFile) { $0.detectsMovesWithinFile.toggle() },
            item("Detect Movements Across Files", on: settings.detectsMovesAcrossFiles) { $0.detectsMovesAcrossFiles.toggle() }
        ]))
        menu.addItem(.separator())
        menu.addItem(IDEClosureMenuItem(title: "Close Annotations") { [weak self, weak textView] in
            self?.disable(file)
            if let textView, let self { self.forget(ObjectIdentifier(textView), textView: textView) }
        })
        return menu
    }

    private func viewItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = [
            item("Author", on: settings.showsAuthor) { $0.showsAuthor.toggle() },
            item("Date", on: settings.showsDate) { $0.showsDate.toggle() },
            item("Revision", on: settings.showsHash) { $0.showsHash.toggle() },
            .separator()
        ]
        items += IDEBlameSettings.AuthorStyle.allCases.map { style in
            item("Author: \(style.title)", on: settings.authorStyle == style) { $0.authorStyle = style }
        }
        items.append(.separator())
        items += IDEBlameSettings.DateStyle.allCases.map { style in
            item("Date: \(style.title)", on: settings.dateStyle == style) { $0.dateStyle = style }
        }
        items.append(.separator())
        items.append(item("Show Commit Timestamp", on: settings.usesCommitterTime) { $0.usesCommitterTime.toggle() })
        return items
    }

    private func item(_ title: String, on: Bool, change: @escaping (inout IDEBlameSettings) -> Void) -> NSMenuItem {
        let item = IDEClosureMenuItem(title: title) { [weak self] in self?.updateSettings(change) }
        item.state = on ? .on : .off
        return item
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        parent.submenu = menu
        return parent
    }
}
