import Foundation
import Penumbra

/// The window's SwiftUI preview: the glue between the session (`SwiftUIPreview/`), the SwiftPM
/// project system that knows the package and its trust, and the chrome that shows the canvas.
extension IDEWorkspace {
    /// Whether the active file is a Swift file in a SwiftPM code target, so a preview can be built.
    var canPreviewSwiftUI: Bool {
        guard swiftPM.isActive, let url = workbench.activePane.selectedDocument?.url, url.pathExtension == "swift" else {
            return false
        }
        return swiftUIPreviewPackage(for: url) != nil
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
        session.refresh()
    }

    func hideSwiftUIPreview() {
        isSwiftUIPreviewVisible = false
        swiftUIPreview?.stop()
    }

    /// Rebuilds the preview after the active file was saved, when the canvas is showing.
    func noteSwiftUIPreviewDocumentSaved(_ url: URL?) {
        guard isSwiftUIPreviewVisible, let url, url.pathExtension == "swift",
              workbench.activePane.selectedDocument?.url?.standardizedFileURL == url.standardizedFileURL else { return }
        swiftUIPreview?.refresh()
    }

    private func swiftUIPreviewPackage(for url: URL) -> (root: URL, target: String)? {
        guard let manifest = swiftPM.manifest, let root = swiftPM.rootURL,
              let name = manifest.moduleResolver(root: root)(url), let target = manifest.target(named: name),
              target.kind == .regular || target.kind == .executable else { return nil }
        return (root, target.name)
    }

    private func makeSwiftUIPreviewSession() -> IDESwiftUIPreviewSession {
        let context = IDESwiftUIPreviewContext(
            activeFile: { [weak self] in
                guard let self, let url = self.workbench.activePane.selectedDocument?.url else { return nil }
                guard let text = self.openBufferText(for: url) ?? (try? String(contentsOf: url, encoding: .utf8)) else { return nil }
                return (url, text)
            },
            package: { [weak self] url in self?.swiftUIPreviewPackage(for: url) },
            ensureTrusted: { [weak self] in await self?.swiftPM.ensureTrusted() ?? false },
            toolchain: { [weak self] in
                let environment = self?.swiftPM.launchEnvironment
                guard let swift = IDESwiftPMProjectSystem.resolveSwift(environment: environment) else { return nil }
                return IDESwiftUIPreviewToolchain.beside(swift: swift)
            },
            publishDiagnostics: { [weak self] diagnostics in
                self?.problems.setBuildDiagnostics(diagnostics, source: IDEProblemsStore.swiftUIPreviewBuildSource)
            },
            bufferText: { [weak self] url in self?.openBufferText(for: url) }
        )
        return IDESwiftUIPreviewSession(context: context)
    }
}
