import Foundation
import GitIntelligence

/// The project-relative files `grep`, `glob` and Find in Files should open inside a work tree.
enum IDEGitVisibleFiles {
    /// Nil when `directory` is not a git checkout, or git could not answer. An empty set means
    /// git answered and listed nothing.
    static func relativePaths(under directory: URL) async -> Set<String>? {
        await GitRepository.visibleFiles(under: directory).map(Set.init)
    }
}
