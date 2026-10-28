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
        // A run that was watched live reads its recording in the tab it already has.
        if let runID, let live = profileSessions.first(where: { $0.value.runID == runID && $0.value.phase == .live }) {
            live.value.finishLive(recordings: recordings)
            for pane in workbench.panes {
                guard let document = pane.documents.first(where: { $0.id == live.key }) else { continue }
                // The tab is the recording's from here on: restored with the session, found by its file.
                document.url = first
                selectTab(live.key, in: pane.id)
            }
            return
        }
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

    /// Opens an Instruments recording of a Swift program: exported with `xctrace` and parsed in the tab, which then
    /// looks like a Java profile (flame graph, hot methods, call tree, per-thread).
    func openSwiftProfile(trace: URL, title: String, root: URL?) {
        let document = WorkbenchDocument(displayName: title)
        document.contentKind = .profile
        let session = makeProfileSession(recordings: [trace], title: title, runID: nil)
        session.sourceLoader = { try await IDESwiftRunProvider.loadTimeProfile(trace: trace) }
        // A Swift frame's "class" is its binary: a frame of the program's binary carries its
        // source file and opens it, while a system frame without one says so.
        session.openFrame = { [weak self] _, line, sourcePath in
            guard let path = sourcePath, !path.isEmpty else {
                self?.reportRunProblem("This frame has no recorded source file, so there is nothing to open.")
                return
            }
            self?.revealDebugStop(file: URL(fileURLWithPath: path), line: max(line, 1))
        }
        let swiftTargets = Set(swiftPM.manifest?.targets.map(\.name) ?? [])
        let xcodeTargets = Set(xcode.model?.targets.map(\.name) ?? [])
        session.classifyClass = { module in
            if swiftTargets.contains(module) || xcodeTargets.contains(module) { return .project }
            // The platform's own libraries (dyld, libswiftCore, libsystem_c, …) play the part the JDK does for Java.
            if module.hasPrefix("lib") || module == "dyld" || module.isEmpty { return .jdk }
            return .library
        }
        profileSessions[document.id] = session
        presentDiagramDocument(document)
    }

    // MARK: - Live

    func beginLiveProfile(
        title: String, runID: String, snapshotDirectory: URL, jcmd: URL?, jps: URL?,
        processID: (@MainActor () -> Int32?)?
    ) {
        guard IDEPreferences.shared.javaProfileShowsLiveCharts else { return }
        let session = makeProfileSession(recordings: [], title: "Profile: \(title)", runID: runID)
        session.stopRun = { [weak self] in self?.stopRunning() }
        session.openSnapshot = { [weak self] url in
            self?.openProfile(recordings: [url], title: "Snapshot: \(title)", runID: nil, project: self?.project.rootURL)
        }
        let monitor = IDEProfilerLiveMonitor(
            runID: runID, jcmd: jcmd, jps: jps, snapshotDirectory: snapshotDirectory.appendingPathComponent("snapshots"),
            knownProcessID: processID
        )
        let document = WorkbenchDocument(displayName: "Profile: \(title)")
        document.contentKind = .profile
        // Live before the tab shows: showing a session that is still idle reads its recording.
        session.beginLive(monitor: monitor)
        profileSessions[document.id] = session
        presentDiagramDocument(document)
    }

    func hasLiveProfile(runID: String) -> Bool {
        profileSessions.values.contains { $0.runID == runID && $0.phase == .live }
    }

    func endLiveProfile(runID: String, failure: String) {
        for session in profileSessions.values where session.runID == runID { session.failLive(failure) }
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
        session.openFrame = { [weak self] className, line, _ in
            self?.openProfileFrame(className: className, line: line)
        }
        let roots = IDEProfileSourceRoots()
        session.classifyClass = { [weak self, roots] className in
            guard let self else { return .library }
            let candidates = roots.value ?? self.debugSourceRoots()
            roots.value = candidates
            let relative = Self.profileSourcePath(ofClass: className)
            for root in candidates where FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path) {
                return .project
            }
            return .library
        }
        session.onQueryChanged = { [weak self, weak session] in
            guard let self, let session else { return }
            self.profileSessionQueryChanged(session)
        }
        session.makeBaselineSession = { [weak self] recordings, title in
            guard let self else { return IDEProfilerSession(recordings: recordings, title: title) }
            return self.makeProfileSession(recordings: recordings, title: title, runID: nil)
        }
        session.baselineCandidates = { [weak self, weak session] in
            guard let self, let session else { return [] }
            return self.profileBaselineCandidates(excluding: session)
        }
        session.chooseBaselineFile = { [weak self, weak session] in
            guard let self, let session else { return }
            self.chooseBaselineRecording(for: session)
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
        if profileHintsSession === session {
            profileHintsSession = nil
            refreshProfileHints()
        }
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
        // Looking at a recording makes it the one the editors' line hints follow.
        if session.phase == .ready, profileHintsSession !== session {
            profileHintsSession = session
            refreshProfileHints()
        }
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

    // MARK: - Line hints in the editor

    /// A tab's query changed or its recording arrived: it is the profile the hints follow.
    func profileSessionQueryChanged(_ session: IDEProfilerSession) {
        // A baseline being read for a comparison is in no tab, and must not drive the editor.
        guard session.phase == .ready, profileSessions.values.contains(where: { $0 === session }) else { return }
        profileHintsSession = session
        refreshProfileHints()
    }

    /// Rebuilds the line costs from the followed tab (off the main actor) and repaints the editors.
    func refreshProfileHints() {
        guard IDEPreferences.shared.javaProfileLineHints, let session = profileHintsSession,
              session.phase == .ready, session.kind != .gc,
              let tree = session.tree, let symbols = session.symbols else {
            profileHints.clear()
            refreshAnnotationColumnsInOpenEditors()
            return
        }
        let ticket = profileHints.beginUpdate()
        let title = session.title
        Task.detached(priority: .userInitiated) { [weak self] in
            let lines = JavaLineProfile.build(from: tree, symbols: symbols)
            await MainActor.run { [weak self] in
                guard let self, self.profileHints.finishUpdate(ticket: ticket, profile: lines, title: title) else { return }
                self.refreshAnnotationColumnsInOpenEditors()
            }
        }
    }

    /// Settings or the Run menu turned the hints on or off.
    func profileLineHintsPreferenceChanged() {
        refreshProfileHints()
    }

    /// Whether the profiler's hints, and not git blame, fill the annotation column of `url`.
    func profileHintsOwnAnnotations(of url: URL?) -> Bool {
        guard let url, IDEPreferences.shared.javaProfileLineHints, profileHints.isActive else { return false }
        return profileHints.lines(forFile: url, roots: debugSourceRoots()) != nil
    }

    /// Fills the annotation column of `textView` when the hints own it for `url`.
    func applyProfileLineHints(to textView: TextView, url: URL?) {
        guard let url, profileHintsOwnAnnotations(of: url),
              let annotations = profileHints.annotations(
                forFile: url, roots: debugSourceRoots(), lineCount: textView.lineCount
              ) else { return }
        textView.setGutterAnnotations(annotations, edited: nil)
    }

    /// Hints in the editors that have costs for their file, blame (or nothing) in the others, and the
    /// hot-line tint repainted.
    func refreshAnnotationColumnsInOpenEditors() {
        for pane in workbench.panes {
            guard let textView = hostCache.peek(pane.id)?.textView,
                  pane.selectedDocument?.contentKind == .text else { continue }
            let url = pane.selectedDocument?.url
            if profileHintsOwnAnnotations(of: url) {
                applyProfileLineHints(to: textView, url: url)
            } else {
                blame.refresh(textView: textView, url: url, git: gitStatus, force: true)
            }
        }
        refreshExecutionLineBackgrounds()
    }

    /// The hot lines of `url`, tinted where no other band is.
    func profileHeatBackgrounds(forFile url: URL?, avoiding existing: [LineBackground]) -> [LineBackground] {
        guard IDEPreferences.shared.javaProfileLineHints, profileHints.isActive, let url else { return [] }
        let heat = profileHints.heat(forFile: url, roots: debugSourceRoots())
        guard !heat.isEmpty else { return [] }
        var taken = Set<Int>()
        for band in existing {
            for line in band.line..<(band.line + max(band.lineCount, 1)) { taken.insert(line) }
        }
        let base: CGFloat = isDarkEditorTheme ? 0.10 : 0.13
        return heat.compactMap { entry in
            guard !taken.contains(entry.line) else { return nil }
            let alpha = base + 0.22 * CGFloat(entry.intensity)
            return LineBackground(line: entry.line, lineCount: 1, color: NSColor.systemOrange.withAlphaComponent(alpha).cgColor)
        }
    }

    // MARK: - Baselines

    /// What a profile tab can be compared with: the other open profile tabs (already read), then the
    /// newest recorded runs of this project.
    func profileBaselineCandidates(excluding session: IDEProfilerSession) -> [IDEProfilerSession.BaselineCandidate] {
        var result: [IDEProfilerSession.BaselineCandidate] = []
        var seen = Set(session.recordings.map(\.standardizedFileURL))
        for other in profileSessions.values where other.id != session.id && other.profile != nil {
            result.append(IDEProfilerSession.BaselineCandidate(
                id: "tab-\(other.id)", title: other.title, subtitle: "open", recordings: other.recordings, profile: other.profile
            ))
            seen.formUnion(other.recordings.map(\.standardizedFileURL))
        }
        for recent in recentProfiles() {
            guard let first = recent.recordings.first, !seen.contains(first.standardizedFileURL) else { continue }
            result.append(IDEProfilerSession.BaselineCandidate(
                id: "run-\(recent.run.id)", title: recent.title, subtitle: recent.detail,
                recordings: recent.recordings, profile: nil
            ))
        }
        return result
    }

    // MARK: - Recent profiles

    /// This project's newest profiled runs (Run ▸ Recent Profiles).
    func recentProfiles(limit: Int = 10) -> [JavaRecentProfile] {
        guard let root = project.rootURL else { return [] }
        return JavaRecentProfile.list(
            artifacts: IDEJavaRunProvider.artifacts, projectHash: JavaRunArtifacts.projectHash(for: root), limit: limit
        )
    }

    func openRecentProfile(_ profile: JavaRecentProfile) {
        openProfile(
            recordings: profile.recordings, title: "Profile: \(profile.title)", runID: profile.run.id,
            project: project.rootURL
        )
    }

    func deleteRecentProfile(_ profile: JavaRecentProfile) {
        IDEJavaRunProvider.artifacts.delete(profile.run)
    }

    func chooseBaselineRecording(for session: IDEProfilerSession) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the recording to compare this one with."
        if let type = UTType(filenameExtension: "jfr") { panel.allowedContentTypes = [type] }
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        session.setBaseline(IDEProfilerSession.BaselineCandidate(
            id: "file-\(url.path)", title: url.lastPathComponent, subtitle: "file",
            recordings: Self.recordings(sharingFolderWith: url), profile: nil
        ))
    }

    // MARK: - A frame's source

    /// `app.Outer$Inner` and `app.Cart$$Lambda/0x…` both live in `app.Outer` / `app.Cart`.
    static func topLevelClassName(of className: String) -> String {
        className.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? className
    }

    /// `app/Outer.java` for a class of that file, relative to a source root.
    static func profileSourcePath(ofClass className: String) -> String {
        topLevelClassName(of: className).replacingOccurrences(of: ".", with: "/") + ".java"
    }

    /// Opens the source of `className` (a binary name: `app.Spin$Worker`, `app.Cart$$Lambda/0x…`) at
    /// `line`. Project sources are found by the declaring file's name; a class that is only in a
    /// library says so (its decompiled source is Go to Definition's, which needs a place in a file).
    func openProfileFrame(className: String, line: Int) {
        let topLevel = Self.topLevelClassName(of: className)
        let relative = Self.profileSourcePath(ofClass: className)
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

/// The source roots of a window's project, looked up once for a profile tab's colouring.
private final class IDEProfileSourceRoots {
    var value: [URL]?
}

extension JavaRecentProfile {
    /// `2 hours ago · 14 MB · profile · depth 128`.
    var detail: String {
        var parts = [run.modified.formatted(.relative(presentation: .named))]
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(run.bytes), countStyle: .file))
        if let settings = info?.settings { parts.append(settings) }
        return parts.joined(separator: " · ")
    }
}
