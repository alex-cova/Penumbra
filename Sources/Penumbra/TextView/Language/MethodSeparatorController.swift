import Foundation

/// Computes the document rows that get an IntelliJ-style method separator, by scanning the live
/// tree-sitter tree with ``DeclarationScanner`` and keeping the rows of declarations whose rule is
/// a ``DeclarationRule/isMethodSeparatorAnchor``.
///
/// Runs synchronously on the main actor — the scan does no name extraction (`text: nil`), so it is
/// a cheap type-string walk. Recompute after each syntax parse and when folds change.
@MainActor
final class MethodSeparatorController {
    weak var languageMode: TreeSitterInternalLanguageMode?
    var configuration: LanguageConfiguration?
    var isEnabled = false {
        didSet {
            if isEnabled != oldValue {
                isEnabled ? recompute() : clear()
            }
        }
    }
    /// Called with the new row set whenever it changes.
    var onRowsChanged: ((Set<Int>) -> Void)?

    private(set) var separatorRows: Set<Int> = []

    /// Rescan and publish if the row set changed.
    func recompute() {
        let newRows = computeRows()
        guard newRows != separatorRows else {
            return
        }
        separatorRows = newRows
        onRowsChanged?(newRows)
    }

    func clear() {
        guard !separatorRows.isEmpty else {
            return
        }
        separatorRows = []
        onRowsChanged?([])
    }

    private func computeRows() -> Set<Int> {
        guard isEnabled,
              let configuration,
              configuration.showsMethodSeparators,
              let root = languageMode?.rootSyntaxNode else {
            return []
        }
        let declarations = DeclarationScanner.scan(root: root, configuration: configuration, text: nil)
        var rows: Set<Int> = []
        for declaration in declarations where declaration.isMethodSeparatorAnchor {
            let row = declaration.container.startRow
            if row > 0 {
                rows.insert(row)
            }
        }
        return rows
    }
}
