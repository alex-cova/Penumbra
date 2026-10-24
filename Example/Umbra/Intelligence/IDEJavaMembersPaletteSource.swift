import EditorIntelligence
import Foundation
import JavaIntelligence
import Penumbra

/// Project-wide Java members for the Symbols tab and the `@` scope of Go to File: methods, fields,
/// enum constants and record components declared by the project's own classes (`JavaIndex.members`,
/// camel-hump matched like the Classes tab). Not a provider of its own: the Symbols provider lists
/// these rows first, in its section, and leaves out the open Java documents' tree-sitter symbols so
/// nothing appears twice. Library members (JARs, the JDK) stay out until "Include non-project
/// items" is wired.
struct IDEJavaMembersPaletteSource: Sendable {
    let javaIndex: JavaIndex
    let fileIndex: @MainActor @Sendable () -> PaletteFileIndex?
    /// Opens the member: it is located in its file as the file is now, so no stored position can be stale.
    let onOpen: @MainActor @Sendable (JavaMemberMatch, Bool) -> Void

    func items(matching query: String, limit: Int) async -> [PaletteItem] {
        guard !query.isEmpty else { return [] }
        let matches = await javaIndex.members(matching: query, limit: limit)
        guard !matches.isEmpty else { return [] }
        let files = await MainActor.run { fileIndex() }
        let onOpen = self.onOpen
        return matches.enumerated().map { rank, member in
            let entry = files?.entry(for: member.url)
            return PaletteItem(
                id: "member:\(member.ownerQualifiedName).\(member.name)(\(member.parameterKeys.joined(separator: ",")))",
                title: member.name,
                sectionTitle: "Symbols",
                matchedIndices: CompletionMatcher.match(query, in: member.name)?.matchedOffsets ?? [],
                score: limit - rank,
                action: { onOpen(member, false) },
                icon: Self.icon(for: member),
                location: Self.detail(of: member),
                trailing: member.ownerSimpleName,
                footer: "\(member.ownerQualifiedName) — \(entry?.relativePath ?? member.url.path)",
                alternateAction: { onOpen(member, true) }
            )
        }
    }

    /// `(String, int): int` for a method, `: String` for a field.
    static func detail(of member: JavaMemberMatch) -> String? {
        switch member.kind {
        case .method:
            return member.typeText.isEmpty ? member.parameterList : "\(member.parameterList): \(member.typeText)"
        case .field, .recordComponent:
            return member.typeText.isEmpty ? nil : ": \(member.typeText)"
        case .enumConstant:
            return nil
        }
    }

    static func icon(for member: JavaMemberMatch) -> PaletteIcon {
        switch member.kind {
        case .method: PaletteIcon(systemName: "m.square.fill", tint: member.isStatic ? .accent : .purple)
        case .field: PaletteIcon(systemName: "f.square.fill", tint: member.isStatic ? .accent : .blue)
        case .enumConstant: PaletteIcon(systemName: "e.square.fill", tint: .orange)
        case .recordComponent: PaletteIcon(systemName: "p.square.fill", tint: .green)
        }
    }
}
