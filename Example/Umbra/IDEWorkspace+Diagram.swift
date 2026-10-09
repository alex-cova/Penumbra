import AppKit
import JavaIntelligence
import Penumbra

/// Class and dependency diagrams: opening them as editor tabs from the Java menu, the editor, the Explorer
/// and the Gradle sidebar, and what their sessions need from the workspace (the index, open buffers, Gradle).
extension IDEWorkspace {
    // MARK: - Opening

    /// Opens `request` in a diagram tab, or selects the tab already showing it. `minimumNeighbourDepth` is
    /// the least number of neighbouring types a new class diagram should include.
    func openDiagram(_ request: IDEDiagramRequest, minimumNeighbourDepth: Int = 0) {
        for pane in workbench.panes {
            for document in pane.documents where document.contentKind == .diagram {
                if diagramSessions[document.id]?.request.id == request.id {
                    selectTab(document.id, in: pane.id)
                    return
                }
            }
        }
        let document = WorkbenchDocument(displayName: request.title)
        document.contentKind = .diagram
        diagramSessions[document.id] = makeDiagramSession(request, minimumNeighbourDepth: minimumNeighbourDepth)
        presentDiagramDocument(document)
    }

    /// The Java file of the selected editor tab, if there is one.
    var activeJavaFileURL: URL? {
        guard let document = workbench.activePane.selectedDocument,
              document.contentKind == .text,
              let url = document.url,
              url.pathExtension.lowercased() == "java" else { return nil }
        return url
    }

    var canShowClassDiagram: Bool { hasOpenProject }

    func showClassDiagramForActiveFile() {
        guard let url = activeJavaFileURL else {
            showClassDiagramForProject()
            return
        }
        showClassDiagram(forFile: url)
    }

    func showClassDiagram(forFile url: URL) {
        openDiagram(.classes(.file(url)))
    }

    func showClassDiagramForActivePackage() {
        guard let url = activeJavaFileURL, let name = javaPackageName(ofFile: url) else {
            notifications.post("Open a Java file in a package to diagram its package.", category: .general)
            return
        }
        openDiagram(.classes(.package(name)))
    }

    func showClassDiagram(forDirectory url: URL) {
        guard let name = javaPackageName(ofDirectory: url) else {
            notifications.post("That folder is not a Java package.", category: .general)
            return
        }
        openDiagram(.classes(.package(name)))
    }

    /// An Explorer row: a Java file, a package folder, or a source root (the whole project).
    func showClassDiagram(forExplorerItem url: URL) {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard isDirectory.boolValue else {
            showClassDiagram(forFile: url)
            return
        }
        let path = url.standardizedFileURL.path
        let isSourceRoot = gradle.sourceRootPaths.contains { URL(fileURLWithPath: $0).standardizedFileURL.path == path }
        if isSourceRoot || project.rootURL?.standardizedFileURL.path == path {
            showClassDiagramForProject()
        } else {
            showClassDiagram(forDirectory: url)
        }
    }

    func showClassDiagramForProject() {
        openDiagram(.classes(.project))
    }

    func showGradleModuleDiagram() {
        guard gradle.isActive else {
            notifications.post("This is not a Gradle project.", category: .gradle)
            return
        }
        openDiagram(.gradleModules)
    }

    /// The libraries of a Gradle project: the one given, else the module of the active file, else the root.
    func showGradleDependencyDiagram(projectPath: String? = nil) {
        guard gradle.isActive else {
            notifications.post("This is not a Gradle project.", category: .gradle)
            return
        }
        let path = projectPath ?? gradleProjectPath(containing: workbench.activePane.selectedDocument?.url) ?? ":"
        openDiagram(.gradleLibraries(projectPath: path, configuration: IDEDiagramSettings.load().libraryConfiguration))
    }

