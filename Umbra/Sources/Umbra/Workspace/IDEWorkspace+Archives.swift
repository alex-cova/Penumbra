import AppKit
import JavaIntelligence
import Penumbra

/// Jars and class files opened as files. A `.jar` is not an editor tab: its contents are listed in
/// the Explorer (Opened Archives, the same lazy tree as External Libraries). A `.class` opens as its
/// decompiled Java, and Open as Hex Editor / Reopen as Decompiled Source switch between that and the
/// bytes at any time.
extension IDEWorkspace {
    // MARK: - Detection

    /// A `.jar` that is really a zip (`PK`), unless the user listed `jar` under Settings ▸ Hex to
    /// force the bytes.
    static func isJavaArchive(_ url: URL) -> Bool {
        guard url.isFileURL, url.pathExtension.lowercased() == "jar",
              !IDEHexSettings.shared.forceHexExtensions.contains("jar") else { return false }
        let head = IDEHexRouting.readHead(url).prefix(2)
        return head.elementsEqual([0x50, 0x4B])
    }

    /// A class file to show as source: it starts with the class magic and `class` is not forced to hex.
    static func isDecompilableClass(_ url: URL) -> Bool {
        guard url.isFileURL, JavaClassFileDecompiler.isClassFile(url),
              !IDEHexSettings.shared.forceHexExtensions.contains("class") else { return false }
        return JavaClassFileDecompiler.hasClassMagic(IDEHexRouting.readHead(url))
    }

    // MARK: - Archives

    /// Lists `url`'s contents in the Explorer and brings the Explorer forward.
    func openArchive(_ url: URL) {
        recordRecentFile(url)
        agent.dismissPage()
        externalLibraries.openArchive(url)
        syncBytecodeArchives()
        showSidebarTab(.explorer)
        refreshPresentation()
    }

    func closeArchive(_ item: IDEExternalLibraryItem) {
        guard let url = item.location else { return }
        externalLibraries.closeArchive(url)
        syncBytecodeArchives()
        refreshPresentation()
    }

    /// Tells Call Hierarchy which jars a class copied out of the cache may belong to: the ones the
    /// user opened and the project's dependencies.
    func syncBytecodeArchives() {
        javaSupport.bytecodeCallHierarchyProvider.setArchives(
            externalLibraries.openedArchives + externalLibraries.libraries.map(\.jar)
        )
    }

    /// The jar's bytes in a hex tab, for a jar the user would rather inspect than browse.
    func openArchiveAsHex(_ item: IDEExternalLibraryItem) {
        guard let url = item.location else { return }
        Task { await openHexDocument(from: url) }
    }

    /// A class or resource row of an opened jar: the entry is copied out of the jar (read-only, in
    /// the index cache) and opened. A class decompiles on the way in.
    func openArchiveEntry(_ entry: String, from archive: URL) {
        let cacheRoot = javaSupport.indexCacheRoot
        Task { [weak self] in
            let url = await Task.detached(priority: .userInitiated) {
                JavaAttachedSources.extractResource(entry: entry, from: archive, cacheRoot: cacheRoot)
            }.value
            guard let self else { return }
            guard let url else {
                NSSound.beep()
                return
            }
            await self.openDocument(from: url)
        }
    }

    // MARK: - Class files

    /// A document showing the decompiled source of the class file at `url`, or `nil` when the user
    /// declines the Sunflower agreement or the bytes cannot be decompiled (the caller then shows hex).
    /// The document keeps the `.class` URL, which is what makes it read-only and keeps it out of
    /// analysis (``JavaAttachedSources/isExtractedSource(_:)``).
    func loadDecompiledClass(from url: URL) async -> WorkbenchDocument? {
        if !hasConsent(to: .javaDecompiler), !(await requestConsent(to: .javaDecompiler)) { return nil }
        let source = await Task.detached(priority: .userInitiated) {
            JavaClassFileDecompiler.decompile(contentsOf: url)
        }.value
        guard let source else { return nil }
        let language = IDELanguageSupport.language(forIdentifier: "java", fileURL: url)
        let document = WorkbenchDocument(
            url: url, displayName: url.lastPathComponent, text: source, language: language, languageIdentifier: "java"
        )
        let theme = IDEEditorTheme.shared.current
        let multiplier = CGFloat(preferences.lineHeightMultiplier)
        if let language {
            document.pendingState = TextViewState(
                text: source, theme: theme, lineHeightMultiplier: multiplier, language: language,
                languageProvider: Self.languageProvider, parsePolicy: .viewport
            )
        } else {
            document.pendingState = TextViewState(text: source, theme: theme, lineHeightMultiplier: multiplier)
        }
        document.isFileBacked = false
        document.encoding = .utf8
        return document
    }

    /// Opens `url` as bytes regardless of its type.
    func openHexDocument(from url: URL) async {
        await openDocument(from: url, asHex: true)
    }

    /// Whether the active tab shows a class file's bytes, so it can go back to its source.
    var activeDocumentCanReopenAsDecompiled: Bool {
        guard let document = workbench.activePane.selectedDocument, document.contentKind == .binary,
              let url = document.url else { return false }
        return JavaClassFileDecompiler.isClassFile(url)
    }

    func reopenActiveDocumentAsDecompiled() {
        guard let document = workbench.activePane.selectedDocument else { return }
        Task { await reopenAsDecompiled(document) }
    }
}
