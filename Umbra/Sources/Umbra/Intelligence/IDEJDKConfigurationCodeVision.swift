import EditorIntelligence
import Foundation
import JavaIntelligence
import Penumbra

/// Project-level version-manager annotations on the existing Code Vision layout.
@MainActor
final class IDEJDKConfigurationCodeVision: CodeVisionProviding {
    private let native: any CodeVisionProviding
    private let jdk: IDEJDKSelection
    private var lastScan: ContinuousClock.Instant?

    init(native: any CodeVisionProviding, jdk: IDEJDKSelection) {
        self.native = native
        self.jdk = jdk
    }

    static func supports(_ url: URL?, in root: URL?) -> Bool {
        guard let url, let root else { return false }
        return JavaVersionDeclaration.fileNames.contains(url.lastPathComponent)
            && url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL
    }

    func codeVisionAnchors(for document: Document) async -> [Int] {
        guard Self.supports(document.url, in: jdk.projectRoot) else {
            return await native.codeVisionAnchors(for: document)
        }
        return declarations(for: document).map(\.utf16Offset)
    }

    func codeVision(for document: Document, anchors: [Int]) async -> [CodeVisionLens] {
        guard Self.supports(document.url, in: jdk.projectRoot), let url = document.url,
              let root = jdk.projectRoot else {
            return await native.codeVision(for: document, anchors: anchors)
        }
        let declarations = declarations(for: document)
        guard !declarations.isEmpty else { return [] }
        if lastScan.map({ $0.duration(to: .now) > .seconds(60) }) ?? true {
            await jdk.refreshDetected()
            lastScan = .now
        }
        let siblings = await runDetached(priority: .utility) {
            Self.siblingDeclarations(excluding: url, root: root)
        }
        guard !Task.isCancelled, jdk.projectRoot == root else { return [] }

        let all = declarations + siblings
        return declarations.filter { anchors.contains($0.utf16Offset) }.map { declaration in
            CodeVisionLens(utf16Offset: declaration.utf16Offset, entries: [entry(for: declaration, alongside: all)])
        }
    }

    private func declarations(for document: Document) -> [JavaVersionDeclaration] {
        guard let fileName = document.url?.lastPathComponent, document.contentSnapshot.utf16Length <= 65_536 else { return [] }
        let source = document.substring(utf16Offset: 0, length: document.contentSnapshot.utf16Length)
        return JavaVersionDeclaration.parse(fileName: fileName, source: source)
    }

    private nonisolated static func siblingDeclarations(excluding url: URL, root: URL) -> [JavaVersionDeclaration] {
        JavaVersionDeclaration.fileNames.sorted().filter { $0 != url.lastPathComponent }.flatMap { fileName in
            let sibling = root.appendingPathComponent(fileName)
            let values = try? sibling.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true,
                  values?.fileSize ?? Int.max <= 65_536,
                  let handle = try? FileHandle(forReadingFrom: sibling) else { return [JavaVersionDeclaration]() }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 65_537), data.count <= 65_536,
                  let source = String(data: data, encoding: .utf8) else { return [] }
            return JavaVersionDeclaration.parse(fileName: fileName, source: source)
        }
    }

    private func entry(for declaration: JavaVersionDeclaration, alongside all: [JavaVersionDeclaration]) -> CodeVisionEntry {
        guard let requirement = declaration.requirement else {
            return CodeVisionEntry(id: "jdk.invalid", text: "Review Java version declaration")
        }
        if all.contains(where: { candidate in
            guard let other = candidate.requirement else { return false }
            return other.featureVersion != requirement.featureVersion
                || (other.vendor != nil && requirement.vendor != nil && other.vendor != requirement.vendor)
                || (other.version != requirement.version
                    && !other.version.hasPrefix(requirement.version + ".")
                    && !requirement.version.hasPrefix(other.version + "."))
        }) {
            return CodeVisionEntry(id: "jdk.conflict", text: "Review conflicting JDK declarations")
        }
        if let selected = jdk.current?.installation, requirement.matches(selected) {
            return CodeVisionEntry(id: "jdk.active", text: "Active JDK · \(selected.displayName)")
        }
        if let match = matchingInstallation(requirement) {
            return CodeVisionEntry(id: "jdk.select", text: "Set \(match.displayName) as Project JDK")
        }
        return CodeVisionEntry(id: "jdk.choose", text: "JDK \(declaration.value) missing · Choose JDK…")
    }

    func handle(_ entry: CodeVisionEntry, at offset: Int, in textView: TextView, workspace: IDEWorkspace) {
        guard let url = textView.documentURL, let root = jdk.projectRoot, Self.supports(url, in: root),
              textView.documentLength <= 65_536,
              let text = textView.text(in: NSRange(location: 0, length: textView.documentLength)),
              let declaration = JavaVersionDeclaration.parse(fileName: url.lastPathComponent, source: text)
                .first(where: { $0.utf16Offset == offset }) else { return }
        switch entry.id {
        case "jdk.select", "jdk.choose":
            guard let requirement = declaration.requirement else { return }
            let generation = textView.contentGeneration
            Task { [weak workspace, weak textView] in
                let siblings = await runDetached(priority: .utility) {
                    Self.siblingDeclarations(excluding: url, root: root)
                }
                guard let workspace, let textView, textView.documentURL == url,
                      textView.contentGeneration == generation, jdk.projectRoot == root,
                      self.entry(for: declaration, alongside: siblings + JavaVersionDeclaration.parse(fileName: url.lastPathComponent, source: text)).id == entry.id else { return }
                if entry.id == "jdk.select", let installation = matchingInstallation(requirement) {
                    jdk.chooseForProject(installation)
                    await jdk.refreshCurrent()
                    workspace.refreshJDKConfigurationHints()
                } else if entry.id == "jdk.choose" {
                    workspace.chooseJDKFolder(prompt: "Set Project JDK") { [weak workspace, weak textView] url in
                        Task {
                            let installation = await runDetached(priority: .utility) {
                                JDKLocator().installation(atUserSelected: url)
                            }
                            guard let workspace, let textView, textView.contentGeneration == generation,
                                  Self.supports(textView.documentURL, in: root), self.jdk.projectRoot == root else { return }
                            guard let installation, installation.isFullJDK, requirement.matches(installation) else {
                                workspace.notifications.post(
                                    "JDK does not match", detail: "Choose a full JDK matching \(declaration.value).", severity: .error
                                )
                                return
                            }
                            self.jdk.chooseForProject(installation)
                            await self.jdk.refreshCurrent()
                            workspace.refreshJDKConfigurationHints()
                        }
                    }
                }
            }
        case "jdk.active":
            workspace.notifications.post("Project JDK", detail: "The editor is using \(declaration.value).")
        case "jdk.invalid":
            workspace.notifications.post("Review Java version", detail: "Use a literal Java version with an optional supported vendor.")
        case "jdk.conflict":
            workspace.notifications.post("Review Java version", detail: "The version manager files in the project root specify different JDKs.")
        default:
            break
        }
    }

    private func matchingInstallation(_ requirement: JavaVersionDeclaration.Requirement) -> JDKInstallation? {
        jdk.detected.first { requirement.matches($0) && $0.isFullJDK }
    }
}
