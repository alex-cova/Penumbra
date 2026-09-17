import Foundation

/// Tracks which ranges of the document should stay at full opacity while Focus Mode is enabled,
/// and caches the per-line breakdown consumed by `LayoutManager`/`LineFragmentRenderer`.
///
/// Mirrors `FoldingController`'s shape (reassignable `lineManager`/`stringView`, an `isEnabled`
/// toggle) and `HighlightService`'s per-line caching (`focusedRanges` are resolved once per
/// selection change, then split into line-local ranges lazily, one line at a time, as
/// `LayoutManager` lays out each line).
final class FocusModeController {
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else {
                return
            }
            if !isEnabled {
                focusedRanges = []
            }
        }
    }
    var granularity: FocusGranularity = .paragraph
    var unfocusedAlpha: CGFloat = 0.35
    /// `unfocusedAlpha` when enabled, `1` (no dimming) otherwise. What `LineFragmentRenderer`
    /// should actually draw with.
    var effectiveUnfocusedAlpha: CGFloat {
        isEnabled ? unfocusedAlpha : 1
    }
    var lineManager: LineManager {
        didSet {
            if lineManager !== oldValue {
                invalidatePerLineCache()
            }
        }
    }
    var stringView: StringView {
        didSet {
            if stringView !== oldValue {
                invalidatePerLineCache()
            }
        }
    }
    private(set) var focusedRanges: [NSRange] = [] {
        didSet {
            if focusedRanges != oldValue {
                invalidatePerLineCache()
            }
        }
    }

    private let textSegmenter = TextSegmenter()
    private var lineLocalRangesByLineID: [DocumentLineNodeID: [NSRange]] = [:]

    init(lineManager: LineManager, stringView: StringView) {
        self.lineManager = lineManager
        self.stringView = stringView
    }

    /// Recomputes `focusedRanges` for the current `selections`. Returns `true` when the resolved
    /// ranges changed, so callers can skip a redraw when a caret move doesn't cross a sentence or
    /// paragraph boundary.
    @discardableResult
    func updateFocusedRanges(for selections: [NSRange]) -> Bool {
        guard isEnabled else {
            guard !focusedRanges.isEmpty else {
                return false
            }
            focusedRanges = []
            return true
        }
        let newRanges = textSegmenter.focusRanges(for: selections,
                                                  granularity: granularity,
                                                  lineManager: lineManager,
                                                  stringView: stringView)
        guard newRanges != focusedRanges else {
            return false
        }
        focusedRanges = newRanges
        return true
    }

    /// The portions of `lineRange` (in the line's own local coordinates, i.e. relative to
    /// `lineRange.location`) that should stay focused. Empty when Focus Mode is off or the line
    /// isn't touched by any focused range.
    func focusedRanges(forLineWithID lineID: DocumentLineNodeID, lineRange: NSRange) -> [NSRange] {
        guard isEnabled else {
            return []
        }
        if let cached = lineLocalRangesByLineID[lineID] {
            return cached
        }
        var result: [NSRange] = []
        for range in focusedRanges where range.overlaps(lineRange) {
            result.append(range.capped(to: lineRange).local(to: lineRange))
        }
        lineLocalRangesByLineID[lineID] = result
        return result
    }

    private func invalidatePerLineCache() {
        lineLocalRangesByLineID.removeAll()
    }
}
