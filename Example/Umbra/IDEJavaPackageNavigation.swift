import AppKit
import EditorIntelligence
import JavaIntelligence
import Penumbra

/// Go to Definition on a package that has no folder in the project (`java.util`, a dependency's
/// package): a list of its classes, and the chosen one opens through the ordinary definition path.
extension IDEWorkspace {
    func showLibraryPackage(_ name: String) {
        guard let paletteController else { return }
        let index = javaSupport.javaIndex
        Task { @MainActor [weak self] in
            let stubs = await index.classes(inPackage: name)
                .filter { $0.outerQualifiedName == nil }
                .sorted { $0.simpleName.localizedCaseInsensitiveCompare($1.simpleName) == .orderedAscending }
            guard let self, !stubs.isEmpty else { return }
            let items = stubs.map { (title: $0.simpleName, subtitle: Optional(Self.kindLabel($0.kind))) }
            paletteController.presentList(title: "Classes in \(name)", items: items) { [weak self] choice in
                guard let self, stubs.indices.contains(choice) else { return }
                Task { @MainActor in await self.openJavaType(qualifiedName: stubs[choice].qualifiedName) }
            }
        }
    }

    /// Opens the declaration of `qualifiedName` by asking Go to Definition about an `import` of it,
    /// so attached sources, decompiling and its one-time agreement behave exactly as for a click.
    func openJavaType(qualifiedName: String) async {
        let source = "import \(qualifiedName);"
        let offset = (source as NSString).length - 2
        let position = TextPosition(line: 0, column: offset, utf16Offset: offset)
        let document = Document(
            displayName: "Import.java",
            contentSnapshot: TextSnapshot(version: 0, text: source),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "java"
        )
        let result = await javaSupport.navigationProvider.provide(context: NavigationContext(
            document: document, cursor: Cursor(position: position), selection: document.selection,
            trigger: .manual, kind: .definition
        ))
        switch result {
        case .single(let location):
            _ = openNavigationLocation(location)
        case .multiple(let locations):
            presentNavigationChoices(locations)
        case nil:
            NSSound.beep()
        }
    }

    private static func kindLabel(_ kind: JavaTypeKind) -> String {
        switch kind {
        case .classKind: "class"
        case .interfaceKind: "interface"
        case .enumKind: "enum"
        case .recordKind: "record"
        case .annotationKind: "annotation"
        }
    }
}
