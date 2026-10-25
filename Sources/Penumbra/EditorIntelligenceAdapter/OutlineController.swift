@preconcurrency import AppKit
import EditorIntelligence
import Foundation

/// Owns the outline sidebar's refresh for one ``EditorIntelligenceController``.
///
/// Rebuilds the tree from the symbol index after typing pauses and selects the item containing
/// the cursor. Extracted from `EditorIntelligenceController` so the feature has one home; the
/// sidebar view itself stays with the controller, which installs it and keeps it public.
@MainActor
final class OutlineController {
    private let adapter: (any EditorAdapter)?
    private let symbolIndex: SymbolIndex?
    private let outlineSidebarView: OutlineSidebarView
    private var task: Task<Void, Never>?

    init(adapter: (any EditorAdapter)?, symbolIndex: SymbolIndex?, outlineSidebarView: OutlineSidebarView) {
        self.adapter = adapter
        self.symbolIndex = symbolIndex
        self.outlineSidebarView = outlineSidebarView
    }

    /// Refresh the outline sidebar from the symbol index.
    func refresh() {
        guard let document = adapter?.currentDocument, let symbolIndex else {
            return
        }
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            let symbols = await symbolIndex.symbols(in: document.id)
            let items = OutlineBuilder.build(from: symbols)
            let selectedID = self.selectedItemID(for: document.cursor.position, in: items)
            await MainActor.run {
                self.outlineSidebarView.update(model: OutlineModel(items: items, selectedItemID: selectedID))
            }
        }
    }

    private func selectedItemID(for position: TextPosition, in items: [OutlineItem]) -> UUID? {
        let offset = position.utf16Offset
        var match: OutlineItem?
        func walk(_ items: [OutlineItem]) {
            for item in items {
                let start = min(item.range.start.utf16Offset, item.range.end.utf16Offset)
                let end = max(item.range.start.utf16Offset, item.range.end.utf16Offset)
                if start <= offset, offset <= end {
                    match = item
                    walk(item.children)
                }
            }
        }
        walk(items)
        return match?.id
    }

    deinit {
        task?.cancel()
    }
}
