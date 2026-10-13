import AppKit
import JavaIntelligence
import Penumbra
import UniformTypeIdentifiers

/// Flight Recorder profiles as editor tabs: opening a recording (from a profiled run, the Explorer,
/// Finder or File ▸ Open Profiler Recording…), the tab's viewer, and what a frame opens.
extension IDEWorkspace {
    // MARK: - Detection

    /// Whether `url` is a recording to open in the profiler: the `FLR\0` magic, or a `.jfr` name on
    /// bytes that are not text (so a notes file called `x.jfr` still opens as text).
    static func isFlightRecording(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if JavaFlightRecordingDetector.isRecording(at: url) { return true }
        guard JavaFlightRecordingDetector.hasRecordingExtension(url),
              FileManager.default.fileExists(atPath: url.path) else { return false }
        let head = IDEHexRouting.readHead(url)
        return !head.isEmpty && BinaryContentDetector.looksBinary(head)
    }

    // MARK: - Opening

    /// Opens `url` in a profile tab, or selects the tab already showing it. A file in a run's folder
    /// brings its siblings (a Gradle test run writes one recording per JVM).
    func openProfile(file url: URL) {
        let recordings = Self.recordings(sharingFolderWith: url)
        openProfile(recordings: recordings, title: url.lastPathComponent, runID: nil, project: project.rootURL)
    }

    func openProfile(recordings: [URL], title: String, runID: String?, project: URL?) {
        guard let first = recordings.first else { return }
        let standard = first.standardizedFileURL
        for pane in workbench.panes {
            for document in pane.documents where document.contentKind == .profile {
                if document.url?.standardizedFileURL == standard {
                    selectTab(document.id, in: pane.id)
                    return
                }
            }
        }
        let document = WorkbenchDocument(displayName: title)
        document.contentKind = .profile
        document.url = first
        profileSessions[document.id] = makeProfileSession(recordings: recordings, title: title, runID: runID)
        presentDiagramDocument(document)
    }

