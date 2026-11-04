import EditorIntelligence
import Foundation

extension NavigationResult {
    /// This result was computed for `textView`'s buffer at `generation`. When the buffer has
    /// changed since, targets inside it are offsets of text that no longer exists, so they are
    /// dropped (the user's edit wins over a late answer); targets in other files are unaffected.
    /// Returns nil when nothing is left.
    @MainActor
    func discardingTargets(in textView: TextView?, changedSince generation: UInt64) -> NavigationResult? {
        guard let textView, textView.contentGeneration != generation else { return self }
        func isInCurrentBuffer(_ location: Location) -> Bool {
            guard location.target == .source else { return false }
            guard let url = location.url else { return true }
            return url == textView.documentURL
        }
        switch self {
        case .single(let location):
            return isInCurrentBuffer(location) ? nil : self
        case .multiple(let locations):
            let kept = locations.filter { !isInCurrentBuffer($0) }
            return kept.isEmpty ? nil : .multiple(kept)
        }
    }
}
