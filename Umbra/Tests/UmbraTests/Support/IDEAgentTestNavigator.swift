import EditorIntelligence
import Foundation
import JavaIntelligence
@testable import Umbra

/// Drives the Java providers directly, the way `IDEAgentNavigationTools` did before
/// production navigation moved to `IDEEngineAgentNavigator` over `NavigationEngine`.
/// Only the navigation tests use it.
struct IDEJavaAgentNavigator: IDEAgentNavigating {
    let definitionProvider: JavaGoToDefinitionProvider
    let usageProvider: JavaFindUsagesProvider

    func definitions(file: URL, source: String, utf16Offset: Int) async -> [IDEAgentCodeLocation] {
        let position = IDEEngineAgentNavigator.position(in: source, utf16Offset: utf16Offset)
        let range = TextRange(start: position, end: position)
        let document = Document(
            url: file, displayName: file.lastPathComponent,
            contentSnapshot: TextSnapshot(version: 0, text: source),
            selection: Selection(range: range), cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 0, height: 0), languageIdentifier: "java")
        let context = NavigationContext(
            document: document, cursor: document.cursor, selection: document.selection, trigger: .idle, kind: .definition)
        let locations: [Location]
        switch await definitionProvider.provide(context: context) {
        case .single(let location)?: locations = [location]
        case .multiple(let found)?: locations = found
        case nil: locations = []
        }
        return locations.map { location in
            IDEAgentCodeLocation(
                fileURL: location.url ?? (location.documentID == document.id ? file : nil),
                line: location.range.start.line + 1, label: location.displayName)
        }
    }

    func usages(file: URL, source: String, utf16Offset: Int) async -> [IDEAgentCodeLocation] {
        await usageProvider.findUsages(source: source, url: file, utf16Offset: utf16Offset).map { usage in
            IDEAgentCodeLocation(
                fileURL: usage.url, line: usage.line + 1, label: usage.lineText,
                kind: String(describing: usage.kind), isAmbiguous: usage.confidence == .ambiguous)
        }
    }
}
