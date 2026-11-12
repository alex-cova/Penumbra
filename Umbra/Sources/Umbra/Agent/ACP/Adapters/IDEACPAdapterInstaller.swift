import Foundation
import SubprocessKit

// MARK: - npm seam

struct IDEACPNpmRunResult: Equatable, Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var cancelled: Bool
    var timedOut: Bool
}

/// Runs `npm`. Production uses SubprocessKit with an argument array (no shell); tests substitute
/// a runner that writes a fixture tree.
protocol IDEACPNpmRunning: Sendable {
    func run(
        npm: String, arguments: [String], workingDirectory: URL, environment: [String: String], timeout: Duration
    ) async throws -> IDEACPNpmRunResult
}

struct IDEACPSubprocessNpmRunner: IDEACPNpmRunning {
    func run(
        npm: String, arguments: [String], workingDirectory: URL, environment: [String: String], timeout: Duration
    ) async throws -> IDEACPNpmRunResult {
        var request = SubprocessRequest(executable: npm, arguments: arguments)
        request.workingDirectory = workingDirectory
        request.environment = environment
        request.standardInput = .closed
        request.output = .separateStreams
        request.stdoutCapture = .bounded(head: 16 * 1_024, tail: 48 * 1_024)
        request.stderrCapture = .bounded(head: 8 * 1_024, tail: 24 * 1_024)
        request.processGroup = true
        request.killGroupOnExit = true
        request.timeout = timeout
        request.terminationGrace = .seconds(3)
        do {
            let result = try await SubprocessRunner.run(request)
            return IDEACPNpmRunResult(
                exitCode: result.exit.status, stdout: result.stdout.text, stderr: result.stderr.text,
                cancelled: result.cancelled, timedOut: result.timedOut)
        } catch {
            throw IDEACPAdapterError.npmFailed("npm could not be started: \(error.localizedDescription)")
        }
    }
}

// MARK: - Progress

struct IDEACPInstallProgress: Equatable, Sendable {
    var step: IDEACPAdapterStep
    var detail: String
    /// Real byte counts while npm writes the tree; nil when nothing is measurable.
    var bytesDone: Int64?
    var bytesExpected: Int64?
}

// MARK: - Installer

