import Foundation

/// Coordinates multiple ``HighlightProviding`` sources and caches merged highlight ranges.
@MainActor
public final class HighlightProviderCoordinator: VisibleRangeProvider.Delegate {
    public private(set) var providers: [HighlightProviding] = []
    private weak var textView: TextView?
    private var visibleRangeProvider: VisibleRangeProvider?
    private var cachedRanges: [SyntaxHighlightRange] = []
    private var invalidatedIndices = IndexSet()

    public var onHighlightsChanged: (() -> Void)?

    public init() {}

    public func attach(to textView: TextView, providers: [HighlightProviding]) {
        self.textView = textView
        self.providers = providers
        for provider in providers {
            provider.setUp(textView: textView)
        }
        let visibleProvider = VisibleRangeProvider(textView: textView)
        visibleProvider.delegate = self
        visibleRangeProvider = visibleProvider
        refreshHighlights(in: visibleProvider.visibleIndices)
    }

    public func willApplyEdit(in range: NSRange) {
        for provider in providers {
            provider.willApplyEdit(range: range)
        }
    }

    public func applyEdit(in range: NSRange, delta: Int) {
        let group = DispatchGroup()
        var merged = IndexSet()
        for provider in providers {
            group.enter()
            provider.applyEdit(range: range, delta: delta) { result in
                if case .success(let indices) = result {
                    merged.formUnion(indices)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.invalidatedIndices.formUnion(merged)
            self.refreshHighlights(in: merged)
        }
    }

    public func highlights(intersecting range: NSRange) -> [SyntaxHighlightRange] {
        cachedRanges.filter { NSIntersectionRange($0.range, range).length > 0 }
    }

    func visibleRangeProvider(_ provider: VisibleRangeProvider, didUpdate indices: IndexSet) {
        refreshHighlights(in: indices)
    }

    private func refreshHighlights(in indices: IndexSet) {
        guard textView != nil, !indices.isEmpty else {
            return
        }
        let queryRange = NSRange(location: indices.min() ?? 0, length: (indices.max() ?? 0) - (indices.min() ?? 0) + 1)
        let group = DispatchGroup()
        var merged: [SyntaxHighlightRange] = []
        for provider in providers {
            group.enter()
            provider.queryHighlightsFor(range: queryRange) { result in
                if case .success(let ranges) = result {
                    merged.append(contentsOf: ranges)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.cachedRanges = merged
            self.invalidatedIndices.subtract(indices)
            self.onHighlightsChanged?()
        }
    }
}
