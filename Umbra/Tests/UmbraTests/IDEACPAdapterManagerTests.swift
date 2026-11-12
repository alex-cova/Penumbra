import AgentKit
import Foundation
import XCTest
@testable import Umbra

private final class TestClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

@MainActor
final class IDEACPAdapterManagerTests: XCTestCase {
    private struct Harness {
        let root: ACPTestRoot
        let fetcher: ACPFixtureFetcher
        let npm: ACPFakeNpm
        let manager: IDEACPAdapterManager
        let settings: IDEAgentSettings
        let clock: TestClock
    }

    private var harnesses: [Harness] = []
    private var savedShared: IDEACPAdapterManager!

    override func setUp() async throws { savedShared = IDEACPAdapterManager.shared }
    override func tearDown() async throws {
        IDEACPAdapterManager.shared = savedShared
        harnesses.forEach { $0.root.cleanUp() }
        harnesses = []
    }

    private func harness(
        sandboxed: Bool = false, node: IDEACPNodeInstallation? = acpFakeNode(),
        smoke: IDEACPProbe.Phase = .connected(protocolVersion: 1, agentName: "Fake", loadSession: false),
        configure: (ACPFixtureFetcher, ACPFakeNpm) throws -> Void = { _, _ in }
    ) throws -> Harness {
        let root = try ACPTestRoot()
        let fetcher = ACPFixtureFetcher()
        try fetcher.serve(package: "@agentclientprotocol/codex-acp", fixture: ACPFixtures.codex, version: "2.6.0")
        try fetcher.serve(package: "@agentclientprotocol/claude-agent-acp", fixture: ACPFixtures.claude, version: "0.106.0")
        let codex = try ACPFixtures.version(ACPFixtures.codex)
        let claude = try ACPFixtures.version(ACPFixtures.claude)
        let npm = ACPFakeNpm(packages: [
            .init(name: codex.name, version: codex.version, integrity: codex.dist.integrity!),
            .init(name: claude.name, version: claude.version, integrity: claude.dist.integrity!),
        ])
        try configure(fetcher, npm)
        let registry = IDEACPNpmRegistry(fetcher: fetcher)
        let installer = IDEACPAdapterInstaller(environment: .init(
            store: root.store, registry: registry, npm: npm, locateNode: { node }, smokeTest: { _ in smoke },
            freeBytes: { Int64.max }, hostArchitecture: "arm64", npmTimeout: .seconds(30), progressInterval: .milliseconds(20)))
        let clock = TestClock()
        let defaults = UserDefaults(suiteName: "umbra.acp.manager.\(UUID().uuidString)")!
        let manager = IDEACPAdapterManager(
            store: root.store, registry: registry, installer: installer, defaults: defaults, isSandboxed: sandboxed,
            pathProvider: { "/usr/bin:/bin" }, now: { clock.date })
        let settings = IDEAgentSettings(defaults: defaults, keyStore: IDEAgentMemoryKeyStore())
        let made = Harness(root: root, fetcher: fetcher, npm: npm, manager: manager, settings: settings, clock: clock)
        harnesses.append(made)
        return made
    }

    private func installVersion(_ h: Harness, _ version: String, active: Bool = true) throws {
        try acpWriteVersion(h.root.store, version: version, installedAt: Date(timeIntervalSinceNow: -Double(version.count) * 10))
        if active {
            try h.root.store.writeActive("codex-acp", IDEACPActiveManifest(version: version, previous: nil, activatedAt: Date()))
        }
    }

    private func latestRequests(_ h: Harness) -> Int { h.fetcher.requests.filter { $0.hasSuffix("/latest") }.count }

    // MARK: Loading and state

