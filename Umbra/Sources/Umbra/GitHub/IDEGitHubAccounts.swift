import Foundation
import Observation

@MainActor
@Observable
final class IDEGitHubAccounts {
    typealias Service = GitHubAccounts<ContinuousClock>

    static let shared: IDEGitHubAccounts = {
        let bundle = Bundle.main
        guard let appID = bundle.bundleIdentifier,
              let clientID = configurationValue(bundle.object(forInfoDictionaryKey: "UmbraGitHubClientID"))
        else { return IDEGitHubAccounts(service: nil) }
        let transport = GitHubTransport()
        return IDEGitHubAccounts(
            service: Service(
                transport: transport, clientID: clientID, clock: ContinuousClock(),
                store: GitHubKeychain(distributionIdentifier: appID, clientID: clientID)
            ),
            transport: transport,
            installationSlug: configurationValue(bundle.object(forInfoDictionaryKey: "UmbraGitHubAppSlug"))
        )
    }()

    private static func configurationValue(_ raw: Any?) -> String? {
        guard let value = raw as? String, (1...128).contains(value.utf8.count),
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 })
        else { return nil }
        return value
    }

    let service: Service?
    let metadataClient: GitHubMetadataClient?
    let installationURL: URL?
    private(set) var identities: [GitHubIdentity] = []
    private(set) var revision = 0
    private(set) var loadError: String?

    init(service: Service?, transport: GitHubTransport? = nil, installationSlug: String? = nil) {
        self.service = service
        metadataClient = transport.map { GitHubMetadataClient(transport: $0) }
        installationURL = installationSlug.flatMap { URL(string: "https://github.com/apps/\($0)/installations/new") }
    }

    func reload() async {
        guard let service else { return }
        let started = revision
        do {
            let loaded = try await service.identities()
            guard !Task.isCancelled, started == revision else { return }
            loadError = nil
            if loaded != identities {
                identities = loaded
                revision += 1
            }
        } catch {
            guard !Task.isCancelled, started == revision else { return }
            loadError = "Umbra couldn’t read GitHub accounts from Keychain."
        }
    }

    func didSignIn(_ identity: GitHubIdentity) async {
        await metadataClient?.invalidate(userID: identity.id)
        identities = (identities.filter { $0.id != identity.id } + [identity]).sorted { $0.id < $1.id }
        revision += 1
    }

    func signOut(_ id: Int64) async throws {
        try await service?.signOut(userID: id)
        identities.removeAll { $0.id == id }
        revision += 1
        await metadataClient?.invalidate(userID: id)
    }
}

enum IDEGitHubMessage {
    static func describe(_ error: Error) -> String {
        switch error {
        case GitHubAuthorizationError.denied: "GitHub sign-in was declined."
        case GitHubAuthorizationError.expired: "The sign-in code expired. Start again to get a new code."
        case GitHubAuthorizationError.unavailable: "Device sign-in is disabled for this GitHub App."
        case GitHubAuthorizationError.reauthorizationRequired, GitHubAccountError.signedOut,
             GitHubTransportError.httpStatus(401): "Sign in again in GitHub settings."
        case GitHubAccountError.identityChanged: "The browser authorized a different GitHub account."
        case GitHubTransportError.httpStatus(403), GitHubTransportError.httpStatus(404):
            "GitHub couldn’t grant access. Check the repository and the account’s GitHub App installation."
        case GitHubTransportError.rateLimited, GitHubTransportError.httpStatus(429): "GitHub is limiting requests. Try again later."
        case GitHubTransportError.connectionFailed: "Umbra couldn’t reach GitHub. Check your connection and try again."
        case is GitHubCredentialError: "Umbra couldn’t access your GitHub account in Keychain."
        default: "GitHub couldn’t complete the request. Try again."
        }
    }
}
