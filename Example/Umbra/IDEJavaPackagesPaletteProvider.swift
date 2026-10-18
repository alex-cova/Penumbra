import Foundation
import Penumbra

/// The Packages tab of Go to File: project packages from ``IDEJavaPackageIndex``, ranked like
/// Go to Class. Choosing a row reveals that directory in the Explorer.
final class IDEJavaPackagesPaletteProvider: SearchEverywhereProvider, @unchecked Sendable {
    let sectionTitle = "Packages"
    let sectionOrder = 16

    private let packages: @MainActor @Sendable () -> IDEJavaPackageIndex
    private let onReveal: @MainActor @Sendable (URL) -> Void

    init(
        packages: @escaping @MainActor @Sendable () -> IDEJavaPackageIndex,
        onReveal: @escaping @MainActor @Sendable (URL) -> Void
    ) {
        self.packages = packages
        self.onReveal = onReveal
    }

    func items(matching query: String, limit: Int) async -> [PaletteItem] {
        let hits = await MainActor.run { packages().matching(query, limit: limit) }
        let onReveal = self.onReveal
        return hits.enumerated().map { index, hit in
            let entry = hit.entry
            return PaletteItem(
                id: "package:\(entry.url.path)",
                title: entry.title,
                sectionTitle: sectionTitle,
                matchedIndices: hit.matchedOffsets,
                score: hits.count - index,
                action: { onReveal(entry.url) },
                icon: PaletteIcon(systemName: "folder.fill", tint: entry.isTest ? .orange : .blue),
                trailing: entry.module,
                footer: entry.relativePath,
                sourceRoot: entry.isTest ? .tests : .sources
            )
        }
    }
}
