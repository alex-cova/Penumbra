@preconcurrency import AppKit
import Foundation

/// Keeps an ``ErrorStripeView`` in step with a text view's diagnostics. Positions are recomputed
/// when the diagnostics change and, debounced, when the content height changes (edits move the
/// ticks), never per scrolled frame.
@MainActor
final class ErrorStripeController {
    let view = ErrorStripeView(frame: .zero)

    /// Maps a UTF-16 offset to its fraction of the document height, or `nil` past the end.
    var fractionForOffset: ((Int) -> CGFloat?)?
    /// Most diagnostics ticked; the most severe win when there are more.
    static let maxMarks = 2_000
    var debounceInterval: TimeInterval = 0.2

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { refresh() } else { view.setMarks([]) }
        }
    }

    private var diagnostics: [TextViewDiagnostic] = []
    private var pending: DispatchWorkItem?

    func setDiagnostics(_ diagnostics: [TextViewDiagnostic]) {
        self.diagnostics = diagnostics
        refresh()
    }

    /// The content moved (an edit changed the height or line positions): recompute shortly.
    func contentDidChange() {
        guard isEnabled, !diagnostics.isEmpty, pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    func refresh() {
        pending?.cancel()
        pending = nil
        guard isEnabled, let fractionForOffset else {
            view.setMarks([])
            return
        }
        let chosen = diagnostics.count > Self.maxMarks
            ? Array(diagnostics.sorted { $0.severity.stripeRank > $1.severity.stripeRank }.prefix(Self.maxMarks))
            : diagnostics
        view.setMarks(chosen.compactMap { diagnostic in
            fractionForOffset(diagnostic.range.location).map { ErrorStripeMark(fraction: $0, severity: diagnostic.severity) }
        })
    }
}
