import AgentKit
import Foundation

/// Starts an allowed agent, performs `initialize` (and `session/new` when the agent lists
/// auth methods), then closes the process. Called only from the Test button or an equivalent
/// explicit action — discovery does not use it.
enum IDEACPConnectionTest {
    static func run(
        definition: IDEACPDefinition,
        workingDirectory: URL,
        environment: [String: String],
        timeout: Duration = .seconds(8)
    ) async -> IDEACPProbe.Phase {
        guard definition.resolvedExecutable(pathValue: environment["PATH"] ?? "") != nil else {
            return .failed(definition.missingExecutableMessage)
        }
        let transport = IDEACPTransport(
            definition: definition, workingDirectory: workingDirectory, environment: environment)
        let session = ACPClientSession(
            transport: transport, cwd: workingDirectory.path, requestTimeout: timeout)
        do {
            let response = try await session.connect()
            let name = response.agentInfo?.title ?? response.agentInfo?.name
            if response.authMethods.isEmpty {
                await session.close()
                return .connected(
                    protocolVersion: response.protocolVersion, agentName: name,
                    loadSession: response.agentCapabilities.loadSession)
            }
            do {
                _ = try await session.newSession()
                await session.close()
                return .connected(
                    protocolVersion: response.protocolVersion, agentName: name,
                    loadSession: response.agentCapabilities.loadSession)
            } catch {
                await session.close()
                if IDEACPAuth.isAuthenticationFailure(error) {
                    return .authenticationRequired(response.authMethods.first?.name ?? "Sign in")
                }
                return .failed(IDEACPSecretScrubber.scrub(error.localizedDescription))
            }
        } catch {
            await session.close()
            return .failed(IDEACPSecretScrubber.scrub(error.localizedDescription))
        }
    }
}
