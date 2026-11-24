import Foundation
import GitIntelligence
import Observation

@MainActor
@Observable
final class IDEGitHubWorkspaceModel {
    struct Remote: Hashable, Identifiable {
        let name: String
        let repository: GitHubRemote

        var id: String { name }
    }

    private(set) var remotes: [Remote] = []
    private(set) var discovering = false
    private(set) var metadata: GitHubRepositoryMetadata?
    private(set) var loading = false
    private(set) var failure: String?
    private(set) var selectedRemote: String?
    private var selectedAccount: Int64?
    private(set) var requestRevision: Int?

    @ObservationIgnored private var repository: GitRepository?
    @ObservationIgnored private var upstream: String?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored private var metadataTask: Task<Void, Never>?
    @ObservationIgnored private var needsDiscovery = true
    @ObservationIgnored private var explicitlySelectedRemote = false

    func updateRepository(_ repository: GitRepository?, upstream: String?) {
        if self.repository?.id != repository?.id {
            resetDiscovery()
            selectedAccount = nil
            self.repository = repository
            self.upstream = upstream
            discoverIfNeeded()
        } else if self.upstream != upstream {
            self.upstream = upstream
            if !explicitlySelectedRemote, selectedRemote != preferredRemote {
                cancelMetadata()
                selectedRemote = preferredRemote
            }
        }
    }

    func activate() {
        active = true
        discoverIfNeeded()
    }

    func deactivate() {
        active = false
        cancelMetadata()
        if discoveryTask != nil {
            discoveryTask?.cancel()
            discoveryTask = nil
            discovering = false
            needsDiscovery = true
        }
    }

    func refreshRemotes() {
        resetDiscovery()
        discoverIfNeeded()
    }

    func selectRemote(_ name: String?) {
        cancelMetadata()
        explicitlySelectedRemote = name != nil
        selectedRemote = name
    }

    func selectAccount(_ id: Int64?) {
        cancelMetadata()
        selectedAccount = id
    }

    func loadMetadata(using accounts: IDEGitHubAccounts) async {
        guard active, !Task.isCancelled else { return }
        cancelMetadata()
        guard
              let remote = remotes.first(where: { $0.name == selectedRemote }),
              let account = accountID(accounts.identities),
              let service = accounts.service, let client = accounts.metadataClient
        else { return }

        loading = true
        let revision = accounts.revision
        requestRevision = revision
        let operation = Task { [weak self] in
            defer {
                if !Task.isCancelled { self?.loading = false }
            }
            do {
                let value = try await client.repository(remote.repository, userID: account, accounts: service)
                try Task.checkCancellation()
                guard accounts.revision == revision else { return }
                self?.metadata = value
            } catch {
                if !Task.isCancelled, accounts.revision == revision { self?.failure = IDEGitHubMessage.describe(error) }
            }
        }
        metadataTask = operation
        await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    func accountID(_ identities: [GitHubIdentity]) -> Int64? {
        if let selectedAccount {
            return identities.contains(where: { $0.id == selectedAccount }) ? selectedAccount : nil
        }
        return identities.count == 1 ? identities.first?.id : nil
    }

    private var preferredRemote: String? {
        if let upstream, let tracking = remotes.filter({ upstream.hasPrefix($0.name + "/") })
            .max(by: { $0.name.count < $1.name.count }) {
            return tracking.name
        }
        return remotes.count == 1 ? remotes.first?.name : nil
    }

    private func discoverIfNeeded() {
        guard active, needsDiscovery, let repository else { return }
        needsDiscovery = false
        discovering = true
        discoveryTask = Task { [weak self] in
            let remotes = await repository.remoteDetails()
            guard let self, !Task.isCancelled else { return }
            self.remotes = remotes.compactMap { remote in
                GitHubRemote(fetchURL: remote.fetchURL).map { Remote(name: remote.name, repository: $0) }
            }
            self.selectedRemote = self.preferredRemote
            self.discovering = false
            self.discoveryTask = nil
        }
    }

    private func cancelMetadata() {
        metadataTask?.cancel()
        metadataTask = nil
        loading = false
        metadata = nil
        failure = nil
        requestRevision = nil
    }

    private func resetDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
        discovering = false
        needsDiscovery = true
        explicitlySelectedRemote = false
        selectedRemote = nil
        remotes = []
        cancelMetadata()
    }
}
