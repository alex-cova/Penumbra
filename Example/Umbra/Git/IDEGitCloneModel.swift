import Foundation
import GitIntelligence
import Observation

/// The state of one Clone Repository dialog. It lives outside the sheet view so a credential
/// prompt that interrupts the clone does not lose what was typed.
@MainActor
@Observable
final class IDEGitCloneModel {
    var url = ""
    var parentDirectory: URL
    var name = ""
    var recurseSubmodules = true
    /// The folder name follows the address until the user types one.
    private var nameWasEdited = false

    private(set) var isWorking = false
    private(set) var progress: GitProgress?
    private(set) var error: String?
    private(set) var checkResult: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let networkSession: String
    @ObservationIgnored var onFinished: (@MainActor (URL) -> Void)?

    init(parentDirectory: URL? = nil, networkSession: String, clipboard: String? = nil) {
        self.parentDirectory = parentDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Developer", isDirectory: true)
        self.networkSession = networkSession
        if let clipboard, Self.looksLikeRepositoryAddress(clipboard) {
            url = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
            name = GitRepository.repositoryName(fromURL: url)
        }
    }

    /// `https://…`, `ssh://…`, `git@host:path`, `git://…`: what a clone address looks like.
    static func looksLikeRepositoryAddress(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n"), !trimmed.contains(" ") else { return false }
        if ["https://", "http://", "ssh://", "git://"].contains(where: { trimmed.hasPrefix($0) }) { return true }
        return trimmed.range(of: #"^[\w.-]+@[\w.-]+:[\w./-]+$"#, options: .regularExpression) != nil
    }

    func urlDidChange() {
        error = nil
        checkResult = nil
        if !nameWasEdited { name = GitRepository.repositoryName(fromURL: url) }
    }

    func nameDidChange() {
        nameWasEdited = !name.isEmpty
        error = nil
    }

    var destination: URL? {
        let folder = name.trimmingCharacters(in: .whitespaces)
        guard !folder.isEmpty, !folder.contains("/"), !folder.hasPrefix(".") else { return nil }
        return parentDirectory.appendingPathComponent(folder, isDirectory: true)
    }

    var canClone: Bool {
        !isWorking && destination != nil && !url.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var environment: GitNetworkEnvironment {
        IDEGitAskPassServer.shared.environment(session: networkSession)
    }

    func check() {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        checkResult = nil
        let address = url
        let network = environment
        task = Task { [weak self] in
            do {
                try await GitRepository.checkRemote(url: address, network: network, runner: IDEGitSupport.runner)
                self?.checkResult = "The repository answers."
            } catch {
                guard !Task.isCancelled else { return }
                self?.error = IDEGitSupport.describe(error)
            }
            self?.isWorking = false
        }
    }

    func clone() {
        guard canClone, let destination else { return }
        isWorking = true
        error = nil
        progress = nil
        let address = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let recurse = recurseSubmodules
        let network = environment
        let existedBefore = FileManager.default.fileExists(atPath: destination.path)
        task = Task { [weak self] in
            do {
                _ = try await GitRepository.clone(
                    url: address, into: destination, recurseSubmodules: recurse, network: network,
                    runner: IDEGitSupport.runner,
                    onProgress: { value in Task { @MainActor in self?.progress = value } })
                guard let self else { return }
                self.isWorking = false
                self.onFinished?(destination)
            } catch {
                // A cancelled or failed clone leaves a partial folder behind: remove what it made.
                if !existedBefore { try? FileManager.default.removeItem(at: destination) }
                guard let self else { return }
                self.isWorking = false
                if !Task.isCancelled { self.error = IDEGitSupport.describe(error) }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isWorking = false
        progress = nil
    }
}
