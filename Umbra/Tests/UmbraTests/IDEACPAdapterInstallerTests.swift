import Foundation
import XCTest
@testable import Umbra

private final class SmokeSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var launched: [IDEACPResolvedLaunch] = []
    private var manifestPresent: [Bool] = []
    var phase: IDEACPProbe.Phase = .connected(protocolVersion: 1, agentName: "Fake", loadSession: false)
    var launches: [IDEACPResolvedLaunch] { lock.withLock { launched } }
    var sawManifestBeforeStart: [Bool] { lock.withLock { manifestPresent } }

    func run(_ launch: IDEACPResolvedLaunch) -> IDEACPProbe.Phase {
        let present = launch.managed.map {
            FileManager.default.fileExists(atPath: $0.versionDirectory.appendingPathComponent("install.json").path)
        } ?? false
        lock.withLock {
            launched.append(launch)
            manifestPresent.append(present)
        }
        return phase
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [IDEACPInstallProgress] = []
    func add(_ progress: IDEACPInstallProgress) { lock.withLock { events.append(progress) } }
    var all: [IDEACPInstallProgress] { lock.withLock { events } }
}

private struct Rig {
    let root: ACPTestRoot
    let fetcher: ACPFixtureFetcher
    let npm: ACPFakeNpm
    fileprivate let smoke: SmokeSpy
    let installer: IDEACPAdapterInstaller
    var store: IDEACPAdapterStore { root.store }
    static let codexVersion = "2.6.0"
    static let claudeVersion = "0.106.0"
}

private func makeRig(
    node: IDEACPNodeInstallation? = acpFakeNode(),
    freeBytes: Int64 = Int64.max,
    arch: String = "arm64",
    progressInterval: Duration = .milliseconds(20),
    configure: (ACPFixtureFetcher, ACPFakeNpm) throws -> Void = { _, _ in }
) throws -> Rig {
    let root = try ACPTestRoot()
    let fetcher = ACPFixtureFetcher()
    try fetcher.serve(package: "@agentclientprotocol/codex-acp", fixture: ACPFixtures.codex, version: Rig.codexVersion)
    try fetcher.serve(package: "@agentclientprotocol/claude-agent-acp", fixture: ACPFixtures.claude, version: Rig.claudeVersion)
    let codexDocument = try ACPFixtures.version(ACPFixtures.codex)
    let claudeDocument = try ACPFixtures.version(ACPFixtures.claude)
    let npm = ACPFakeNpm(packages: [
        .init(name: codexDocument.name, version: codexDocument.version, integrity: codexDocument.dist.integrity!),
        .init(name: claudeDocument.name, version: claudeDocument.version, integrity: claudeDocument.dist.integrity!),
    ])
    let smoke = SmokeSpy()
    try configure(fetcher, npm)
    let environment = IDEACPAdapterInstaller.Environment(
        store: root.store, registry: IDEACPNpmRegistry(fetcher: fetcher), npm: npm,
        locateNode: { node }, smokeTest: { smoke.run($0) }, freeBytes: { freeBytes }, hostArchitecture: arch,
        npmTimeout: .seconds(30), progressInterval: progressInterval)
    return Rig(root: root, fetcher: fetcher, npm: npm, smoke: smoke, installer: IDEACPAdapterInstaller(environment: environment))
}

final class IDEACPAdapterInstallerTests: XCTestCase {
    private let codex = IDEACPAdapterCatalog.codex
    private let claude = IDEACPAdapterCatalog.claude
    private var rigs: [Rig] = []

    override func tearDown() {
        rigs.forEach { $0.root.cleanUp() }
        rigs = []
    }

    private func rig(
        node: IDEACPNodeInstallation? = acpFakeNode(), freeBytes: Int64 = Int64.max,
        arch: String = "arm64", configure: (ACPFixtureFetcher, ACPFakeNpm) throws -> Void = { _, _ in }
    ) throws -> Rig {
        let made = try makeRig(node: node, freeBytes: freeBytes, arch: arch, configure: configure)
        rigs.append(made)
        return made
    }

    private func install(
        _ rig: Rig, entry: IDEACPAdapterEntry? = nil, progress: ProgressLog? = nil
    ) async throws -> IDEACPInstallManifest {
        let entry = entry ?? codex
        let proposal = try await rig.installer.propose(entry: entry)
        return try await rig.installer.install(proposal: proposal, entry: entry) { progress?.add($0) }
    }

