import Foundation

/// Manages grouped text emphases (search matches, bracket pairs, diagnostics) on top of
/// ``HighlightService`` without clobbering ranges set directly through ``TextView/highlightedRanges``.
public final class EmphasisManager {
    public var userHighlightedRanges: [HighlightedRange] = [] {
        didSet {
            if userHighlightedRanges != oldValue {
                syncHighlightedRanges()
            }
        }
    }

    var highlightService: HighlightService? {
        didSet {
            syncHighlightedRanges()
        }
    }

    var onEmphasesChanged: (() -> Void)?
    var onSelectInDocument: ((NSRange) -> Void)?

    private var emphasesByGroup: [String: [HighlightedRange]] = [:]
    private var flashWorkItems: [String: DispatchWorkItem] = [:]

    public init() {}

    public func addEmphasis(_ emphasis: Emphasis, for group: String, color: UIColor) {
        addEmphases([emphasis], for: group, color: color)
    }

    public func addEmphases(_ emphases: [Emphasis], for group: String, color: UIColor) {
        var ranges = emphasesByGroup[group, default: []]
        for emphasis in emphases {
            let highlightedRange = HighlightedRange(emphasis: emphasis, group: group, color: resolvedColor(for: emphasis, baseColor: color))
            ranges.append(highlightedRange)
            if emphasis.selectInDocument {
                onSelectInDocument?(emphasis.range)
            }
            if emphasis.flash {
                scheduleFlashRemoval(for: highlightedRange.id, group: group)
            }
        }
        emphasesByGroup[group] = ranges
        syncHighlightedRanges()
    }

    public func replaceEmphases(_ emphases: [Emphasis], for group: String, color: UIColor) {
        removeEmphases(for: group)
        addEmphases(emphases, for: group, color: color)
    }

    public func removeEmphases(for group: String) {
        emphasesByGroup[group]?.forEach { cancelFlashRemoval(for: $0.id) }
        emphasesByGroup[group] = nil
        syncHighlightedRanges()
    }

    public func removeAllEmphases() {
        emphasesByGroup.keys.forEach { removeEmphases(for: $0) }
    }

    public func getEmphases(for group: String) -> [Emphasis] {
        emphasesByGroup[group, default: []].map { highlightedRange in
            Emphasis(range: highlightedRange.range,
                     style: highlightedRange.style,
                     flash: false,
                     inactive: highlightedRange.isInactive,
                     selectInDocument: false)
        }
    }
}

private extension EmphasisManager {
    private func resolvedColor(for emphasis: Emphasis, baseColor: UIColor) -> UIColor {
        switch emphasis.style {
        case .standard:
            return emphasis.inactive ? baseColor.withAlphaComponent(0.25) : baseColor
        case .underline(let color), .squiggle(let color), .outline(let color, _):
            return color
        }
    }

    private func syncHighlightedRanges() {
        let emphasisRanges = emphasesByGroup.values.flatMap { $0 }
        highlightService?.highlightedRanges = userHighlightedRanges + emphasisRanges
        onEmphasesChanged?()
    }

    private func scheduleFlashRemoval(for id: String, group: String) {
        cancelFlashRemoval(for: id)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.emphasesByGroup[group]?.removeAll { $0.id == id }
            if self.emphasesByGroup[group]?.isEmpty == true {
                self.emphasesByGroup[group] = nil
            }
            self.flashWorkItems[id] = nil
            self.syncHighlightedRanges()
        }
        flashWorkItems[id] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: workItem)
    }

    private func cancelFlashRemoval(for id: String) {
        flashWorkItems[id]?.cancel()
        flashWorkItems[id] = nil
    }
}
