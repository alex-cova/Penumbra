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
        return await run(transport: transport, workingDirectory: workingDirectory, timeout: timeout)
    }

    /// The same check for a launch the resolver picked (a managed adapter, a system adapter, a
    /// native CLI). `leases` is nil for the install check, which runs from a staging folder.
    static func run(
        definition: IDEACPDefinition,
        launch: IDEACPResolvedLaunch,
        workingDirectory: URL,
        environment: [String: String],
        leases: IDEACPAdapterLeases? = .shared,
        timeout: Duration = .seconds(15)
    ) async -> IDEACPProbe.Phase {
        let transport = IDEACPTransport(
            definition: definition, launch: launch, workingDirectory: workingDirectory,
            environment: environment, leases: leases)
        return await run(transport: transport, workingDirectory: workingDirectory, timeout: timeout)
    }

    private static func run(
        transport: IDEACPTransport, workingDirectory: URL, timeout: Duration
    ) async -> IDEACPProbe.Phase {
        let phase = await handshake(transport: transport, workingDirectory: workingDirectory, timeout: timeout)
        // Wait for the child to be reaped, so the version it used can be replaced right after.
        await transport.waitForExit()
        return phase
    }

    private static func handshake(
        transport: IDEACPTransport, workingDirectory: URL, timeout: Duration
    ) async -> IDEACPProbe.Phase {
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
                return .failed(failureText(error, transport: transport))
            }
        } catch {
            await session.close()
            return .failed(failureText(error, transport: transport))
        }
    }

    /// The error plus the last lines the process wrote to stderr, scrubbed and bounded.
    private static func failureText(_ error: Error, transport: IDEACPTransport) -> String {
        let base = IDEACPSecretScrubber.scrub(error.localizedDescription)
        guard let detail = IDEACPDiagnostics.detail(transport.recentStderr) else { return base }
        return "\(base)\n\(detail)"
    }
}
