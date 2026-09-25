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
    ///
    /// `rowWindow` limits the walk to declarations that overlap those rows and keeps separators
    /// outside it. A character typed inside one method must not walk the rest of the file.
    /// `nil` scans the whole tree (open, theme change, or a parse with no row diff).
    func recompute(rowWindow: ClosedRange<Int>? = nil) {
        let newRows = computeRows(rowWindow: rowWindow)
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

    private func computeRows(rowWindow: ClosedRange<Int>?) -> Set<Int> {
        guard isEnabled,
              let configuration,
              configuration.showsMethodSeparators,
              let root = languageMode?.rootSyntaxNode else {
            return []
        }
        let declarations = DeclarationScanner.scan(
            root: root,
            configuration: configuration,
            text: nil,
            rowWindow: rowWindow
        )
        var rows: Set<Int> = rowWindow.map { window in
            separatorRows.filter { !window.contains($0) }
        } ?? []
        for declaration in declarations where declaration.isMethodSeparatorAnchor {
            let row = declaration.container.startRow
            if row > 0 {
                rows.insert(row)
            }
        }
        return rows
    }
}
