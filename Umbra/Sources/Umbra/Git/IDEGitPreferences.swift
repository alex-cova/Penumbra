import Darwin
import Foundation
import GitIntelligence

/// Version control settings that live in `UserDefaults` and are read where they are used.
enum IDEGitPreferences {
    static let updateStrategyKey = "umbra.git.updateStrategy"
    static let asksBeforeUpdateKey = "umbra.git.asksBeforeUpdate"
    static let protectedBranchesKey = "umbra.git.protectedBranches"
    static let fetchIntervalKey = "umbra.git.fetchIntervalMinutes"

    static let defaultProtectedBranches = "main, master"

    /// What Update Project does when it does not ask: rebase or merge.
    static var updateStrategy: GitPullStrategy {
        get { UserDefaults.standard.string(forKey: updateStrategyKey) == "rebase" ? .rebase : .merge }
        set { UserDefaults.standard.set(newValue == .rebase ? "rebase" : "merge", forKey: updateStrategyKey) }
    }

    static var asksBeforeUpdate: Bool {
        get { UserDefaults.standard.object(forKey: asksBeforeUpdateKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: asksBeforeUpdateKey) }
    }

    /// Glob patterns (`main`, `release/*`) of branches that refuse a force push and ask before a delete.
    static var protectedBranchPatterns: [String] {
        get { patterns(from: UserDefaults.standard.string(forKey: protectedBranchesKey) ?? defaultProtectedBranches) }
        set { UserDefaults.standard.set(newValue.joined(separator: ", "), forKey: protectedBranchesKey) }
    }

    /// Minutes between background fetches; 0 (the default) never fetches by itself.
    static var fetchIntervalMinutes: Int {
        get { max(0, UserDefaults.standard.integer(forKey: fetchIntervalKey)) }
        set { UserDefaults.standard.set(max(0, newValue), forKey: fetchIntervalKey) }
    }

    static func patterns(from text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func isProtected(_ branch: String, patterns: [String]? = nil) -> Bool {
        (patterns ?? protectedBranchPatterns).contains { fnmatch($0, branch, 0) == 0 }
    }

    /// The default for the Update Project sheet: `pull.rebase` of the repository when it is set,
    /// else the last choice the user made.
    static func initialUpdateStrategy(repositoryPullRebase: String?) -> GitPullStrategy {
        switch repositoryPullRebase?.lowercased() {
        case "true", "merges", "interactive": return .rebase
        case "false": return .merge
        default: return updateStrategy
        }
    }
}