/// Installs a catalog adapter into a staging folder, verifies it, proves it starts as an ACP
/// agent, and only then activates it. Any failure removes the staging folder and leaves the
/// previously active version as it was.
actor IDEACPAdapterInstaller {
    struct Environment: Sendable {
        var store: IDEACPAdapterStore
        var registry: IDEACPNpmRegistry
        var npm: any IDEACPNpmRunning
        /// Finds Node.js on the path the agents use.
        var locateNode: @Sendable () async -> IDEACPNodeInstallation?
        /// Starts a launch built from the staged tree, performs `initialize`, closes it.
        var smokeTest: @Sendable (IDEACPResolvedLaunch) async -> IDEACPProbe.Phase
        var freeBytes: @Sendable () -> Int64
        var hostArchitecture: String
        var npmTimeout: Duration
        var progressInterval: Duration

        init(
            store: IDEACPAdapterStore,
            registry: IDEACPNpmRegistry,
            npm: any IDEACPNpmRunning = IDEACPSubprocessNpmRunner(),
            locateNode: @escaping @Sendable () async -> IDEACPNodeInstallation?,
            smokeTest: @escaping @Sendable (IDEACPResolvedLaunch) async -> IDEACPProbe.Phase,
            freeBytes: (@Sendable () -> Int64)? = nil,
            hostArchitecture: String = IDEACPAdapterInstaller.currentArchitecture,
            npmTimeout: Duration = .seconds(20 * 60),
            progressInterval: Duration = .seconds(1)
        ) {
            self.store = store
            self.registry = registry
            self.npm = npm
            self.locateNode = locateNode
            self.smokeTest = smokeTest
            self.freeBytes = freeBytes ?? { store.freeBytes() }
            self.hostArchitecture = hostArchitecture
            self.npmTimeout = npmTimeout
            self.progressInterval = progressInterval
        }
    }

    static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x64"
        #endif
    }

    private let env: Environment
    private var busy = Set<String>()
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(environment: Environment) {
        self.env = environment
    }

    // MARK: Proposal (no download, nothing executed)

    /// Resolves a version, runs the pre-download trust checks, and describes exactly what an
    /// install would do. `version == nil` means the registry's `latest`.
    func propose(entry: IDEACPAdapterEntry, version: String? = nil, updatingFrom: String? = nil, security: Bool = false)
        async throws -> IDEACPInstallProposal
    {
        guard let source = entry.npm else { throw IDEACPAdapterError.notManaged }
        let metadata = try await env.registry.fetchVerified(source: source, version: version)
        let (document, verified) = (metadata.document, metadata.verified)
        try checkPlatform(document)
        let requirement = IDEACPNodeRuntime.requirement(engines: document.engines, fallbackMajor: source.fallbackMinimumNode)
        let node = await env.locateNode()
        var warnings = try IDEACPNodeRuntime.check(node, requirement: requirement)
        if let deprecated = document.deprecated { warnings.append("This version is deprecated: \(deprecated)") }
        let free = env.freeBytes()
        let needed = entry.approximateInstallBytes * 2
        guard free >= needed else { throw IDEACPAdapterError.diskFull(needed: needed, free: free) }
        return IDEACPInstallProposal(
            entryID: entry.id, providerName: entry.provider, packageName: source.package,
            version: verified.version, integrity: verified.integrity, signatureKeyID: verified.signatureKeyID,
            publisher: verified.publisher, repository: source.repository,
            method: "npm into a private folder. Install scripts are not run.",
            nodeDescription: node.map { "Node.js \($0.version) at \($0.node)" } ?? "Node.js not found",
            nodeVersionRequirement: requirement, approximateBytes: entry.approximateInstallBytes,
            freeBytes: free, updatingFrom: updatingFrom, isSecurityUpdate: security, warnings: warnings)
    }

    // MARK: Install

    func install(
        proposal: IDEACPInstallProposal, entry: IDEACPAdapterEntry,
        progress: @escaping @Sendable (IDEACPInstallProgress) -> Void
    ) async throws -> IDEACPInstallManifest {
        guard entry.npm != nil else { throw IDEACPAdapterError.notManaged }
        await acquire(entry.id)
        do {
            let manifest = try await perform(proposal: proposal, entry: entry, progress: progress)
            release(entry.id)
            return manifest
        } catch {
            release(entry.id)
            throw Self.normalize(error)
        }
    }

    private func perform(
        proposal: IDEACPInstallProposal, entry: IDEACPAdapterEntry,
        progress: @escaping @Sendable (IDEACPInstallProgress) -> Void
    ) async throws -> IDEACPInstallManifest {
        guard let source = entry.npm else { throw IDEACPAdapterError.notManaged }
        let store = env.store
        let id = entry.id
        func report(_ step: IDEACPAdapterStep, _ detail: String, done: Int64? = nil, expected: Int64? = nil) {
            progress(IDEACPInstallProgress(step: step, detail: detail, bytesDone: done, bytesExpected: expected))
        }

        // 1. Resolve again: what the user approved is what gets installed.
        report(.resolving, "Checking \(source.package)@\(proposal.version)")
        try Task.checkCancellation()
        let metadata = try await env.registry.fetchVerified(source: source, version: proposal.version)
        guard metadata.verified.integrity == proposal.integrity else {
            throw IDEACPAdapterError.integrity("The registry now reports a different checksum for \(proposal.version) than the one you approved.")
        }
        try checkPlatform(metadata.document)
        let requirement = IDEACPNodeRuntime.requirement(engines: metadata.document.engines, fallbackMajor: source.fallbackMinimumNode)
        guard let node = await env.locateNode() else { throw IDEACPAdapterError.nodeMissing }
        var warnings = try IDEACPNodeRuntime.check(node, requirement: requirement)
        let needed = entry.approximateInstallBytes * 2
        let free = env.freeBytes()
        guard free >= needed else { throw IDEACPAdapterError.diskFull(needed: needed, free: free) }

        // 2. Download into staging.
        // The real path (`realpath`, not `resolvingSymlinksInPath`, which turns /private/var back into
        // /var): npm resolves links internally but writes its lockfile keys relative to the prefix
        // it was given, so a prefix under `/var` (a link to `/private/var`) produces keys full of
        // `../` that no check could match.
        let held = try store.makeHeldStaging(id)
        // Held until the folder is activated or discarded, so `recover` in another Umbra process
        // leaves it alone.
        defer { held.lock.release() }
        let staging = IDEACPPaths.real(orSelf: held.url)
        let cache = store.npmDirectory.appendingPathComponent("cache", isDirectory: true)
        do {
            try Task.checkCancellation()
            try prepareNpmFiles(store: store)
            report(.downloading, "Downloading and unpacking", done: 0, expected: entry.approximateInstallBytes)
            // Detached: walking a large tree must not occupy the installer actor.
            let sizePoller = Task.detached(priority: .utility) { [interval = env.progressInterval] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    // A cancelled sleep returns too: check again, so no event is reported late.
                    if Task.isCancelled { break }
                    let size = IDEACPAdapterStore.directorySize(staging)
                    report(.downloading, "Downloading and unpacking", done: size, expected: entry.approximateInstallBytes)
                }
            }
            let environment = npmEnvironment(node: node, store: store)
            let install: IDEACPNpmRunResult
            do {
                install = try await env.npm.run(
                    npm: node.npm,
                    arguments: Self.installArguments(
                        package: source.package, version: proposal.version, staging: staging, cache: cache,
                        userConfig: Self.configFiles(in: store.npmDirectory).user,
                        globalConfig: Self.configFiles(in: store.npmDirectory).global),
                    workingDirectory: staging, environment: environment, timeout: env.npmTimeout)
            } catch {
                sizePoller.cancel()
                await sizePoller.value
                throw error
            }
            sizePoller.cancel()
            // Wait for it to stop, so a late "downloading" never follows "verifying".
            await sizePoller.value
            try Task.checkCancellation()
            if install.cancelled { throw IDEACPAdapterError.cancelled }
            if install.timedOut { throw IDEACPAdapterError.npmFailed("npm did not finish within \(env.npmTimeout.components.seconds / 60) minutes.") }
            guard install.exitCode == 0 else { throw Self.mapNpmFailure(install, free: env.freeBytes(), needed: needed) }

            // 3. Verify what npm actually wrote.
            report(.verifying, "Checking the installed files")
            let lockData: Data
            do {
                lockData = try Data(contentsOf: staging.appendingPathComponent("package-lock.json"))
            } catch {
                throw IDEACPAdapterError.corruptManifest("npm wrote no package-lock.json.")
            }
            try IDEACPTrustPolicy.verifyLockfile(
                lockData, package: source.package, version: proposal.version, integrity: proposal.integrity)
            let summary = try IDEACPTreeAudit.audit(root: staging)
            let entryURL = try IDEACPTreeAudit.entryFile(prefix: staging, package: source.package, entryPath: source.entryPath)
            try Task.checkCancellation()

            report(.verifying, "Verifying signatures and provenance with npm")
            let audit = try await env.npm.run(
                npm: node.npm, arguments: ["audit", "signatures", "--json", "--registry=https://registry.npmjs.org/",
                                           "--cache", cache.path, "--userconfig", Self.configFiles(in: store.npmDirectory).user.path,
                                           "--globalconfig", Self.configFiles(in: store.npmDirectory).global.path],
                workingDirectory: staging, environment: environment, timeout: .seconds(120))
            try Task.checkCancellation()
            if audit.cancelled { throw IDEACPAdapterError.cancelled }
            warnings += try Self.interpretAudit(audit, package: source.package)
            warnings += Self.installScriptWarnings(prefix: staging)

            guard let entryHash = IDEACPAdapterStore.sha256(of: entryURL) else {
                throw IDEACPAdapterError.unsafeTree("\(source.entryPath) (unreadable)")
            }
            let manifest = IDEACPInstallManifest(
                adapterID: id, package: source.package, version: proposal.version, integrity: proposal.integrity,
                signatureKeyID: metadata.verified.signatureKeyID, provenanceRepository: source.repository,
                publisher: metadata.verified.publisher, nodePath: node.node, nodeVersion: node.version.description,
                entryRelativePath: "node_modules/\(source.package)/\(source.entryPath)", entrySHA256: entryHash,
                installedBytes: summary.bytes,
                // Whole seconds, as stored, so the returned manifest equals the one read back.
                installedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded()), warnings: warnings)

            // 4. Prove it starts, then activate.
            report(.installing, "Starting the adapter once to check the ACP handshake")
            try store.writeManifest(manifest, in: staging)
            let probeInstall = IDEACPActiveInstall(
                adapterID: id, version: manifest.version, versionDirectory: staging,
                entryURL: staging.appendingPathComponent(manifest.entryRelativePath),
                entrySHA256: entryHash, nodePath: node.node)
            let launch = IDEACPResolvedLaunch(
                executable: node.node, args: [probeInstall.entryURL.path],
                source: .managed(adapterID: id, version: manifest.version), identity: "adapter:\(id)",
                managed: probeInstall)
            switch await env.smokeTest(launch) {
            case .connected, .authenticationRequired:
                break
            case .failed(let message):
                throw IDEACPAdapterError.startupFailed(IDEACPSecretScrubber.scrub(message))
            case .running:
                throw IDEACPAdapterError.startupFailed("The handshake did not finish.")
            }
            try Task.checkCancellation()

            report(.installing, "Activating \(manifest.version)")
            try store.activate(id, staged: staging, manifest: manifest)
            _ = store.prune(id)
            try? FileManager.default.removeItem(at: cache)
            store.appendDiagnostic(id, "Installed \(manifest.package)@\(manifest.version) (key \(manifest.signatureKeyID)). \(warnings.count) warning(s).")
            return manifest
        } catch {
            store.discardStaging(staging)
            try? FileManager.default.removeItem(at: cache)
            store.appendDiagnostic(id, "Install of \(proposal.version) failed: \(Self.normalize(error).localizedDescription)")
            throw error
        }
    }

    // MARK: Helpers

    /// npm refuses to load one file as both the user and the global config, so there are two.
    nonisolated static func configFiles(in npmDirectory: URL) -> (user: URL, global: URL) {
        (npmDirectory.appendingPathComponent("npmrc"), npmDirectory.appendingPathComponent("npmrc-global"))
    }

    nonisolated static func installArguments(
        package: String, version: String, staging: URL, cache: URL, userConfig: URL, globalConfig: URL
    ) -> [String] {
        [
            "install", "--prefix", staging.path, "\(package)@\(version)",
            "--ignore-scripts", "--no-audit", "--no-fund", "--omit=dev", "--no-update-notifier", "--no-progress",
            "--loglevel=error", "--registry=https://registry.npmjs.org/",
            "--cache", cache.path, "--userconfig", userConfig.path, "--globalconfig", globalConfig.path,
        ]
    }

    /// A clean environment: no inherited npm configuration, tokens, or `NODE_OPTIONS`. `HOME` is a
    /// private folder, so `~/.npmrc` and its registry credentials are never read.
    private func npmEnvironment(node: IDEACPNodeInstallation, store: IDEACPAdapterStore) -> [String: String] {
        let home = store.npmDirectory.appendingPathComponent("home", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return [
            "PATH": ([node.directory] + AgentCommandEnvironment.basePath).joined(separator: ":"),
            "HOME": home.path,
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": "en_US.UTF-8",
            "NO_COLOR": "1",
            "npm_config_update_notifier": "false",
            "npm_config_fund": "false",
            "npm_config_audit": "false",
            "npm_config_ignore_scripts": "true",
        ]
    }

    private func prepareNpmFiles(store: IDEACPAdapterStore) throws {
        try store.ensureLayout()
        let files = Self.configFiles(in: store.npmDirectory)
        let text = "registry=https://registry.npmjs.org/\nignore-scripts=true\naudit=false\nfund=false\nupdate-notifier=false\n"
        try store.writeAtomically(Data(text.utf8), to: files.user)
        try store.writeAtomically(Data(text.utf8), to: files.global)
    }

    private func checkPlatform(_ document: IDEACPPackageVersion) throws {
        if let os = document.os, !os.isEmpty, !os.contains("darwin"), !os.contains("!win32") {
            throw IDEACPAdapterError.unsupportedPlatform("It is built for \(os.joined(separator: ", ")), not macOS.")
        }
        if let cpu = document.cpu, !cpu.isEmpty, !cpu.contains(env.hostArchitecture) {
            throw IDEACPAdapterError.unsupportedPlatform("It is built for \(cpu.joined(separator: ", ")), not \(env.hostArchitecture).")
        }
    }

    static func mapNpmFailure(_ result: IDEACPNpmRunResult, free: Int64, needed: Int64) -> IDEACPAdapterError {
        let text = result.stderr + "\n" + result.stdout
        if text.contains("ENOSPC") || text.localizedCaseInsensitiveContains("no space left") {
            return .diskFull(needed: needed, free: free)
        }
        let networkMarkers = ["ENOTFOUND", "ECONNREFUSED", "ECONNRESET", "ETIMEDOUT", "EAI_AGAIN", "ENETUNREACH", "network"]
        if networkMarkers.contains(where: { text.contains($0) }) {
            return .offline(tail(of: text))
        }
        if text.contains("E404") { return .registry("npm could not find the package. \(tail(of: text))") }
        return .npmFailed(tail(of: text))
    }

    static func interpretAudit(_ result: IDEACPNpmRunResult, package: String) throws -> [String] {
        let data = Data(result.stdout.utf8)
        if (try? JSONSerialization.jsonObject(with: data)) == nil {
            let text = result.stderr + result.stdout
            if ["ENOTFOUND", "ECONNREFUSED", "ETIMEDOUT", "EAI_AGAIN", "network"].contains(where: { text.contains($0) }) {
                throw IDEACPAdapterError.offline("Signatures could not be checked. \(tail(of: text))")
            }
            throw IDEACPAdapterError.untrusted("npm could not verify the signatures. \(tail(of: text))")
        }
        return try IDEACPTrustPolicy.checkAuditSignatures(data, package: package)
    }

    /// Packages in the top level of `node_modules` that declare install scripts. Umbra did not run
    /// them (`--ignore-scripts`); the user is told, because an adapter might rely on one.
    static func installScriptWarnings(prefix: URL) -> [String] {
        let modules = prefix.appendingPathComponent("node_modules", isDirectory: true)
        var directories: [URL] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: modules.path)) ?? [] where !name.hasPrefix(".") {
            let url = modules.appendingPathComponent(name)
            if name.hasPrefix("@") {
                let scoped = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
                directories += scoped.map { url.appendingPathComponent($0) }
            } else {
                directories.append(url)
            }
        }
        var names: [String] = []
        for directory in directories {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("package.json")),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let scripts = object["scripts"] as? [String: Any]
            else { continue }
            if ["preinstall", "install", "postinstall"].contains(where: { scripts[$0] != nil }) {
                names.append(object["name"] as? String ?? directory.lastPathComponent)
            }
        }
        guard !names.isEmpty else { return [] }
        return ["Install scripts were not run for: \(names.sorted().prefix(5).joined(separator: ", "))."]
    }

    static func tail(of text: String) -> String {
        let scrubbed = IDEACPSecretScrubber.scrub(text)
        let lines = scrubbed.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let joined = lines.suffix(4).joined(separator: " ")
        return joined.count > 400 ? "…" + joined.suffix(400) : joined
    }

    nonisolated static func normalize(_ error: Error) -> IDEACPAdapterError {
        if let adapter = error as? IDEACPAdapterError { return adapter }
        if error is CancellationError { return .cancelled }
        let code = (error as NSError).code
        if code == Int(ENOSPC) || code == NSFileWriteOutOfSpaceError { return .diskFull(needed: 0, free: 0) }
        return .npmFailed(error.localizedDescription)
    }

    // MARK: Per-adapter serialization

    private func acquire(_ id: String) async {
        if busy.contains(id) {
            await withCheckedContinuation { waiters[id, default: []].append($0) }
        } else {
            busy.insert(id)
        }
    }

    private func release(_ id: String) {
        if var queue = waiters[id], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[id] = queue
            next.resume()
        } else {
            waiters[id] = nil
            busy.remove(id)
        }
    }
}

extension IDEACPNpmRegistry {
    struct VerifiedMetadata: Sendable {
        var document: IDEACPPackageVersion
        var verified: IDEACPVerifiedPackage
    }

    /// Fetches a version (`latest` when nil), its provenance, and applies the trust policy.
    func fetchVerified(source: IDEACPNpmSource, version: String?) async throws -> VerifiedMetadata {
        let document = if let version {
            try await self.version(package: source.package, version: version)
        } else {
            try await latest(package: source.package)
        }
        let attestations = try await self.attestations(for: document)
        let verified = try IDEACPTrustPolicy.verify(
            version: document, attestations: attestations, source: source, expectedVersion: version)
        return VerifiedMetadata(document: document, verified: verified)
    }
}
