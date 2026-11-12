import Foundation
import XCTest
@testable import Umbra

/// Real registry data captured for the tests: the version document and provenance bundle of
/// codex-acp 2.6.0 and claude-agent-acp 0.106.0. The signatures in them verify against the key
/// pinned in `IDEACPTrustPolicy`, so the trust policy is tested offline against real artifacts.
enum ACPFixtures {
    static func data(_ name: String) throws -> Data {
        let base = try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("Fixtures/ACPAdapters")
        return try Data(contentsOf: base.appendingPathComponent(name))
    }

    static func version(_ name: String) throws -> IDEACPPackageVersion {
        try JSONDecoder().decode(IDEACPPackageVersion.self, from: data("\(name).version.json"))
    }

    static func versionJSON(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data("\(name).version.json")) as? [String: Any])
    }

    static func attestations(_ name: String) throws -> Data { try data("\(name).attestations.json") }

    static let codex = "codex-acp-2.6.0"
    static let claude = "claude-agent-acp-0.106.0"
}

/// A registry that answers from memory. Records every request, so a test can assert that nothing
/// went anywhere it should not.
final class ACPFixtureFetcher: IDEACPHTTPFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: (Data, Int)] = [:]
    private var log: [String] = []
    private var failure: Error?

    var requests: [String] { lock.withLock { log } }

    func route(_ url: String, _ data: Data, status: Int = 200) {
        lock.withLock { routes[url] = (data, status) }
    }

    func fail(with error: Error?) { lock.withLock { failure = error } }

    func fetch(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        let key = (request.httpMethod == "POST" ? "POST " : "") + (request.url?.absoluteString ?? "")
        let (failure, route) = lock.withLock { () -> (Error?, (Data, Int)?) in
            log.append(key)
            return (self.failure, routes[key])
        }
        if let failure { throw failure }
        guard let route else { return (Data("{}".utf8), 404) }
        return (route.0, route.1)
    }

    /// Routes `latest`, the pinned version, the attestation, and an empty advisory answer for a
    /// package, from the captured fixtures.
    func serve(package: String, fixture: String, version: String) throws {
        let encoded = IDEACPNpmRegistry.encode(package)
        let versionData = try ACPFixtures.data("\(fixture).version.json")
        route("https://registry.npmjs.org/\(encoded)/latest", versionData)
        route("https://registry.npmjs.org/\(encoded)/\(version)", versionData)
        let document = try ACPFixtures.version(fixture)
        if let url = document.dist.attestations?.url {
            route(url, try ACPFixtures.attestations(fixture))
        }
        route("POST https://registry.npmjs.org/-/npm/v1/security/advisories/bulk", Data("{}".utf8))
    }
}

/// Stands in for `npm`: writes the tree a real install would (package.json, dist/index.js, the
/// lockfile, a few dependencies), and answers `audit signatures` from a closure. Tests change
/// the tree through `mutate` to model a malicious or broken package. It serves several packages,
/// chosen by the `name@version` argument, and counts how many installs overlap.
final class ACPFakeNpm: IDEACPNpmRunning, @unchecked Sendable {
    struct Call: Equatable { var arguments: [String]; var workingDirectory: String; var environment: [String: String] }
    struct Package: Sendable { var name: String; var version: String; var integrity: String }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var running = 0
    private var peak = 0
    private var peakPerPackage: [String: Int] = [:]
    private var runningPerPackage: [String: Int] = [:]

