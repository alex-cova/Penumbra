import AppKit
import JavaIntelligence

/// The Explorer's External Libraries section: refreshed from the active build's model, and opening
/// its rows.
extension IDEWorkspace {
    /// Called when a Gradle or Maven model arrives or goes away.
    func refreshExternalLibraries() {
        guard javaSupport.isJavaBuildActive, let model = javaSupport.projectModel else {
            externalLibraries.update(libraries: [])
            syncBytecodeArchives()
            return
        }
        externalLibraries.update(libraries: JavaExternalLibrary.list(from: model))
        syncBytecodeArchives()
    }

    /// A class goes through Go to Definition (attached sources, or the decompiler and its agreement);
    /// a resource is copied out of its jar and opened read-only.
    func openExternalLibraryItem(_ item: IDEExternalLibraryItem) {
        switch item.kind {
        case .type:
            // A class in a jar the user opened has no index behind it: extract and decompile it.
            if let archive = item.archive, let entry = item.entry {
                openArchiveEntry(entry, from: archive)
                return
            }
            guard let name = item.qualifiedName else { return }
            Task { await openJavaType(qualifiedName: name) }
        case .resource:
            guard let archive = item.archive, let entry = item.entry else { return }
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
        default:
            break
        }
    }

    func copyExternalLibraryItemName(_ item: IDEExternalLibraryItem) {
        let text = item.qualifiedName ?? item.title
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
