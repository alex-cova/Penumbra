import Foundation

/// Renders ``TextViewDiagnostic`` values through ``EmphasisManager``.
final class DiagnosticEmphasisController {
    weak var emphasisManager: EmphasisManager?

    private(set) var diagnostics: [TextViewDiagnostic] = []

    func setDiagnostics(_ diagnostics: [TextViewDiagnostic]) {
        self.diagnostics = diagnostics
        syncEmphases()
    }

    /// `range` of the old text was replaced by `newLength` UTF-16 units: markers ending at
    /// or before the edit stay, markers starting at or after it shift by the delta, and a
    /// marker the edit touches is dropped. Same drop-on-overlap semantics as
    /// `SemanticHighlightStore` and `InlayHintIndex`: a squiggle never stretches over freshly
    /// typed text with a stale message. Ids survive, so the next report can match by content.
    func applyEdit(range: NSRange, newLength: Int) {
        guard !diagnostics.isEmpty else { return }
        let delta = newLength - range.length
        var kept: [TextViewDiagnostic] = []
        kept.reserveCapacity(diagnostics.count)
        for diagnostic in diagnostics {
            if diagnostic.range.upperBound <= range.location {
                kept.append(diagnostic)
            } else if diagnostic.range.location >= range.upperBound {
                kept.append(TextViewDiagnostic(
                    id: diagnostic.id,
                    range: NSRange(location: diagnostic.range.location + delta, length: diagnostic.range.length),
                    severity: diagnostic.severity,
                    message: diagnostic.message,
                    source: diagnostic.source,
                    code: diagnostic.code
                ))
            }
        }
        diagnostics = kept
        syncEmphases()
    }

    func clearDiagnostics() {
        diagnostics = []
        emphasisManager?.removeEmphases(for: EmphasisGroup.diagnostics)
    }

    private func syncEmphases() {
        guard let emphasisManager else {
            return
        }
        let emphases = diagnostics.map { diagnostic in
            Emphasis(range: diagnostic.range,
                     style: .squiggle(color: diagnostic.severity.squiggleColor))
        }
        emphasisManager.replaceEmphases(emphases, for: EmphasisGroup.diagnostics, color: .clear)
    }
}