    let packages: [Package]
    var entryContents = "#!/usr/bin/env node\nconsole.log('fake adapter');\n"
    var mutate: (@Sendable (URL) throws -> Void)?
    var lockMutate: (@Sendable (inout [String: Any]) -> Void)?
    var installResult: IDEACPNpmRunResult?
    var auditResult = IDEACPNpmRunResult(exitCode: 0, stdout: #"{"invalid":[],"missing":[]}"#, stderr: "", cancelled: false, timedOut: false)
    /// Suspends `install` until the task is cancelled, to model a long download.
    var hangsInInstall = false
    var installDelay: Duration?

    init(packages: [Package]) { self.packages = packages }

    convenience init(package: String, version: String, integrity: String) {
        self.init(packages: [Package(name: package, version: version, integrity: integrity)])
    }

    var calls: [Call] { lock.withLock { recorded } }
    var installCalls: [Call] { calls.filter { $0.arguments.first == "install" } }
    var peakConcurrentInstalls: Int { lock.withLock { peak } }
    func peakConcurrentInstalls(of package: String) -> Int { lock.withLock { peakPerPackage[package] ?? 0 } }

    func run(
        npm: String, arguments: [String], workingDirectory: URL, environment: [String: String], timeout: Duration
    ) async throws -> IDEACPNpmRunResult {
        lock.withLock { recorded.append(Call(arguments: arguments, workingDirectory: workingDirectory.path, environment: environment)) }
        if arguments.first == "audit" { return auditResult }
        let spec = arguments.count > 3 ? arguments[3] : ""
        let package = try XCTUnwrap(packages.first { "\($0.name)@\($0.version)" == spec }, "unexpected install spec \(spec)")
        lock.withLock {
            running += 1
            peak = max(peak, running)
            runningPerPackage[package.name, default: 0] += 1
            peakPerPackage[package.name] = max(peakPerPackage[package.name] ?? 0, runningPerPackage[package.name] ?? 0)
        }
        defer {
            lock.withLock {
                running -= 1
                runningPerPackage[package.name, default: 1] -= 1
            }
        }
        if let installDelay { try? await Task.sleep(for: installDelay) }
        if hangsInInstall {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            return IDEACPNpmRunResult(exitCode: 143, stdout: "", stderr: "", cancelled: true, timedOut: false)
        }
        if let installResult { return installResult }
        let prefix = try XCTUnwrap(arguments.firstIndex(of: "--prefix").map { URL(fileURLWithPath: arguments[$0 + 1]) })
        try writeTree(prefix: prefix, package: package)
        return IDEACPNpmRunResult(exitCode: 0, stdout: "", stderr: "", cancelled: false, timedOut: false)
    }

    func writeTree(prefix: URL, package: Package) throws {
        let fileManager = FileManager.default
        let packageDirectory = prefix.appendingPathComponent("node_modules/\(package.name)")
        try fileManager.createDirectory(at: packageDirectory.appendingPathComponent("dist"), withIntermediateDirectories: true)
        try Data("""
        {"name":"\(package.name)","version":"\(package.version)","bin":{"adapter":"dist/index.js"}}
        """.utf8).write(to: packageDirectory.appendingPathComponent("package.json"))
        try entryContents.write(to: packageDirectory.appendingPathComponent("dist/index.js"), atomically: true, encoding: .utf8)
        let dependency = prefix.appendingPathComponent("node_modules/dep-one")
        try fileManager.createDirectory(at: dependency, withIntermediateDirectories: true)
        try Data(#"{"name":"dep-one","version":"1.0.0"}"#.utf8).write(to: dependency.appendingPathComponent("package.json"))
        var lock: [String: Any] = [
            "lockfileVersion": 3,
            "packages": [
                "": ["dependencies": [package.name: package.version]],
                "node_modules/\(package.name)": [
                    "version": package.version,
                    "resolved": "https://registry.npmjs.org/\(package.name)/-/adapter-\(package.version).tgz",
                    "integrity": package.integrity,
                ],
                "node_modules/dep-one": [
                    "version": "1.0.0",
                    "resolved": "https://registry.npmjs.org/dep-one/-/dep-one-1.0.0.tgz",
                    "integrity": "sha512-" + String(repeating: "A", count: 86) + "==",
                ],
            ] as [String: Any],
        ]
        lockMutate?(&lock)
        try JSONSerialization.data(withJSONObject: lock).write(to: prefix.appendingPathComponent("package-lock.json"))
        try Data(#"{"dependencies":{}}"#.utf8).write(to: prefix.appendingPathComponent("package.json"))
        try mutate?(prefix)
    }
}

/// A temporary adapter root with a store and an isolated lease registry.
struct ACPTestRoot {
    let root: URL
    let leases: IDEACPAdapterLeases
    let store: IDEACPAdapterStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-acp-adapters-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        leases = IDEACPAdapterLeases()
        store = IDEACPAdapterStore(root: root, leases: leases)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

/// A node installation that exists only on paper: the fake npm and the smoke test never run it.
func acpFakeNode(version: String = "26.12.1") -> IDEACPNodeInstallation {
    IDEACPNodeInstallation(node: "/usr/bin/true", npm: "/usr/bin/true", version: IDEACPSemver(version)!)
}

/// A manifest for a store test, with an entry file written on disk.
@discardableResult
func acpWriteVersion(
    _ store: IDEACPAdapterStore, adapter: String = "codex-acp", version: String, installedAt: Date = Date(),
    entry: String = "console.log(1)\n", writeManifest: Bool = true
) throws -> IDEACPInstallManifest {
    try store.ensureLayout(for: adapter)
    let directory = store.versionDirectory(adapter, version)
    let entryPath = "node_modules/pkg/dist/index.js"
    let entryURL = directory.appendingPathComponent(entryPath)
    try FileManager.default.createDirectory(at: entryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try entry.write(to: entryURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let manifest = IDEACPInstallManifest(
        adapterID: adapter, package: "pkg", version: version, integrity: "sha512-x", signatureKeyID: "SHA256:key",
        provenanceRepository: "https://github.com/o/r", publisher: "test", nodePath: "/usr/bin/true", nodeVersion: "26.0.0",
        entryRelativePath: entryPath, entrySHA256: IDEACPAdapterStore.sha256(of: entryURL) ?? "", installedBytes: 10,
        installedAt: installedAt, warnings: [])
    if writeManifest { try store.writeManifest(manifest, in: directory) }
    return manifest
}

/// A tiny ACP agent in Python: answers `initialize` and `session/new`, and replies to a prompt
/// with `reply`. Used as the entry script of a "managed" version so real processes can run.
func acpFakeAgentScript(reply: String) -> String {
    #"""
    import json, os, sys
    pid_path = os.environ.get("FAKE_PID_FILE")
    if pid_path:
        with open(pid_path, "w") as f: f.write(str(os.getpid()))
    def send(obj):
        sys.stdout.write(json.dumps(obj) + "\n"); sys.stdout.flush()
    for line in sys.stdin:
        if not line.strip(): continue
        msg = json.loads(line)
        method = msg.get("method")
        if method == "initialize":
            send({"jsonrpc":"2.0","id":msg["id"],"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":False},"authMethods":[],"agentInfo":{"name":"fake","title":"Fake","version":"1.0.0"}}})
        elif method == "session/new":
            send({"jsonrpc":"2.0","id":msg["id"],"result":{"sessionId":"fake-1"}})
        elif method == "session/prompt":
            send({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"fake-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\#(reply)"}}}})
            send({"jsonrpc":"2.0","id":msg["id"],"result":{"stopReason":"end_turn"}})
        elif "id" in msg:
            send({"jsonrpc":"2.0","id":msg["id"],"result":{}})
    """#
}

/// Writes a complete managed version whose entry script is a fake ACP agent run by python3,
/// and (optionally) makes it the active one.
@discardableResult
func acpInstallFakeAgent(
    _ store: IDEACPAdapterStore, adapter: String = "codex-acp", version: String, reply: String,
    installedAt: Date = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded()), activate: Bool = true
) throws -> IDEACPInstallManifest {
    try store.ensureLayout(for: adapter)
    let directory = store.versionDirectory(adapter, version)
    let entryPath = "node_modules/fake/agent.py"
    let entryURL = directory.appendingPathComponent(entryPath)
    try FileManager.default.createDirectory(at: entryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try acpFakeAgentScript(reply: reply).write(to: entryURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let manifest = IDEACPInstallManifest(
        adapterID: adapter, package: "fake", version: version, integrity: "sha512-x", signatureKeyID: "SHA256:key",
        provenanceRepository: "r", publisher: "test", nodePath: "/usr/bin/python3", nodeVersion: "3.0.0",
        entryRelativePath: entryPath, entrySHA256: IDEACPAdapterStore.sha256(of: entryURL)!, installedBytes: 1,
        installedAt: installedAt, warnings: [])
    try store.writeManifest(manifest, in: directory)
    if activate {
        let previous = try? store.readActive(adapter)
        try store.writeActive(adapter, IDEACPActiveManifest(version: version, previous: previous?.version, activatedAt: Date()))
    }
    return manifest
}

@MainActor
func acpWaitUntil(_ timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    return condition()
}
