import Foundation
import GitIntelligence
import JavaIntelligence

/// The runner the Git model uses. While a repository is not trusted (`gitTrust`), every command runs
/// with the filter commands its own config defines blanked out: `git status` and `git diff` run a
/// file's `filter.<name>.clean` to compare it with the index, so just opening a repository would run
/// that program. Once the user trusts the repository (the question `confirmTrusted` asks before a
/// change) the commands run unchanged, so staging applies the real filter.
///
/// A repository with no `[filter` section in its `.git/config` costs one file read per command and
/// no process; one with filters costs one `git config` per change of that file.
final class IDEGitTrustRunner: GitRunning, @unchecked Sendable {
    private let base: any GitRunning
    private let trust: ProjectTrustStore
    private let lock = NSLock()
    private var cache: [String: (stamp: Date?, overrides: [String])] = [:]

    init(base: any GitRunning, trust: ProjectTrustStore) {
        self.base = base
        self.trust = trust
    }

    func run(
        _ arguments: [String], in directory: URL, stdin: Data?, environment: [String: String]?,
        onProgress: GitProgressHandler?
    ) async throws -> GitOutput {
        var effective = arguments
        if !trust.isTrusted(directory) {
            effective = await overrides(for: directory) + arguments
        }
        return try await base.run(effective, in: directory, stdin: stdin, environment: environment, onProgress: onProgress)
    }

    private func overrides(for directory: URL) async -> [String] {
        guard let config = Self.configFile(for: directory) else { return [] }
        let stamp = (try? FileManager.default.attributesOfItem(atPath: config.path)[.modificationDate]) as? Date
        let key = directory.standardizedFileURL.path
        if let hit = lock.withLock({ cache[key] }), hit.stamp == stamp { return hit.overrides }
        let text = (try? String(contentsOf: config, encoding: .utf8))?.lowercased() ?? ""
        var found: [String] = []
        // An include can bring a filter section in from another file, so it is asked about too.
        if text.contains("[filter") || text.contains("[include") {
            found = await GitRepository(root: directory, runner: base).filterOverrides()
        }
        lock.withLock { cache[key] = (stamp, found) }
        return found
    }

    /// The `config` file of the repository whose work tree is `directory`: `.git/config`, or for a
    /// linked worktree (`.git` is a file) the main repository's, through `commondir`.
    static func configFile(for directory: URL) -> URL? {
        let dotGit = directory.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGit.appendingPathComponent("config") }
        guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let gitDirectory = URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
        if let common = try? String(contentsOf: gitDirectory.appendingPathComponent("commondir"), encoding: .utf8) {
            let name = common.trimmingCharacters(in: .whitespacesAndNewlines)
            return URL(fileURLWithPath: name, relativeTo: gitDirectory).standardizedFileURL.appendingPathComponent("config")
        }
        return gitDirectory.appendingPathComponent("config")
    }
}
