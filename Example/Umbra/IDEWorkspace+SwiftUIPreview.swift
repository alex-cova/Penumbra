import Foundation
import Penumbra

/// The window's SwiftUI preview: the glue between the session (`SwiftUIPreview/`), the SwiftPM
/// project system that knows the package and its trust, and the chrome that shows the canvas.
extension IDEWorkspace {
    /// Whether the active file is a Swift file in a SwiftPM code target, so a preview can be built.
    var canPreviewSwiftUI: Bool {
        guard swiftPM.isActive || xcode.isActive, let url = workbench.activePane.selectedDocument?.url, url.pathExtension == "swift" else {
            return false
        }
        return swiftUIPreviewPackage(for: url) != nil
    }

    /// Whether `url` is a Swift file of a SwiftPM code target, so it can be previewed.
    func canPreviewSwiftUI(file url: URL) -> Bool {
        (swiftPM.isActive || xcode.isActive) && url.pathExtension == "swift" && swiftUIPreviewPackage(for: url) != nil
    }

    /// Opens the canvas on the active file's preview number `blockIndex` (the gutter's eye).
    func showSwiftUIPreview(blockIndex: Int) {
        guard canPreviewSwiftUI else {
            notifications.post("Open a Swift file of a SwiftPM package to preview it.", category: .general)
            return
        }
        let session = swiftUIPreview ?? makeSwiftUIPreviewSession()
        swiftUIPreview = session
        isSwiftUIPreviewVisible = true
        swiftUIPreviewDocumentID = workbench.activePane.selectedDocument?.id
        session.select(blockIndex)
    }

    /// Shows the canvas and builds the active file's preview, or closes it.
    func toggleSwiftUIPreview() {
        if isSwiftUIPreviewVisible {
            hideSwiftUIPreview()
            return
        }
        guard canPreviewSwiftUI else {
            notifications.post("Open a Swift file of a SwiftPM package to preview it.", category: .general)
            return
        }
        let session = swiftUIPreview ?? makeSwiftUIPreviewSession()
        swiftUIPreview = session
        isSwiftUIPreviewVisible = true
        swiftUIPreviewDocumentID = workbench.activePane.selectedDocument?.id
        session.refresh()
    }

    func hideSwiftUIPreview() {
        isSwiftUIPreviewVisible = false
        swiftUIPreviewSwitchTask?.cancel()
        swiftUIPreviewSwitchTask = nil
        swiftUIPreviewDocumentID = nil
        swiftUIPreview?.stop()
    }

    /// Shows the preview of the Swift file a tab switch brought to the front. A switch to a file that
    /// is not Swift (or not in a code target) leaves the canvas as it is, and quick switches are
    /// collapsed: only the file that stays selected is built.
    func noteSwiftUIPreviewActiveDocumentMayHaveChanged() {
        guard isSwiftUIPreviewVisible, let document = workbench.activePane.selectedDocument,
              document.id != swiftUIPreviewDocumentID, document.contentKind == .text,
              let url = document.url, url.pathExtension == "swift", swiftUIPreviewPackage(for: url) != nil else { return }
        swiftUIPreviewDocumentID = document.id
        swiftUIPreviewSwitchTask?.cancel()
        swiftUIPreviewSwitchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, self.isSwiftUIPreviewVisible,
                  self.workbench.activePane.selectedDocument?.id == document.id else { return }
            self.swiftUIPreview?.refresh()
        }
    }

    /// Rebuilds the preview after the active file was saved, when the canvas is showing.
    func noteSwiftUIPreviewDocumentSaved(_ url: URL?) {
        guard isSwiftUIPreviewVisible, let url, url.pathExtension == "swift",
              workbench.activePane.selectedDocument?.url?.standardizedFileURL == url.standardizedFileURL else { return }
        swiftUIPreview?.refresh()
    }

    /// The SwiftPM package or Xcode project target a Swift file is compiled in.
    private func swiftUIPreviewPackage(for url: URL) -> IDESwiftUIPreviewPackage? {
        if swiftPM.isActive, let manifest = swiftPM.manifest, let root = swiftPM.rootURL,
           let name = manifest.moduleResolver(root: root)(url), let target = manifest.target(named: name),
           target.kind == .regular || target.kind == .executable {
            return IDESwiftUIPreviewPackage(root: root, target: target.name)
        }
        if xcode.isActive, let model = xcode.model {
            // A file in several targets (an app and its extension): the first that is not a test.
            if let name = model.targets(containing: url).first {
                return IDESwiftUIPreviewPackage(
                    root: model.projectURL.deletingLastPathComponent(), target: name,
                    buildSystem: .xcode(project: model.projectURL.path)
                )
            }
        }
        return nil
    }

    private func makeSwiftUIPreviewSession() -> IDESwiftUIPreviewSession {
        let context = IDESwiftUIPreviewContext(
            activeFile: { [weak self] in
                guard let self, let url = self.workbench.activePane.selectedDocument?.url else { return nil }
                guard let text = self.openBufferText(for: url) ?? (try? String(contentsOf: url, encoding: .utf8)) else { return nil }
                return (url, text)
            },
            package: { [weak self] url in self?.swiftUIPreviewPackage(for: url) },
            ensureTrusted: { [weak self] package in
                guard let self else { return false }
                switch package.buildSystem {
                case .swiftPM: return await self.swiftPM.ensureTrusted()
                case .xcode: return await self.xcode.ensureTrusted()
                }
            },
            toolchain: { [weak self] in
                let environment = self?.swiftPM.launchEnvironment
                guard let swift = IDESwiftPMProjectSystem.resolveSwift(environment: environment) else { return nil }
                var toolchain = IDESwiftUIPreviewToolchain.beside(swift: swift)
                if let xcodebuild = IDEXcodeProjectSystem.resolveXcodebuild(environment: self?.xcode.launchEnvironment) {
                    toolchain.xcodebuild = xcodebuild
                }
                return toolchain
            },
            publishDiagnostics: { [weak self] diagnostics in
                self?.problems.setBuildDiagnostics(diagnostics, source: IDEProblemsStore.swiftUIPreviewBuildSource)
            },
            bufferText: { [weak self] url in self?.openBufferText(for: url) }
        )
        return IDESwiftUIPreviewSession(context: context)
    }
}