    /// File ▸ Open Profiler Recording…
    func chooseProfilerRecording() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Java Flight Recorder file."
        if let type = UTType(filenameExtension: "jfr") { panel.allowedContentTypes = [type] }
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        recordRecentFile(url)
        openProfile(file: url)
    }

    /// Every `.jfr` beside `url` when that folder is a profiled run's (they all belong to one run),
    /// else just `url`; the largest first.
    static func recordings(sharingFolderWith url: URL) -> [URL] {
        let folder = url.deletingLastPathComponent()
        let isRunFolder = folder.path.contains("/Profiles/")
        guard isRunFolder else { return [url] }
        let siblings = JavaProfileGradleScript.recordings(in: folder)
        return siblings.isEmpty ? [url] : siblings
    }

    // MARK: - Session

    func makeProfileSession(recordings: [URL], title: String, runID: String?) -> IDEProfilerSession {
        let session = IDEProfilerSession(recordings: recordings, title: title, runID: runID)
        session.confirmThresholdBytes = IDEPreferences.shared.javaProfileConfirmMegabytes * 1024 * 1024
        session.jfrCandidates = { [weak self] in
            var candidates: [JDKInstallation] = []
            if let project = await self?.javaSupport.jdk.resolve(minimumFeatureVersion: nil)?.installation {
                candidates.append(project)
            }
            // A newer JDK's tool reads older recordings, so the rest come newest first.
            let installed = JDKLocator().discoverAll().sorted { $0.featureVersion > $1.featureVersion }
            for jdk in installed where !candidates.contains(where: { $0.home == jdk.home }) { candidates.append(jdk) }
            return candidates
        }
        session.openFrame = { [weak self] className, line in
            self?.openProfileFrame(className: className, line: line)
        }
        session.chooseJDK = { [weak self] in
            self?.requestedSettingsDomain = .java
            self?.showSettings()
        }
        session.openAsHex = { [weak self, weak session] in
            guard let self, let session else { return }
            self.reopenProfileAsHex(sessionID: session.id)
        }
        return session
    }

    /// Reopen as Hex for a profile tab: the same tab shows the file's bytes.
    func reopenProfileAsHex(sessionID: UUID) {
        for pane in workbench.panes {
            for document in pane.documents where profileSessions[document.id]?.id == sessionID {
                closeProfileSession(document.id, in: pane)
                Task { await reopenAsHex(document) }
                return
            }
        }
    }

    func closeProfileSession(_ documentID: UUID, in pane: EditorPane) {
        guard let session = profileSessions.removeValue(forKey: documentID) else { return }
        hostCache.peek(pane.id)?.profileViewer.detach(session)
        session.cancel()
    }

    func closeAllProfileSessions() {
        for session in profileSessions.values { session.cancel() }
        profileSessions.removeAll()
    }

    /// Puts a profile tab's viewer over the pane's editor, keeping the text document it replaces.
    func showProfileDocument(_ document: WorkbenchDocument, in pane: EditorPane, host: IDEEditorPaneHost) {
        var session = profileSessions[document.id]
        if session == nil {
            // A tab restored with the session: its file is the recording, or the tab goes.
            guard let url = document.url, FileManager.default.fileExists(atPath: url.path) else {
                let id = document.id
                Task { @MainActor [weak self] in self?.closeTab(id, in: pane.id) }
                return
            }
            let made = makeProfileSession(
                recordings: Self.recordings(sharingFolderWith: url), title: document.displayName, runID: nil
            )
            profileSessions[document.id] = made
            session = made
        }
        guard let session else { return }
        changeMarkers.hide(on: host.textView)
        if let previousID = host.loadedDocumentID,
           previousID != document.id,
           let previous = pane.documents.first(where: { $0.id == previousID }),
           previous.contentKind == .text {
            syncTextViewToDocument(host.textView, document: previous, from: host)
            previous.pendingState = host.textView.makeCapturedState()
        }
        host.markdownPreviewController.closeIfNotMarkdown()
        host.hideJSONDiagram(hidingViewer: false)
        host.hideCSVTable()
        host.imageViewerController.hide()
        host.diffViewer.hide()
        host.diagramViewer.hide()
        host.hexViewer.hide()
        host.profileViewer.show(session)
        host.loadedDocumentID = document.id
        host.loadedGeneration = document.contentGeneration
        if pane.id == workbench.activePaneID {
            host.profileViewer.focus()
        }
    }

    // MARK: - A frame's source

    /// Opens the source of `className` (a binary name: `app.Spin$Worker`, `app.Cart$$Lambda/0x…`) at
    /// `line`. Project sources are found by the declaring file's name; a class that is only in a
    /// library says so (its decompiled source is Go to Definition's, which needs a place in a file).
    func openProfileFrame(className: String, line: Int) {
        // `app.Outer$Inner` and `app.Cart$$Lambda/0x…` both live in `app/Outer.java`/`app/Cart.java`.
        let topLevel = className.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
            ?? className
        let relative = topLevel.replacingOccurrences(of: ".", with: "/") + ".java"
        for root in debugSourceRoots() {
            let candidate = root.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                if line > 0 {
                    revealDebugStop(file: candidate, line: line)
                } else {
                    Task { await openDocument(from: candidate) }
                }
                return
            }
        }
        // A source the index knows but the roots above do not cover (a generated or attached root).
        let index = javaSupport.javaIndex
        Task { @MainActor [weak self] in
            if let stub = await index.classStub(qualifiedName: topLevel), case .source(let url, _) = stub.origin {
                if line > 0 { self?.revealDebugStop(file: url, line: line) } else { await self?.openDocument(from: url) }
                return
            }
            self?.reportRunProblem("\(topLevel) is not in the project's sources, so there is no file to open.")
        }
    }
}
