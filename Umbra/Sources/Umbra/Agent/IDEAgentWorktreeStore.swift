import Foundation
import GitIntelligence

/// A worktree Umbra created for an agent chat.
struct IDEAgentWorktreeRecord: Codable, Equatable, Sendable {
    var path: String
    var branch: String
    var createdAt: Date
}

/// The worktrees Umbra created for agent chats. They live under Application Support (inside the
/// app container, so no extra folder grant is needed), one folder per chat, each on its own
/// branch. A manifest remembers what Umbra created; only those paths are ever removed.
struct IDEAgentWorktreeStore: Sendable {
    enum Failure: Error, LocalizedError {
        case notManifested(String)
        case git(String)

        var errorDescription: String? {
            switch self {
            case .notManifested(let path): "Not removing \(path): it is not a worktree Umbra created."
            case .git(let message): message
            }
        }
    }

    let directory: URL
    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

    static func `default`() -> IDEAgentWorktreeStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return IDEAgentWorktreeStore(directory: base.appendingPathComponent("com.umbra.editor/Worktrees", isDirectory: true))
    }

    /// What Umbra created and has not discarded, dropping entries whose folder is already gone.
    func records() -> [IDEAgentWorktreeRecord] {
        guard let data = try? Data(contentsOf: manifestURL),
              let records = try? JSONDecoder().decode([IDEAgentWorktreeRecord].self, from: data)
        else { return [] }
        return records.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Whether `path` is a live worktree from the manifest. Discard checks this before deleting.
    func contains(path: String) -> Bool {
        records().contains {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path
                == URL(fileURLWithPath: path).standardizedFileURL.path
        }
    }

    /// A branch name from the chat title: lowercased words joined with dashes, suffixed when taken.
    static func branchName(for title: String, taken: Set<String>) -> String {
        let words = title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        var base = words.prefix(6).joined(separator: "-").prefix(40).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if base.isEmpty { base = "worktree" }
        var name = String(base)
        var suffix = 2
        while taken.contains(name) { name = "\(base)-\(suffix)"; suffix += 1 }
        return name
    }

    /// Creates a worktree for a new chat: a folder under Application Support on a new branch named
    /// from `title`. Returns the worktree and the branch.
    @discardableResult
    func create(repository: GitRepository, title: String) async throws -> (path: URL, branch: String) {
        let localBranches: Set<String>
        do {
            localBranches = Set(try await repository.branches().filter { $0.kind == .localBranch }.map(\.name))
        } catch {
            throw Failure.git(error.localizedDescription)
        }
        let branch = Self.branchName(for: title, taken: localBranches)
        var url = directory.appendingPathComponent(branch, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(branch)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = try await repository.worktreeAdd(path: url.path, branch: branch)
        } catch {
            throw Failure.git(error.localizedDescription)
        }
        var records = records()
        records.append(IDEAgentWorktreeRecord(path: url.path, branch: branch, createdAt: Date()))
        save(records)
        return (url, branch)
    }

    /// Removes the worktree at `path` and deletes its branch, after verifying the path is in the
    /// manifest. Refuses anything else, even inside the repository.
    func discard(repository: GitRepository, path: String) async throws -> String {
        guard contains(path: path) else { throw Failure.notManifested(path) }
        let branch = records().first {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path
                == URL(fileURLWithPath: path).standardizedFileURL.path
        }?.branch
        do {
            _ = try await repository.worktreeRemove(path: path)
        } catch {
            throw Failure.git(error.localizedDescription)
        }
        save(records().filter {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path
                != URL(fileURLWithPath: path).standardizedFileURL.path
        })
        guard let branch else { return "Removed the worktree." }
        do {
            _ = try await repository.deleteBranch(branch)
            return "Removed the worktree and deleted \(branch)."
        } catch {
            return "Removed the worktree, but \(branch) is still there: \(error.localizedDescription)"
        }
    }

    private func save(_ records: [IDEAgentWorktreeRecord]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(records).write(to: manifestURL, options: .atomic)
    }
}
