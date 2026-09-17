import Foundation

/// Renders ``TextViewDiagnostic`` values through ``EmphasisManager``.
final class DiagnosticEmphasisController {
    weak var emphasisManager: EmphasisManager?

    private(set) var diagnostics: [TextViewDiagnostic] = []

    func setDiagnostics(_ diagnostics: [TextViewDiagnostic]) {
        self.diagnostics = diagnostics
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