    func testLoadShowsWhatIsOnDiskAndRepairsInterruptedInstalls() async throws {
        let h = try harness()
        try installVersion(h, "2.5.0")
        try acpWriteVersion(h.root.store, version: "9.9.9", writeManifest: false)
        _ = try h.root.store.makeStaging("codex-acp")
        XCTAssertFalse(h.manager.hasLoaded)
        await h.manager.load()
        XCTAssertTrue(h.manager.hasLoaded)
        let state = try XCTUnwrap(h.manager.states["codex-acp"])
        XCTAssertEqual(state.phase, .ready(version: "2.5.0"))
        XCTAssertEqual(state.versions.map(\.version), ["2.5.0"])
        XCTAssertEqual(h.manager.states["claude-agent-acp"]?.phase, .notInstalled)
        XCTAssertEqual(h.manager.states.count, 4, "the native CLIs are listed too")
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.root.store.versionDirectory("codex-acp", "9.9.9").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: h.root.store.stagingDirectory("codex-acp").path), [])
    }

    func testLoadingWhileAnInstallRunsNeverRemovesItsStaging() async throws {
        let h = try harness { _, npm in npm.hangsInInstall = true }
        await h.manager.load()
        _ = try await approveAndInstall(h, "claude-agent-acp")
        let started = await acpWaitUntil { !h.npm.installCalls.isEmpty }
        XCTAssertTrue(started)
        let staging = h.root.store.stagingDirectory("claude-agent-acp")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path).count, 1, "the install's staging folder exists")

        // The Settings section and the provider menu both load when they appear; Codex finishing
        // loads too. None of that may touch an install in progress.
        await h.manager.load()
        await h.manager.load()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path).count, 1, "still there after other loads")
        XCTAssertTrue(h.manager.states["claude-agent-acp"]?.phase.isBusy ?? false)

        h.manager.cancel("claude-agent-acp")
        let back = await acpWaitUntil { h.manager.states["claude-agent-acp"]?.phase == .notInstalled }
        XCTAssertTrue(back)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [], "cancelling removes it")
    }

    func testRecoveryRunsOncePerAdapterAtTheFirstLoad() async throws {
        let h = try harness()
        _ = try h.root.store.makeStaging("codex-acp")
        await h.manager.load()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: h.root.store.stagingDirectory("codex-acp").path), [],
                       "the leftover from a crash was cleaned at startup")
        let later = try h.root.store.makeStaging("codex-acp")
        await h.manager.load()
        XCTAssertTrue(FileManager.default.fileExists(atPath: later.path), "a later load only reads")
    }

    // MARK: Update checks

    func testAnUpdateIsDetectedWithoutDownloadingOrRunningAnything() async throws {
        let h = try harness()
        try installVersion(h, "2.5.0")
        await h.manager.load()
        await h.manager.checkForUpdates()
        XCTAssertEqual(h.manager.states["codex-acp"]?.phase, .updateAvailable(installed: "2.5.0", available: "2.6.0", security: false))
        XCTAssertEqual(h.manager.states["codex-acp"]?.available, "2.6.0")
        XCTAssertEqual(h.manager.states["claude-agent-acp"]?.available, "0.106.0")
        XCTAssertEqual(h.manager.states["claude-agent-acp"]?.phase, .notInstalled, "a check never installs")
        XCTAssertTrue(h.npm.calls.isEmpty)
        XCTAssertFalse(h.fetcher.requests.contains { $0.contains(".tgz") }, "no tarball was fetched")
        XCTAssertNotNil(h.manager.lastChecked)
        XCTAssertEqual(h.root.store.readCachedCheck()?.latest["codex-acp"], "2.6.0")
        XCTAssertEqual(h.root.store.activeInstall("codex-acp")?.version, "2.5.0", "the installed version is untouched")
    }

    func testASecurityUpdateIsDistinguishedFromAnOrdinaryOne() async throws {
        let h = try harness { fetcher, _ in
            fetcher.route(
                "POST https://registry.npmjs.org/-/npm/v1/security/advisories/bulk",
                Data(#"{"@agentclientprotocol/codex-acp":[{"id":1,"title":"Path traversal in session loading","severity":"high"}]}"#.utf8))
        }
        try installVersion(h, "2.5.0")
        await h.manager.load()
        await h.manager.checkForUpdates()
        XCTAssertEqual(h.manager.states["codex-acp"]?.phase, .updateAvailable(installed: "2.5.0", available: "2.6.0", security: true))
        XCTAssertEqual(h.manager.states["codex-acp"]?.advisories, ["Path traversal in session loading"])
        let advisoryRequest = h.fetcher.requests.first { $0.hasPrefix("POST") }
        XCTAssertNotNil(advisoryRequest)
    }

    func testBeingCurrentClearsAnEarlierUpdateNotice() async throws {
        let h = try harness()
        try installVersion(h, "2.6.0")
        await h.manager.load()
        await h.manager.checkForUpdates()
        XCTAssertEqual(h.manager.states["codex-acp"]?.phase, .ready(version: "2.6.0"))
        await h.manager.checkForUpdates()
        XCTAssertEqual(h.manager.states["codex-acp"]?.phase, .ready(version: "2.6.0"))
    }

    func testOfflineKeepsTheInstalledStateAndSaysSo() async throws {
        let h = try harness { fetcher, _ in fetcher.fail(with: URLError(.notConnectedToInternet)) }
        try installVersion(h, "2.5.0")
        await h.manager.load()
        await h.manager.checkForUpdates()
        let state = try XCTUnwrap(h.manager.states["codex-acp"])
        XCTAssertEqual(state.phase, .ready(version: "2.5.0"))
        guard case .offline? = state.checkError else { return XCTFail("\(String(describing: state.checkError))") }
        XCTAssertNil(state.available)
        XCTAssertFalse(h.manager.isChecking)
    }

    func testTheUpdatePreferenceControlsAutomaticChecks() async throws {
        let h = try harness()
        await h.manager.load()
        h.manager.updatePolicy = .manual
        await h.manager.checkIfDue()
        XCTAssertEqual(latestRequests(h), 0, "manual means only when asked")

        h.manager.updatePolicy = .whenOpened
        await h.manager.checkIfDue()
        XCTAssertEqual(latestRequests(h), 2, "one metadata read per managed adapter")
        await h.manager.checkIfDue()
        XCTAssertEqual(latestRequests(h), 2, "not again within six hours")
        h.clock.date.addTimeInterval(7 * 3_600)
        await h.manager.checkIfDue()
        XCTAssertEqual(latestRequests(h), 4)

        h.manager.updatePolicy = .daily
        h.clock.date.addTimeInterval(7 * 3_600)
        await h.manager.checkIfDue()
        XCTAssertEqual(latestRequests(h), 4, "daily waits a day")
        h.clock.date.addTimeInterval(18 * 3_600)
        await h.manager.checkIfDue()
        XCTAssertEqual(latestRequests(h), 6)
        await h.manager.checkForUpdates()
        XCTAssertEqual(latestRequests(h), 8, "Check Now always checks")
    }

    func testThePreferenceIsRememberedAndTheDefaultIsWhenOpened() throws {
        let h = try harness()
        XCTAssertEqual(h.manager.updatePolicy, .whenOpened)
        h.manager.updatePolicy = .daily
        XCTAssertEqual(IDEACPUpdateCheckPolicy.daily.interval, 24 * 3_600)
        XCTAssertNil(IDEACPUpdateCheckPolicy.manual.interval)
    }

    // MARK: Install through the manager

    private func approveAndInstall(_ h: Harness, _ id: String = "codex-acp") async throws -> IDEACPInstallProposal {
        let proposal = try await h.manager.prepareInstall(id)
        h.manager.install(proposal, settings: h.settings)
        return proposal
    }

    func testInstallingExposesTheAgentInSettingsAndKeepsItsRegistryEntry() async throws {
        let h = try harness()
        await h.manager.load()
        XCTAssertEqual(h.settings.acpAgents.count, 0)
        let proposal = try await approveAndInstall(h)
        XCTAssertEqual(proposal.version, "2.6.0")
        let done = await acpWaitUntil { h.manager.states["codex-acp"]?.phase == .ready(version: "2.6.0") }
        XCTAssertTrue(done, "\(String(describing: h.manager.states["codex-acp"]?.phase))")

        let state = try XCTUnwrap(h.manager.states["codex-acp"])
        XCTAssertEqual(state.activeVersion, "2.6.0")
        XCTAssertEqual(state.versions.map(\.version), ["2.6.0"])
        XCTAssertNil(state.progress)
        // The registry row exists, follows the catalog, and may run (the approval was the consent).
        let row = try XCTUnwrap(h.settings.acpAgents.first { $0.presetID == "codex" })
        XCTAssertEqual(row.launchMode, .auto)
        XCTAssertTrue(h.settings.acpAllowedAgentIDs.contains(row.id))
        // It resolves to the managed install.
        let launch = try XCTUnwrap(h.manager.resolution(for: row, pathValue: "/usr/bin:/bin").launch)
        XCTAssertEqual(launch.source, .managed(adapterID: "codex-acp", version: "2.6.0"))
        XCTAssertEqual(h.manager.availability(of: row, settings: h.settings, isLive: false), .installed)
    }

    func testInstallingPreservesAnExistingRowItsSecretsAndWorkspaceDefault() async throws {
        let h = try harness()
        let existing = h.settings.materializePreset(IDEACPRegistry.preset(id: "codex")!)
        h.settings.acpAgents[0].name = "My Codex"
        h.settings.acpAgents[0].env = ["CODEX_HOME": "/Users/me/.codex"]
        try h.settings.saveACPEnvValue("s3cret", agentID: existing.id, key: "CODEX_API_KEY")
        let workspace = URL(fileURLWithPath: "/tmp/some-project")
        h.settings.setWorkspaceDefault(agentID: existing.id, workspace: workspace)
        XCTAssertFalse(h.settings.acpAllowedAgentIDs.contains(existing.id))

        _ = try await approveAndInstall(h)
        let done = await acpWaitUntil { h.manager.states["codex-acp"]?.phase == .ready(version: "2.6.0") }
        XCTAssertTrue(done)

        XCTAssertEqual(h.settings.acpAgents.count, 1, "no duplicate row")
        let row = h.settings.acpAgents[0]
        XCTAssertEqual(row.id, existing.id, "same identity, so chats stay bound")
        XCTAssertEqual(row.name, "My Codex")
        XCTAssertEqual(row.env, ["CODEX_HOME": "/Users/me/.codex"])
        XCTAssertEqual(h.settings.acpKeychainEnv(for: existing.id)["CODEX_API_KEY"], "s3cret")
        XCTAssertEqual(h.settings.workspaceDefaultID(for: workspace), existing.id)
        XCTAssertTrue(h.settings.acpAllowedAgentIDs.contains(existing.id))
    }

    func testARowTheUserPointedAtTheirOwnCommandIsNotTakenOver() async throws {
        let h = try harness()
        h.settings.addACPAgent(name: "Codex", commandLine: "/opt/mine/codex-acp --flag")
        h.settings.acpAgents[0].presetID = "codex"
        let id = h.settings.acpAgents[0].id
        _ = try await approveAndInstall(h)
        let done = await acpWaitUntil { h.manager.states["codex-acp"]?.phase == .ready(version: "2.6.0") }
        XCTAssertTrue(done)
        XCTAssertEqual(h.settings.acpAgents[0].launchMode, .custom)
        XCTAssertEqual(h.settings.acpAgents[0].command, "/opt/mine/codex-acp")
        XCTAssertFalse(h.settings.acpAllowedAgentIDs.contains(id), "installing an adapter does not consent to someone else's command")
    }

    func testAnUpdateWithoutNewConsentKeepsThePreviousVersionAndMovesNewSessions() async throws {
        let h = try harness()
        try installVersion(h, "2.5.0")
        await h.manager.load()
        await h.manager.checkForUpdates()
        guard case .updateAvailable? = h.manager.states["codex-acp"]?.phase else { return XCTFail() }
        let proposal = try await h.manager.prepareInstall("codex-acp")
        XCTAssertEqual(proposal.updatingFrom, "2.5.0")
        XCTAssertEqual(h.root.store.activeInstall("codex-acp")?.version, "2.5.0", "preparing changes nothing")
        h.manager.install(proposal, settings: h.settings)
        let done = await acpWaitUntil { h.manager.states["codex-acp"]?.phase == .ready(version: "2.6.0") }
        XCTAssertTrue(done)
        XCTAssertEqual(h.manager.states["codex-acp"]?.previousVersion, "2.5.0")
        XCTAssertEqual(Set(h.manager.states["codex-acp"]?.versions.map(\.version) ?? []), ["2.5.0", "2.6.0"])
    }

    func testTheSandboxedBuildNeverInstalls() async throws {
        let h = try harness(sandboxed: true)
        await h.manager.load()
        do { _ = try await h.manager.prepareInstall("codex-acp"); XCTFail() } catch {
            XCTAssertEqual(error as? IDEACPAdapterError, .sandboxed)
        }
        await h.manager.checkIfDue()
        XCTAssertEqual(latestRequests(h), 0)
        XCTAssertTrue(h.npm.calls.isEmpty)
        let row = IDEACPDefinition(name: "Codex", command: "codex-acp", presetID: "codex", launchMode: .auto)
        XCTAssertEqual(h.manager.availability(of: row, settings: h.settings, isLive: false), .notInstalled,
                       "no install button leads nowhere")
    }

    func testCancellingReturnsToNotInstalled() async throws {
        let h = try harness { _, npm in npm.hangsInInstall = true }
        await h.manager.load()
        _ = try await approveAndInstall(h)
        let started = await acpWaitUntil { !h.npm.installCalls.isEmpty }
        XCTAssertTrue(started)
        XCTAssertTrue(h.manager.states["codex-acp"]?.phase.isBusy ?? false)
        h.manager.cancel("codex-acp")
        let back = await acpWaitUntil { h.manager.states["codex-acp"]?.phase == .notInstalled }
        XCTAssertTrue(back, "\(String(describing: h.manager.states["codex-acp"]?.phase))")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: h.root.store.stagingDirectory("codex-acp").path), [])
        XCTAssertTrue(h.settings.acpAgents.isEmpty, "a cancelled install adds nothing")
    }

    func testAFailureIsShownAndCanBeDismissedAndRetried() async throws {
        let h = try harness(smoke: .failed("it crashed"))
        await h.manager.load()
        _ = try await approveAndInstall(h)
        let failed = await acpWaitUntil {
            if case .failed? = h.manager.states["codex-acp"].map(\.phase) { return true } else { return false }
        }
        XCTAssertTrue(failed)
        guard case .failed(let error, let keeping)? = h.manager.states["codex-acp"]?.phase else { return XCTFail() }
        XCTAssertNil(keeping)
        guard case .startupFailed = error else { return XCTFail("\(error)") }
        XCTAssertTrue(h.settings.acpAgents.isEmpty)

        // Retry runs the whole flow again from the failed state.
        let proposal = try await h.manager.prepareInstall("codex-acp")
        XCTAssertEqual(proposal.version, "2.6.0")
        h.manager.acknowledgeFailure("codex-acp")
        XCTAssertEqual(h.manager.states["codex-acp"]?.phase, .notInstalled)
    }

    func testTwoOperationsOnOneAdapterAreRefused() async throws {
        let h = try harness { _, npm in npm.hangsInInstall = true }
        await h.manager.load()
        _ = try await approveAndInstall(h)
        _ = await acpWaitUntil { !h.npm.installCalls.isEmpty }
        do { _ = try await h.manager.prepareInstall("codex-acp"); XCTFail() } catch {
            guard case .inUse? = error as? IDEACPAdapterError else { return XCTFail("\(error)") }
        }
        do { try await h.manager.remove("codex-acp"); XCTFail() } catch {
            guard case .inUse? = error as? IDEACPAdapterError else { return XCTFail("\(error)") }
        }
        h.manager.cancel("codex-acp")
        _ = await acpWaitUntil { h.manager.states["codex-acp"]?.phase == .notInstalled }
    }

    // MARK: Versions

    func testRestoringRemovingAndLeases() async throws {
        let h = try harness()
        try installVersion(h, "1.0.0")
        try installVersion(h, "2.0.0")
        try h.root.store.writeActive("codex-acp", IDEACPActiveManifest(version: "2.0.0", previous: "1.0.0", activatedAt: Date()))
        await h.manager.load()
        XCTAssertEqual(h.manager.states["codex-acp"]?.previousVersion, "1.0.0")

        try await h.manager.restorePrevious("codex-acp")
        XCTAssertEqual(h.manager.states["codex-acp"]?.activeVersion, "1.0.0")
        XCTAssertEqual(h.manager.states["codex-acp"]?.previousVersion, "2.0.0")
        XCTAssertEqual(h.root.store.activeInstall("codex-acp")?.version, "1.0.0")

        let lease = h.root.leases.acquire(adapterID: "codex-acp", version: "2.0.0")
        XCTAssertTrue(h.manager.isInUse("codex-acp", version: "2.0.0"))
        XCTAssertEqual(h.manager.runningUses("codex-acp"), 1)
        do { try await h.manager.removeVersion("codex-acp", version: "2.0.0"); XCTFail() } catch {
            guard case .inUse? = error as? IDEACPAdapterError else { return XCTFail("\(error)") }
        }
        do { try await h.manager.remove("codex-acp"); XCTFail("an adapter in use is not removed") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.root.store.versionDirectory("codex-acp", "2.0.0").path))
        lease.release()
        try await h.manager.removeVersion("codex-acp", version: "2.0.0")
        XCTAssertEqual(h.manager.states["codex-acp"]?.versions.map(\.version), ["1.0.0"])

        do { try await h.manager.restorePrevious("codex-acp"); XCTFail() } catch {
            XCTAssertEqual(error as? IDEACPAdapterError, .noPreviousVersion)
        }
        try await h.manager.remove("codex-acp")
        XCTAssertEqual(h.manager.states["codex-acp"]?.phase, .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.root.store.adapterDirectory("codex-acp").path))
    }

    // MARK: Availability and the registry

    func testAvailabilityFollowsInstallation() async throws {
        let h = try harness()
        await h.manager.load()
        let row = h.settings.materializePreset(IDEACPRegistry.preset(id: "codex")!)
        XCTAssertEqual(h.manager.availability(of: row, settings: h.settings, isLive: false), .adapterMissing)
        XCTAssertEqual(h.manager.availability(of: row, settings: h.settings, isLive: true), .connected)
        XCTAssertEqual(IDEACPAvailability.adapterMissing.title, "Adapter not installed")

        try acpWriteVersion(h.root.store, version: "2.6.0")
        try h.root.store.writeActive("codex-acp", IDEACPActiveManifest(version: "2.6.0", previous: nil, activatedAt: Date()))
        await h.manager.load()
        XCTAssertEqual(h.manager.availability(of: row, settings: h.settings, isLive: false), .installed)

        // Node is gone: the pinned path no longer exists and none is on the search path.
        h.settings.acpPathValue = "/nonexistent-umbra-bin"
        let manifest = try h.root.store.readManifest("codex-acp", "2.6.0")
        var moved = manifest
        moved.nodePath = "/nonexistent/node"
        try h.root.store.writeManifest(moved, in: h.root.store.versionDirectory("codex-acp", "2.6.0"))
        await h.manager.load()
        guard case .failed(let message) = h.manager.availability(of: row, settings: h.settings, isLive: false) else { return XCTFail() }
        XCTAssertTrue(message.contains("Node.js"))
    }

    func testNativeMLXIsIndependentOfAdapters() async throws {
        let h = try harness()
        await h.manager.load()
        // The native agent has no row, no adapter and no launch: it never consults the manager.
        XCTAssertNil(h.settings.activeACPAgent)
        let native = IDEAIModelChoice(provider: .mlx, model: "m")
        XCTAssertNil(h.settings.acpAgent(for: native))
        XCTAssertNil(native.acpAgentID)
        _ = try await approveAndInstall(h)
        _ = await acpWaitUntil { h.manager.states["codex-acp"]?.phase == .ready(version: "2.6.0") }
        XCTAssertNil(h.settings.acpAgent(for: native), "installing an adapter does not redirect native chats")
        XCTAssertNil(h.settings.activeACPAgent, "and does not make it the default agent")
    }

    // MARK: Connection test with a real process

    func testTestConnectionStartsTheManagedAdapterAndReleasesItsLease() async throws {
        let h = try harness()
        try acpInstallFakeAgent(h.root.store, version: "1.0.0", reply: "hi")
        await h.manager.load()
        let row = h.settings.materializePreset(IDEACPRegistry.preset(id: "codex")!)
        h.settings.setACPAllowed(true, agentID: row.id)

        let environment = AgentCommandEnvironment.make(javaHome: nil)
        await h.manager.testConnection(definition: row, settings: h.settings, environment: environment)
        guard case .connected(let version, let name, _)? = h.settings.acpProbes[row.id]?.phase else {
            return XCTFail("\(String(describing: h.settings.acpProbes[row.id]?.phase))")
        }
        XCTAssertEqual(version, 1)
        XCTAssertEqual(name, "Fake")
        XCTAssertFalse(h.manager.isInUse("codex-acp", version: "1.0.0"), "the process is gone, so the version is free again")
    }

    func testTestConnectionRefusesATamperedEntryFileWithoutRunningIt() async throws {
        let h = try harness()
        let manifest = try acpInstallFakeAgent(h.root.store, version: "1.0.0", reply: "hi")
        await h.manager.load()
        let entry = h.root.store.versionDirectory("codex-acp", "1.0.0").appendingPathComponent(manifest.entryRelativePath)
        try "import os; open('/tmp/umbra-should-not-exist','w').write('x')".write(to: entry, atomically: true, encoding: .utf8)
        let row = h.settings.materializePreset(IDEACPRegistry.preset(id: "codex")!)
        await h.manager.testConnection(definition: row, settings: h.settings, environment: AgentCommandEnvironment.make(javaHome: nil))
        guard case .failed(let message)? = h.settings.acpProbes[row.id]?.phase else { return XCTFail() }
        XCTAssertTrue(message.contains("changed after it was installed"), message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/umbra-should-not-exist"))
    }

    func testTestConnectionReportsAMissingAdapterWithoutSpawning() async throws {
        let h = try harness()
        await h.manager.load()
        let row = h.settings.materializePreset(IDEACPRegistry.preset(id: "claude-code")!)
        await h.manager.testConnection(definition: row, settings: h.settings, environment: ["PATH": "/usr/bin:/bin"])
        guard case .failed(let message)? = h.settings.acpProbes[row.id]?.phase else { return XCTFail() }
        XCTAssertTrue(message.contains("not installed"), message)
    }

    func testDisablingAndEnablingTracksTheState() async throws {
        let h = try harness()
        try installVersion(h, "2.5.0")
        await h.manager.load()
        h.manager.setDisabled("codex-acp", true)
        XCTAssertEqual(h.manager.states["codex-acp"]?.phase, .disabled(installed: "2.5.0"))
        h.manager.setDisabled("codex-acp", false)
        XCTAssertEqual(h.manager.states["codex-acp"]?.phase, .ready(version: "2.5.0"))
    }
}
