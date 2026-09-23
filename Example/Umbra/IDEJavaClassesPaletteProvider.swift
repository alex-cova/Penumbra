import EditorIntelligence
import Foundation
import JavaIntelligence
import Penumbra

/// The Classes tab of Go to File for Java projects: IntelliJ-style camel-hump class lookup over
/// the project's own sources (`JavaIndex.classes(matching:)` already ranks by match tier and
/// source precedence). Library classes (JARs, the JDK) are left out until "Include non-project
/// items" is wired.
final class IDEJavaClassesPaletteProvider: SearchEverywhereProvider {
    let sectionTitle = "Classes"
    let sectionOrder = 15

    private let javaIndex: JavaIndex
    private let fileIndex: @MainActor @Sendable () -> PaletteFileIndex?
    /// Opens the declaration: file, UTF-8 byte range of the class name, and whether to use a split.
    private let onOpen: @MainActor @Sendable (URL, Range<Int>, Bool) -> Void

    init(
        javaIndex: JavaIndex,
        fileIndex: @escaping @MainActor @Sendable () -> PaletteFileIndex?,
        onOpen: @escaping @MainActor @Sendable (URL, Range<Int>, Bool) -> Void
    ) {
        self.javaIndex = javaIndex
        self.fileIndex = fileIndex
        self.onOpen = onOpen
    }

    func items(matching query: String, limit: Int) async -> [PaletteItem] {
        guard !query.isEmpty else { return [] }
        // Project classes are outranked by same-tier JDK ones only through precedence, so ask for
        // more than `limit` before dropping everything that isn't a project source.
        let matches = await javaIndex.classes(matching: query, limit: max(limit * 10, 300))
        let files = await MainActor.run { fileIndex() }
        let onOpen = self.onOpen

        var items: [PaletteItem] = []
        for match in matches {
            guard items.count < limit else { break }
            let stub = match.stub
            guard case .source(let url, let nameRange) = stub.origin else { continue }
            let entry = files?.entry(for: url)
            items.append(PaletteItem(
                id: "class:\(stub.qualifiedName)",
                title: stub.simpleName,
                sectionTitle: sectionTitle,
                matchedIndices: CompletionMatcher.match(query, in: stub.simpleName)?.matchedOffsets ?? [],
                score: matches.count - items.count,
                action: { onOpen(url, nameRange, false) },
                icon: Self.icon(for: stub.kind),
                location: stub.packageName.isEmpty ? nil : stub.packageName,
                trailing: entry?.module,
                footer: entry?.relativePath ?? url.path,
                alternateAction: { onOpen(url, nameRange, true) }
            ))
        }
        return items
    }

    static func icon(for kind: JavaTypeKind) -> PaletteIcon {
        switch kind {
        case .classKind: PaletteIcon(systemName: "c.circle.fill", tint: .blue)
        case .interfaceKind: PaletteIcon(systemName: "i.circle.fill", tint: .green)
        case .enumKind: PaletteIcon(systemName: "e.circle.fill", tint: .orange)
        case .recordKind: PaletteIcon(systemName: "r.circle.fill", tint: .purple)
        case .annotationKind: PaletteIcon(systemName: "at.circle.fill", tint: .orange)
        }
    }
}