    /// Editor context-menu items for a Java file.
    func diagramContextMenuItems(url: URL?) -> [NSMenuItem] {
        guard let url, url.pathExtension.lowercased() == "java" else { return [] }
        return [
            .separator(),
            IDEClosureMenuItem(title: "Show Class Diagram") { [weak self] in
                self?.showClassDiagram(forFile: url)
            },
        ]
    }

    // MARK: - Names

    func gradleProjectPath(containing url: URL?) -> String? {
        guard let url, let model = gradle.model else { return nil }
        let path = url.standardizedFileURL.path
        return model.subprojects
            .filter { path == $0.directory.standardizedFileURL.path || path.hasPrefix($0.directory.standardizedFileURL.path + "/") }
            .max { $0.directory.standardizedFileURL.path.count < $1.directory.standardizedFileURL.path.count }?
            .path
    }

    func javaPackageName(ofFile url: URL) -> String? {
        let text = openBufferText(for: url) ?? (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard let range = text.range(of: #"(?m)^\s*package\s+([\w.]+)\s*;"#, options: .regularExpression) else { return nil }
        let match = text[range]
        guard let nameStart = match.range(of: "package")?.upperBound else { return nil }
        let name = match[nameStart...].trimmingCharacters(in: CharacterSet(charactersIn: "; \t\r\n"))
        return name.isEmpty ? nil : name
    }

    func javaPackageName(ofDirectory url: URL) -> String? {
        let path = url.standardizedFileURL.path
        for root in gradle.sourceRootPaths {
            let rootPath = URL(fileURLWithPath: root).standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relative = path.dropFirst(rootPath.count + 1)
            return relative.split(separator: "/").joined(separator: ".")
        }
        return nil
    }

    // MARK: - Sessions

    private func makeDiagramSession(_ request: IDEDiagramRequest, minimumNeighbourDepth: Int) -> IDEDiagramSession {
        var settings = IDEDiagramSettings.load()
        settings.neighbourDepth = max(settings.neighbourDepth, minimumNeighbourDepth)
        let session = IDEDiagramSession(request: request, settings: settings)
        let java = javaSupport
        let gradle = gradle
        let readBuffer: @MainActor @Sendable (URL) -> String? = { [weak self] url in self?.openBufferText(for: url) }
        session.loadClassGraph = { scope, options in
            let builder = JavaClassGraphBuilder(
                index: java.javaIndex,
                openBuffer: { url in await readBuffer(url) }
            )
            return await builder.build(scope: scope, options: options)
        }
        session.loadModuleGraph = { [weak self] in
            guard self != nil else { return .failure(.message("The window was closed.")) }
            guard let graph = gradle.moduleDependencyGraph else {
                return .failure(.message(
                    gradle.isBusy
                        ? "Gradle is still syncing the project. Reload the diagram when it finishes."
                        : "The Gradle project has not been synced yet. Reload the Gradle project, then try again."
                ))
            }
            return .success(graph)
        }
        session.loadLibraryGraph = { projectPath, configuration in
            await gradle.resolveDependencyGraph(projectPath: projectPath, configuration: configuration)
        }
        session.invalidateCaches = { gradle.invalidateDependencyGraphs() }
        session.openSource = { [weak self] url in
            Task { @MainActor [weak self] in await self?.openDocument(from: url) }
        }
        session.openDiagram = { [weak self] request, depth in
            self?.openDiagram(request, minimumNeighbourDepth: depth)
        }
        return session
    }

    func closeDiagramSession(_ documentID: UUID, in pane: EditorPane) {
        guard let session = diagramSessions.removeValue(forKey: documentID) else { return }
        hostCache.peek(pane.id)?.diagramViewer.detach(session)
        session.cancel()
    }

    func closeAllDiagramSessions() {
        for session in diagramSessions.values { session.cancel() }
        diagramSessions.removeAll()
    }

    /// After the project's sources were re-indexed or Gradle re-synced, open diagrams of that kind redraw.
    func reloadDiagramSessions(classes: Bool) {
        for session in diagramSessions.values where classes ? session.request.isClassDiagram : session.request == .gradleModules {
            session.reload()
        }
    }
}