    /// `path` with its folder's links resolved. The staging folder itself is gone once the install is
    /// done, so only its parent can be resolved.
    private func spelledWithRealParent(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        return IDEACPPaths.real(url.deletingLastPathComponent()).map { $0.appendingPathComponent(url.lastPathComponent).path }
    }

    private func assertNothingInstalled(_ rig: Rig, adapter: String = "codex-acp", file: StaticString = #filePath, line: UInt = #line) {
        let staging = (try? FileManager.default.contentsOfDirectory(atPath: rig.store.stagingDirectory(adapter).path)) ?? []
        XCTAssertEqual(staging, [], "staging was removed", file: file, line: line)
        XCTAssertNil(rig.store.activeInstall(adapter), file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.store.npmDirectory.appendingPathComponent("cache").path),
                       "the npm cache was cleared", file: file, line: line)
    }

    private func assertFails(
        _ rig: Rig, entry: IDEACPAdapterEntry? = nil, expecting: (IDEACPAdapterError) -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await install(rig, entry: entry)
            XCTFail("expected a failure", file: file, line: line)
        } catch {
            let normalized = IDEACPAdapterInstaller.normalize(error)
            XCTAssertTrue(expecting(normalized), "\(normalized)", file: file, line: line)
        }
        assertNothingInstalled(rig, adapter: (entry ?? codex).id, file: file, line: line)
        XCTAssertTrue(rig.smoke.launches.isEmpty, "nothing ran", file: file, line: line)
    }

    // MARK: Proposal

    func testAProposalDescribesTheExactInstallAndRunsNothing() async throws {
        let rig = try rig()
        let proposal = try await rig.installer.propose(entry: codex)
        XCTAssertEqual(proposal.version, "2.6.0")
        XCTAssertEqual(proposal.packageName, "@agentclientprotocol/codex-acp")
        XCTAssertEqual(proposal.providerName, "OpenAI")
        XCTAssertTrue(proposal.publisher.contains("github"))
        XCTAssertEqual(proposal.repository, "https://github.com/agentclientprotocol/codex-acp")
        XCTAssertTrue(proposal.method.contains("scripts are not run"))
        XCTAssertTrue(proposal.nodeDescription.contains("26.12.1"))
        XCTAssertEqual(proposal.signatureKeyID, "SHA256:DhQ8wR5APBvFHLF/+Tc+AYvPOdTpcIDqOhxsBHRwC7U")
        XCTAssertEqual(proposal.approximateBytes, codex.approximateInstallBytes)
        XCTAssertNil(proposal.updatingFrom)

        XCTAssertTrue(rig.npm.calls.isEmpty, "discovery never starts npm")
        XCTAssertTrue(rig.smoke.launches.isEmpty, "discovery never starts downloaded code")
        XCTAssertTrue(rig.fetcher.requests.allSatisfy { $0.contains("https://registry.npmjs.org/") }, "\(rig.fetcher.requests)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.store.adapterDirectory("codex-acp").path), "nothing was created")
    }

    func testAProposalForAnUpdateNamesWhatItReplacesAndTheSecurityFlag() async throws {
        let rig = try rig()
        let proposal = try await rig.installer.propose(entry: codex, updatingFrom: "2.5.0", security: true)
        XCTAssertEqual(proposal.updatingFrom, "2.5.0")
        XCTAssertTrue(proposal.isSecurityUpdate)
    }

    func testNativeCLIsCannotBeInstalled() async throws {
        let rig = try rig()
        do {
            _ = try await rig.installer.propose(entry: IDEACPAdapterCatalog.gemini)
            XCTFail()
        } catch { XCTAssertEqual(error as? IDEACPAdapterError, .notManaged) }
    }

    // MARK: Install

    func testTheHappyPathVerifiesStartsAndActivates() async throws {
        let rig = try rig()
        let log = ProgressLog()
        let manifest = try await install(rig, progress: log)

        XCTAssertEqual(manifest.version, "2.6.0")
        XCTAssertEqual(manifest.package, "@agentclientprotocol/codex-acp")
        XCTAssertEqual(manifest.signatureKeyID, "SHA256:DhQ8wR5APBvFHLF/+Tc+AYvPOdTpcIDqOhxsBHRwC7U")
        XCTAssertEqual(manifest.nodePath, "/usr/bin/true")
        XCTAssertEqual(manifest.nodeVersion, "26.12.1")
        XCTAssertEqual(manifest.entryRelativePath, "node_modules/@agentclientprotocol/codex-acp/dist/index.js")
        XCTAssertGreaterThan(manifest.installedBytes, 0)

        let active = try XCTUnwrap(rig.store.activeInstall("codex-acp"))
        XCTAssertEqual(active.version, "2.6.0")
        XCTAssertEqual(IDEACPAdapterStore.sha256(of: active.entryURL), manifest.entrySHA256)
        XCTAssertNoThrow(try IDEACPAdapterStore.verifyEntry(active))
        XCTAssertEqual(try rig.store.readManifest("codex-acp", "2.6.0"), manifest)

        // The adapter was started once, from the staged tree, after its manifest existed.
        XCTAssertEqual(rig.smoke.launches.count, 1)
        XCTAssertEqual(rig.smoke.sawManifestBeforeStart, [true])
        XCTAssertEqual(rig.smoke.launches[0].executable, "/usr/bin/true")
        XCTAssertTrue(rig.smoke.launches[0].args[0].contains("/staging/"))

        let steps = log.all.map(\.step)
        XCTAssertEqual(steps, steps.sorted(), "progress only moves forward")
        XCTAssertEqual(Set(steps), [.resolving, .downloading, .verifying, .installing])
        XCTAssertTrue(log.all.contains { $0.step == .downloading && $0.bytesExpected == codex.approximateInstallBytes })

        assertNothingInstalledLeftovers(rig)
        XCTAssertTrue(rig.store.readDiagnostics("codex-acp").contains("Installed @agentclientprotocol/codex-acp@2.6.0"))
    }

    private func assertNothingInstalledLeftovers(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        let staging = (try? FileManager.default.contentsOfDirectory(atPath: rig.store.stagingDirectory("codex-acp").path)) ?? []
        XCTAssertEqual(staging, [], file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.store.npmDirectory.appendingPathComponent("cache").path), file: file, line: line)
    }

    func testAnInstallUnderASymbolicLinkIsGivenNpmAsItsRealPath() async throws {
        // /var is a link to /private/var on macOS, and a user's Application Support could be one too.
        let real = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-real-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: real)
        }
        let fetcher = ACPFixtureFetcher()
        try fetcher.serve(package: "@agentclientprotocol/codex-acp", fixture: ACPFixtures.codex, version: "2.6.0")
        let document = try ACPFixtures.version(ACPFixtures.codex)
        let npm = ACPFakeNpm(package: document.name, version: document.version, integrity: document.dist.integrity!)
        // Like real npm: lockfile keys are relative to the prefix as it was spelled.
        npm.lockMutate = { lock in
            var packages = lock["packages"] as! [String: Any]
            if let top = packages["node_modules/@agentclientprotocol/codex-acp"] {
                packages.removeValue(forKey: "node_modules/@agentclientprotocol/codex-acp")
                packages["node_modules/@agentclientprotocol/codex-acp"] = top
            }
            lock["packages"] = packages
        }
        let store = IDEACPAdapterStore(root: link.appendingPathComponent("ACP"), leases: IDEACPAdapterLeases())
        let environment = IDEACPAdapterInstaller.Environment(
            store: store, registry: IDEACPNpmRegistry(fetcher: fetcher), npm: npm, locateNode: { acpFakeNode() },
            smokeTest: { _ in .connected(protocolVersion: 1, agentName: nil, loadSession: false) },
            freeBytes: { Int64.max }, hostArchitecture: "arm64", npmTimeout: .seconds(30), progressInterval: .milliseconds(20))
        let installer = IDEACPAdapterInstaller(environment: environment)
        let proposal = try await installer.propose(entry: codex)
        _ = try await installer.install(proposal: proposal, entry: codex) { _ in }
        let prefix = try XCTUnwrap(npm.installCalls.first.map { $0.arguments[$0.arguments.firstIndex(of: "--prefix")! + 1] })
        XCTAssertFalse(prefix.contains("umbra-link-"), "the link was not passed to npm: \(prefix)")
        XCTAssertEqual(prefix, spelledWithRealParent(prefix), "a true realpath, with /private spelled out")
        XCTAssertEqual(store.activeInstall("codex-acp")?.version, "2.6.0")
    }

    func testNpmIsRunWithAnArgumentArrayScriptsOffAndACleanEnvironment() async throws {
        let rig = try rig()
        _ = try await install(rig)
        let call = try XCTUnwrap(rig.npm.installCalls.first)
        let arguments = call.arguments
        XCTAssertEqual(arguments.first, "install")
        XCTAssertTrue(arguments.contains("@agentclientprotocol/codex-acp@2.6.0"), "an exact version, never a range or a tag")
        XCTAssertTrue(arguments.contains("--ignore-scripts"))
        XCTAssertTrue(arguments.contains("--no-audit"))
        XCTAssertTrue(arguments.contains("--registry=https://registry.npmjs.org/"))
        XCTAssertFalse(arguments.contains("-g"))
        XCTAssertFalse(arguments.contains("--global"))
        let prefix = arguments[arguments.firstIndex(of: "--prefix")! + 1]
        XCTAssertTrue(
            prefix.hasPrefix(IDEACPPaths.real(orSelf: rig.store.stagingDirectory("codex-acp")).path),
            "installs into staging, not into place")
        XCTAssertEqual(prefix, spelledWithRealParent(prefix), "npm is given a path with no symbolic link in it")
        let npmrc = rig.store.npmDirectory.appendingPathComponent("npmrc").path
        let globalrc = rig.store.npmDirectory.appendingPathComponent("npmrc-global").path
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--userconfig")! + 1], npmrc)
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--globalconfig")! + 1], globalrc)
        XCTAssertNotEqual(npmrc, globalrc, "real npm exits when one file is loaded as both the user and the global config")
        XCTAssertEqual(try String(contentsOfFile: globalrc, encoding: .utf8), try String(contentsOfFile: npmrc, encoding: .utf8))
        XCTAssertTrue(arguments[arguments.firstIndex(of: "--cache")! + 1].hasPrefix(rig.store.npmDirectory.path))
        XCTAssertFalse(arguments.contains { $0.contains(";") || $0.contains("|") || $0.contains("$(") }, "no shell syntax")

        let environment = call.environment
        XCTAssertNil(environment["NODE_OPTIONS"])
        XCTAssertNil(environment["NPM_TOKEN"])
        XCTAssertNil(environment["npm_config_registry"])
        XCTAssertEqual(environment["npm_config_ignore_scripts"], "true")
        XCTAssertTrue(environment["PATH"]!.hasPrefix("/usr/bin:"), "the node directory leads the path")
        XCTAssertTrue(environment["HOME"]!.hasPrefix(rig.store.npmDirectory.path), "the user's ~/.npmrc is never read")
        let rc = try String(contentsOfFile: npmrc, encoding: .utf8)
        XCTAssertTrue(rc.contains("ignore-scripts=true"))

        let audit = try XCTUnwrap(rig.npm.calls.first { $0.arguments.first == "audit" })
        XCTAssertEqual(Array(audit.arguments.prefix(3)), ["audit", "signatures", "--json"])
    }

    func testInstallScriptsThatWereSkippedAndUnsignedDependenciesAreSurfaced() async throws {
        let rig = try rig { _, npm in
            npm.mutate = { prefix in
                let dependency = prefix.appendingPathComponent("node_modules/native-dep")
                try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: true)
                try Data(#"{"name":"native-dep","scripts":{"postinstall":"node-gyp rebuild"}}"#.utf8)
                    .write(to: dependency.appendingPathComponent("package.json"))
            }
            npm.auditResult = IDEACPNpmRunResult(
                exitCode: 1, stdout: #"{"invalid":[],"missing":[{"name":"dep-one","version":"1.0.0"}]}"#, stderr: "", cancelled: false, timedOut: false)
        }
        let manifest = try await install(rig)
        XCTAssertTrue(manifest.warnings.contains { $0.contains("Install scripts were not run for: native-dep") }, "\(manifest.warnings)")
        XCTAssertTrue(manifest.warnings.contains { $0.contains("dep-one") && $0.contains("no registry signature") }, "\(manifest.warnings)")
    }

    func testAnAuthenticationPromptDuringTheHandshakeStillCountsAsStarted() async throws {
        let rig = try rig()
        rig.smoke.phase = .authenticationRequired("Sign in")
        _ = try await install(rig)
        XCTAssertNotNil(rig.store.activeInstall("codex-acp"))
    }

    func testClaudeInstallsToo() async throws {
        let rig = try rig()
        let manifest = try await install(rig, entry: claude)
        XCTAssertEqual(manifest.version, "0.106.0")
        XCTAssertEqual(rig.store.activeInstall("claude-agent-acp")?.version, "0.106.0")
        XCTAssertNil(rig.store.activeInstall("codex-acp"))
    }

    // MARK: Trust before download

    func testATamperedChecksumIsRefusedBeforeAnythingIsDownloadedOrRun() async throws {
        let rig = try rig { fetcher, _ in
            var json = try ACPFixtures.versionJSON(ACPFixtures.codex)
            var dist = json["dist"] as! [String: Any]
            dist["integrity"] = "sha512-" + Data(repeating: 9, count: 64).base64EncodedString()
            json["dist"] = dist
            let data = try JSONSerialization.data(withJSONObject: json)
            fetcher.route("https://registry.npmjs.org/@agentclientprotocol%2fcodex-acp/latest", data)
            fetcher.route("https://registry.npmjs.org/@agentclientprotocol%2fcodex-acp/2.6.0", data)
        }
        await assertFails(rig) { if case .untrusted = $0 { return true } else { return false } }
        XCTAssertTrue(rig.npm.calls.isEmpty, "nothing was downloaded")
    }

    func testAMissingProvenanceBundleIsRefused() async throws {
        let rig = try rig { fetcher, _ in
            let url = try XCTUnwrap(ACPFixtures.version(ACPFixtures.codex).dist.attestations?.url)
            fetcher.route(url, Data("{}".utf8), status: 404)
        }
        await assertFails(rig) { if case .registry = $0 { return true } else { return false } }
        XCTAssertTrue(rig.npm.calls.isEmpty)
    }

    func testTheRegistryChangingItsMindAfterApprovalIsRefused() async throws {
        let rig = try rig()
        var proposal = try await rig.installer.propose(entry: codex)
        proposal.integrity = "sha512-" + Data(repeating: 1, count: 64).base64EncodedString()
        do {
            _ = try await rig.installer.install(proposal: proposal, entry: codex) { _ in }
            XCTFail()
        } catch {
            guard case .integrity? = error as? IDEACPAdapterError else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(rig.npm.calls.isEmpty)
        assertNothingInstalled(rig)
    }

    // MARK: Environment failures

    func testOfflineAndRegistryErrors() async throws {
        let offline = try rig { fetcher, _ in fetcher.fail(with: URLError(.notConnectedToInternet)) }
        do {
            _ = try await offline.installer.propose(entry: codex)
            XCTFail()
        } catch { guard case .offline? = error as? IDEACPAdapterError else { return XCTFail("\(error)") } }

        let broken = try rig { fetcher, _ in
            fetcher.route("https://registry.npmjs.org/@agentclientprotocol%2fcodex-acp/latest", Data("{}".utf8), status: 503)
        }
        do {
            _ = try await broken.installer.propose(entry: codex)
            XCTFail()
        } catch { guard case .registry(let detail)? = error as? IDEACPAdapterError else { return XCTFail("\(error)") }; XCTAssertTrue(detail.contains("503")) }

        let garbage = try rig { fetcher, _ in
            fetcher.route("https://registry.npmjs.org/@agentclientprotocol%2fcodex-acp/latest", Data("<html>".utf8))
        }
        do {
            _ = try await garbage.installer.propose(entry: codex)
            XCTFail()
        } catch { guard case .registry? = error as? IDEACPAdapterError else { return XCTFail("\(error)") } }
    }

    func testNodeMissingTooOldAndUnsupportedPlatform() async throws {
        let none = try rig(node: nil)
        do { _ = try await none.installer.propose(entry: codex); XCTFail() } catch {
            XCTAssertEqual(error as? IDEACPAdapterError, .nodeMissing)
        }
        let old = try rig(node: acpFakeNode(version: "20.1.0"))
        do { _ = try await old.installer.propose(entry: claude); XCTFail() } catch {
            XCTAssertEqual(error as? IDEACPAdapterError, .nodeTooOld(found: "20.1.0", required: "Node.js >=22"))
        }
        let intel = try rig(arch: "x64") { fetcher, _ in
            var json = try ACPFixtures.versionJSON(ACPFixtures.codex)
            json["cpu"] = ["arm64"]
            let data = try JSONSerialization.data(withJSONObject: json)
            fetcher.route("https://registry.npmjs.org/@agentclientprotocol%2fcodex-acp/latest", data)
        }
        do { _ = try await intel.installer.propose(entry: codex); XCTFail() } catch {
            guard case .unsupportedPlatform? = error as? IDEACPAdapterError else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(none.npm.calls.isEmpty && old.npm.calls.isEmpty && intel.npm.calls.isEmpty)
    }

    func testNotEnoughDiskIsRefusedUpFrontAndWhenNpmRunsOut() async throws {
        let small = try rig(freeBytes: 1_000)
        do { _ = try await small.installer.propose(entry: codex); XCTFail() } catch {
            XCTAssertEqual(error as? IDEACPAdapterError, .diskFull(needed: codex.approximateInstallBytes * 2, free: 1_000))
        }
        XCTAssertTrue(small.npm.calls.isEmpty)

        let fills = try rig { _, npm in
            npm.installResult = IDEACPNpmRunResult(
                exitCode: 1, stdout: "", stderr: "npm ERR! code ENOSPC\nnpm ERR! ENOSPC: no space left on device, write", cancelled: false, timedOut: false)
        }
        await assertFails(fills) { if case .diskFull = $0 { return true } else { return false } }
    }

    func testNpmFailuresMapToActionableErrorsAndAreScrubbed() async throws {
        let cases: [(String, (IDEACPAdapterError) -> Bool)] = [
            ("npm ERR! code ENOTFOUND\nnpm ERR! network request failed", { if case .offline = $0 { return true } else { return false } }),
            ("npm ERR! code E404\nnpm ERR! 404 Not Found", { if case .registry = $0 { return true } else { return false } }),
            ("npm ERR! something odd token=sk-abcdefghijklmnop", {
                if case .npmFailed(let tail) = $0 { return !tail.contains("sk-abcdefghijklmnop") && tail.contains("[redacted]") }
                return false
            }),
        ]
        for (stderr, matches) in cases {
            let rig = try rig { _, npm in
                npm.installResult = IDEACPNpmRunResult(exitCode: 1, stdout: "", stderr: stderr, cancelled: false, timedOut: false)
            }
            await assertFails(rig, expecting: matches)
        }
        let timedOut = try rig { _, npm in
            npm.installResult = IDEACPNpmRunResult(exitCode: 143, stdout: "", stderr: "", cancelled: false, timedOut: true)
        }
        await assertFails(timedOut) { if case .npmFailed(let text) = $0 { return text.contains("did not finish") } else { return false } }
    }

    // MARK: Malicious or broken packages

    func testUnsafePackageTreesAreDiscardedWithoutRunningAnything() async throws {
        let breaks: [(String, @Sendable (URL) throws -> Void)] = [
            ("symlink out of the prefix", { prefix in
                try FileManager.default.createSymbolicLink(atPath: prefix.appendingPathComponent("node_modules/evil").path, withDestinationPath: "/etc")
            }),
            ("relative symlink that climbs out", { prefix in
                try FileManager.default.createSymbolicLink(
                    atPath: prefix.appendingPathComponent("node_modules/dep-one/up").path, withDestinationPath: "../../../../../../../etc/passwd")
            }),
            ("entry replaced by a link to a system binary", { prefix in
                let entry = prefix.appendingPathComponent("node_modules/@agentclientprotocol/codex-acp/dist/index.js")
                try FileManager.default.removeItem(at: entry)
                try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
            }),
            ("set-uid file", { prefix in
                let file = prefix.appendingPathComponent("node_modules/dep-one/helper")
                try Data("x".utf8).write(to: file)
                XCTAssertEqual(chmod(file.path, 0o4755), 0)
            }),
            ("world-writable file", { prefix in
                let file = prefix.appendingPathComponent("node_modules/dep-one/open")
                try Data("x".utf8).write(to: file)
                XCTAssertEqual(chmod(file.path, 0o666), 0)
            }),
            ("named pipe", { prefix in
                XCTAssertEqual(mkfifo(prefix.appendingPathComponent("node_modules/dep-one/pipe").path, 0o600), 0)
            }),
            ("missing entry script", { prefix in
                try FileManager.default.removeItem(at: prefix.appendingPathComponent("node_modules/@agentclientprotocol/codex-acp/dist/index.js"))
            }),
        ]
        for (name, mutate) in breaks {
            let rig = try rig { _, npm in npm.mutate = mutate }
            await assertFails(rig, expecting: { if case .unsafeTree = $0 { return true } else { return false } })
            XCTAssertNotNil(name)
        }
    }

    func testALockfileThatWasNotResolvedFromTheRegistryIsRefused() async throws {
        let gitDependency = try rig { _, npm in
            npm.lockMutate = { lock in
                var packages = lock["packages"] as! [String: Any]
                packages["node_modules/evil"] = ["version": "1.0.0", "integrity": "sha512-x", "resolved": "git+ssh://git@github.com/evil/evil.git#abc"]
                lock["packages"] = packages
            }
        }
        await assertFails(gitDependency) { if case .untrusted = $0 { return true } else { return false } }

        let swapped = try rig { _, npm in
            npm.lockMutate = { lock in
                var packages = lock["packages"] as! [String: Any]
                var top = packages["node_modules/@agentclientprotocol/codex-acp"] as! [String: Any]
                top["integrity"] = "sha512-" + Data(repeating: 3, count: 64).base64EncodedString()
                packages["node_modules/@agentclientprotocol/codex-acp"] = top
                lock["packages"] = packages
            }
        }
        await assertFails(swapped) { if case .integrity = $0 { return true } else { return false } }
    }

    func testFailedSignatureAuditsAreRefused() async throws {
        let invalid = try rig { _, npm in
            npm.auditResult = IDEACPNpmRunResult(
                exitCode: 1, stdout: #"{"invalid":[{"name":"dep-one","version":"1.0.0"}],"missing":[]}"#, stderr: "", cancelled: false, timedOut: false)
        }
        await assertFails(invalid) { if case .untrusted(let reason) = $0 { return reason.contains("dep-one") } else { return false } }

        let unreadable = try rig { _, npm in
            npm.auditResult = IDEACPNpmRunResult(exitCode: 1, stdout: "oops", stderr: "", cancelled: false, timedOut: false)
        }
        await assertFails(unreadable) { if case .untrusted = $0 { return true } else { return false } }

        let offlineAudit = try rig { _, npm in
            npm.auditResult = IDEACPNpmRunResult(exitCode: 1, stdout: "", stderr: "npm ERR! code ENOTFOUND", cancelled: false, timedOut: false)
        }
        await assertFails(offlineAudit) { if case .offline = $0 { return true } else { return false } }

        let missingTop = try rig { _, npm in
            npm.auditResult = IDEACPNpmRunResult(
                exitCode: 1, stdout: #"{"invalid":[],"missing":[{"name":"@agentclientprotocol/codex-acp","version":"2.6.0"}]}"#, stderr: "", cancelled: false, timedOut: false)
        }
        await assertFails(missingTop) { if case .untrusted = $0 { return true } else { return false } }
    }

    func testAnAdapterThatDoesNotStartIsNotActivated() async throws {
        let rig = try rig()
        rig.smoke.phase = .failed("Error: Cannot find module 'x' token=sk-abcdefghijklmnop")
        do {
            _ = try await install(rig)
            XCTFail()
        } catch {
            guard case .startupFailed(let detail)? = error as? IDEACPAdapterError else { return XCTFail("\(error)") }
            XCTAssertFalse(detail.contains("sk-abcdefghijklmnop"))
            XCTAssertFalse(((error as? LocalizedError)?.errorDescription ?? "").contains("sk-abcdefghijklmnop"))
        }
        assertNothingInstalled(rig)
        XCTAssertEqual(rig.smoke.launches.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.store.versionDirectory("codex-acp", "2.6.0").path),
                       "an unverified version never reaches versions/")
    }

    // MARK: Cancellation and rollback

    func testCancellingMidDownloadRemovesStagingAndKeepsThePreviousVersion() async throws {
        let rig = try rig { _, npm in npm.hangsInInstall = true }
        try acpWriteVersion(rig.store, version: "2.5.0")
        try rig.store.writeActive("codex-acp", IDEACPActiveManifest(version: "2.5.0", previous: nil, activatedAt: Date()))
        let proposal = try await rig.installer.propose(entry: codex, updatingFrom: "2.5.0")
        let installer = rig.installer
        let codex = self.codex
        let task = Task { try await installer.install(proposal: proposal, entry: codex) { _ in } }
        let deadline = Date().addingTimeInterval(10)
        while rig.npm.installCalls.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(rig.npm.installCalls.count, 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail()
        } catch { XCTAssertEqual(IDEACPAdapterInstaller.normalize(error), .cancelled) }

        let staging = (try? FileManager.default.contentsOfDirectory(atPath: rig.store.stagingDirectory("codex-acp").path)) ?? []
        XCTAssertEqual(staging, [])
        XCTAssertEqual(rig.store.activeInstall("codex-acp")?.version, "2.5.0", "the working version is untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.store.versionDirectory("codex-acp", "2.6.0").path))
        XCTAssertTrue(rig.smoke.launches.isEmpty)
    }

    func testAFailedUpdateRollsBackToTheWorkingVersion() async throws {
        let rig = try rig()
        try acpWriteVersion(rig.store, version: "2.5.0")
        try rig.store.writeActive("codex-acp", IDEACPActiveManifest(version: "2.5.0", previous: nil, activatedAt: Date()))
        rig.smoke.phase = .failed("crashed on start")
        do { _ = try await install(rig); XCTFail() } catch {}
        XCTAssertEqual(rig.store.activeInstall("codex-acp")?.version, "2.5.0")
        XCTAssertEqual(rig.store.installedVersions("codex-acp").map(\.version), ["2.5.0"])
        XCTAssertTrue(rig.store.readDiagnostics("codex-acp").contains("failed"))
    }

    func testASuccessfulUpdateKeepsThePreviousVersionForRollback() async throws {
        let rig = try rig()
        try acpWriteVersion(rig.store, version: "2.5.0")
        try rig.store.writeActive("codex-acp", IDEACPActiveManifest(version: "2.5.0", previous: nil, activatedAt: Date()))
        _ = try await install(rig)
        let active = try XCTUnwrap(try rig.store.readActive("codex-acp"))
        XCTAssertEqual(active.version, "2.6.0")
        XCTAssertEqual(active.previous, "2.5.0")
        XCTAssertEqual(Set(rig.store.installedVersions("codex-acp").map(\.version)), ["2.5.0", "2.6.0"])
        let restored = try rig.store.restore("codex-acp", version: "2.5.0")
        XCTAssertEqual(restored.version, "2.5.0")
    }

    // MARK: Concurrency and leases

    func testInstallsOfOneAdapterAreSerializedAndDifferentAdaptersRunTogether() async throws {
        let rig = try rig { _, npm in npm.installDelay = .milliseconds(200) }
        let installer = rig.installer
        let codex = self.codex
        let claude = self.claude
        let codexProposal = try await installer.propose(entry: codex)
        let claudeProposal = try await installer.propose(entry: claude)

        async let first = installer.install(proposal: codexProposal, entry: codex) { _ in }
        async let second = installer.install(proposal: codexProposal, entry: codex) { _ in }
        async let third = installer.install(proposal: claudeProposal, entry: claude) { _ in }
        _ = try await (first, second, third)

        XCTAssertEqual(rig.npm.peakConcurrentInstalls(of: "@agentclientprotocol/codex-acp"), 1, "one adapter never installs twice at once")
        XCTAssertEqual(rig.npm.peakConcurrentInstalls, 2, "codex and claude overlapped")
        XCTAssertEqual(rig.npm.installCalls.count, 3)
        XCTAssertEqual(rig.store.activeInstall("codex-acp")?.version, "2.6.0")
        XCTAssertEqual(rig.store.activeInstall("claude-agent-acp")?.version, "0.106.0")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: rig.store.stagingDirectory("codex-acp").path)) ?? []
        XCTAssertEqual(leftovers, [])
    }

    func testAnUpdateNeverTouchesAVersionARunningChatIsUsing() async throws {
        let rig = try rig()
        try acpWriteVersion(rig.store, version: "2.3.0", installedAt: Date(timeIntervalSinceNow: -200))
        try acpWriteVersion(rig.store, version: "2.5.0", installedAt: Date(timeIntervalSinceNow: -100))
        try rig.store.writeActive("codex-acp", IDEACPActiveManifest(version: "2.5.0", previous: "2.3.0", activatedAt: Date()))
        let runningOnOld = rig.root.leases.acquire(adapterID: "codex-acp", version: "2.3.0")
        let runningOnActive = rig.root.leases.acquire(adapterID: "codex-acp", version: "2.5.0")

        _ = try await install(rig)

        XCTAssertEqual(rig.store.activeInstall("codex-acp")?.version, "2.6.0", "new sessions use the new version")
        for version in ["2.3.0", "2.5.0"] {
            let entry = rig.store.versionDirectory("codex-acp", version).appendingPathComponent("node_modules/pkg/dist/index.js")
            XCTAssertTrue(FileManager.default.fileExists(atPath: entry.path), "\(version) is still there for its running chat")
            XCTAssertNoThrow(try IDEACPAdapterStore.verifyEntry(try XCTUnwrap(rig.store.install(from: rig.store.readManifest("codex-acp", version)) as IDEACPActiveInstall?)))
        }
        XCTAssertThrowsError(try rig.store.removeVersion("codex-acp", version: "2.5.0"))
        runningOnOld.release()
        runningOnActive.release()
        XCTAssertEqual(Set(rig.store.prune("codex-acp")), ["2.3.0"], "once nothing runs on it, the old version can go")
    }

    func testReinstallingARunningVersionFailsCleanlyAndLeavesItWorking() async throws {
        let rig = try rig()
        _ = try await install(rig)
        let lease = rig.root.leases.acquire(adapterID: "codex-acp", version: "2.6.0")
        do { _ = try await install(rig); XCTFail() } catch {
            guard case .inUse? = error as? IDEACPAdapterError else { return XCTFail("\(error)") }
        }
        let active = try XCTUnwrap(rig.store.activeInstall("codex-acp"))
        XCTAssertNoThrow(try IDEACPAdapterStore.verifyEntry(active))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: rig.store.stagingDirectory("codex-acp").path)) ?? []
        XCTAssertEqual(leftovers, [])
        lease.release()
    }
}
