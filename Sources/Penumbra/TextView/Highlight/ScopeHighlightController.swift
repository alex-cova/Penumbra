import Foundation

/// Marks the block the caret is in (IntelliJ's "Highlight current scope"): the innermost fold
/// region that contains the caret's line gets a bar along the fold ribbon.
///
/// Driven from the selection-change path, so the lookup is debounced and, past
/// ``maxRegionCount`` regions, skipped; a lookup walks the regions once, never the document.
@MainActor
final class ScopeHighlightController {
    /// Receives the rows to mark, or `nil` to clear.
    var apply: ((ClosedRange<Int>?) -> Void)?
    var regionsProvider: (() -> [FoldRegion])?
    var rowProvider: ((_ location: Int) -> Int?)?

    var debounceInterval: TimeInterval = 0.08
    static let maxRegionCount = 50_000

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { refreshFromLastRequest() } else { clear() }
        }
    }

    private var lastLocation: Int?
    private var generation = 0

    func selectionDidChange(selectedRange: NSRange?, isMultiCaret: Bool) {
        guard isEnabled else { return }
        guard let selectedRange, !isMultiCaret else {
            lastLocation = nil
            clear()
            return
        }
        lastLocation = selectedRange.location
        schedule()
    }

    /// The regions changed (a parse or an edit): recompute for the last caret.
    func regionsDidChange() {
        guard isEnabled else { return }
        schedule()
    }

    func clear() {
        generation += 1
        apply?(nil)
    }

    private func refreshFromLastRequest() {
        guard lastLocation != nil else { return }
        schedule()
    }

    private func schedule() {
        generation += 1
        let current = generation
        let work = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.resolve()
            }
        }
        if debounceInterval <= 0 {
            work()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
        }
    }

    private func resolve() {
        guard isEnabled, let location = lastLocation, let row = rowProvider?(location),
              let regions = regionsProvider?(), regions.count <= Self.maxRegionCount else {
            apply?(nil)
            return
        }
        apply?(Self.innermostScope(containing: row, in: regions))
    }

    /// The smallest region whose lines include `row`, or `nil` when none does or the block is a
    /// single line (nothing to mark).
    static func innermostScope(containing row: Int, in regions: [FoldRegion]) -> ClosedRange<Int>? {
        var best: ClosedRange<Int>?
        for region in regions where region.lineRange.contains(row) && region.lineRange.count > 1 {
            if let current = best, region.lineRange.count >= current.count {
                continue
            }
            best = region.lineRange
        }
        return best
    }
}
