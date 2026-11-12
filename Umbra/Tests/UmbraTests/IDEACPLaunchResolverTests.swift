import Foundation
import XCTest
@testable import Umbra

final class IDEACPLaunchResolverTests: XCTestCase {
    private let codex = IDEACPAdapterCatalog.codex
    private func row(_ entry: IDEACPAdapterEntry, mode: IDEACPDefinition.LaunchMode = .auto, command: String? = nil, args: [String] = []) -> IDEACPDefinition {
        IDEACPDefinition(name: entry.name, command: command ?? entry.systemCommand ?? entry.id, args: args, presetID: entry.presetID, launchMode: mode)
    }
    private func active(_ version: String, node: String = "/pinned/node") -> IDEACPActiveInstall {
        IDEACPActiveInstall(
            adapterID: "codex-acp", version: version, versionDirectory: URL(fileURLWithPath: "/acp/codex-acp/versions/\(version)"),
            entryURL: URL(fileURLWithPath: "/acp/codex-acp/versions/\(version)/node_modules/pkg/dist/index.js"),
            entrySHA256: "abc", nodePath: node)
    }
    private func resolve(
        _ definition: IDEACPDefinition, active: IDEACPActiveInstall? = nil, present: Set<String> = [],
        packageName: String? = nil
    ) -> IDEACPLaunchResolver.Resolution {
        IDEACPLaunchResolver.resolve(
            definition: definition, entry: definition.adapterEntry, active: active, pathValue: "/bin:/usr/local/bin",
            isExecutable: { present.contains($0) }, systemPackageName: { _ in packageName })
    }

    func testAManagedAdapterRunsUnderThePinnedNodeWithTheEntryScript() throws {
        let launch = try XCTUnwrap(resolve(row(codex), active: active("2.6.0"), present: ["/pinned/node"]).launch)
        XCTAssertEqual(launch.executable, "/pinned/node")
        XCTAssertEqual(launch.args, ["/acp/codex-acp/versions/2.6.0/node_modules/pkg/dist/index.js"])
        XCTAssertEqual(launch.source, .managed(adapterID: "codex-acp", version: "2.6.0"))
        XCTAssertEqual(launch.version, "2.6.0")
        XCTAssertEqual(launch.managed?.entrySHA256, "abc")
        XCTAssertFalse(launch.commandLine.contains("npx"))
    }

    func testTheIdentityDoesNotChangeWhenAManagedVersionIsActivated() throws {
        let old = try XCTUnwrap(resolve(row(codex), active: active("2.5.0"), present: ["/pinned/node"]).launch)
        let new = try XCTUnwrap(resolve(row(codex), active: active("2.6.0"), present: ["/pinned/node"]).launch)
        XCTAssertNotEqual(old.args, new.args)
        XCTAssertEqual(old.identity, new.identity, "an update must not reset the chats that follow this adapter")
        XCTAssertEqual(old.identity, "adapter:codex-acp")
    }

    func testNodeFallsBackToThePathWhenThePinnedOneIsGone() throws {
        let launch = try XCTUnwrap(resolve(row(codex), active: active("2.6.0"), present: ["/usr/local/bin/node"]).launch)
        XCTAssertEqual(launch.executable, "/usr/local/bin/node")
        XCTAssertEqual(resolve(row(codex), active: active("2.6.0"), present: []), .unavailable(.nodeMissing))
    }

    func testPriorityIsCustomThenManagedThenVerifiedSystemThenNativeCLI() throws {
        let present: Set<String> = ["/pinned/node", "/bin/codex-acp", "/bin/custom-acp"]
        // 1. an explicit custom executable beats a managed install
        let custom = row(codex, mode: .custom, command: "custom-acp", args: ["--x"])
        let customLaunch = try XCTUnwrap(resolve(custom, active: active("2.6.0"), present: present).launch)
        XCTAssertEqual(customLaunch.source, .custom)
        XCTAssertEqual(customLaunch.executable, "/bin/custom-acp")
        XCTAssertEqual(customLaunch.args, ["--x"])
        // 2. managed beats a system copy
        let managed = try XCTUnwrap(resolve(row(codex), active: active("2.6.0"), present: present, packageName: "@agentclientprotocol/codex-acp").launch)
        XCTAssertEqual(managed.version, "2.6.0")
        // 3. a verified system copy when nothing is managed
        let system = try XCTUnwrap(resolve(row(codex), present: present, packageName: "@agentclientprotocol/codex-acp").launch)
        XCTAssertEqual(system.source, .systemAdapter)
        XCTAssertEqual(system.executable, "/bin/codex-acp")
        XCTAssertEqual(system.identity, "adapter:codex-acp")
        // 4. native CLIs run their own ACP mode
        let gemini = try XCTUnwrap(resolve(row(IDEACPAdapterCatalog.gemini), present: ["/bin/gemini"]).launch)
        XCTAssertEqual(gemini.source, .nativeCLI)
        XCTAssertEqual(gemini.args, ["--acp"])
    }

    func testAnUnverifiedSystemBinaryIsNotUsed() {
        let present: Set<String> = ["/bin/codex-acp"]
        XCTAssertEqual(resolve(row(codex), present: present, packageName: "something-else"), .unavailable(.notInstalled("Codex")))
        XCTAssertEqual(resolve(row(codex), present: present, packageName: nil), .unavailable(.notInstalled("Codex")))
    }

    func testAProviderCLIIsNeverTreatedAsAnACPAdapter() {
        // `codex` and `claude` are the agents' own CLIs. They do not speak ACP.
        let present: Set<String> = ["/bin/codex", "/bin/claude", "/bin/npx", "/bin/node"]
        XCTAssertEqual(resolve(row(codex), present: present), .unavailable(.notInstalled("Codex")))
        XCTAssertEqual(resolve(row(IDEACPAdapterCatalog.claude), present: present), .unavailable(.notInstalled("Claude Code")))
    }

    func testNpxIsNeverProducedEvenWhenItIsTheOnlyThingOnThePath() {
        for entry in IDEACPAdapterCatalog.entries {
            let result = resolve(row(entry), present: ["/bin/npx", "/usr/local/bin/npx"])
            XCTAssertNil(result.launch, entry.id)
        }
    }

    func testNativeCLIsReportAMissingCommand() {
        XCTAssertEqual(resolve(row(IDEACPAdapterCatalog.opencode), present: []), .unavailable(.cliMissing("opencode")))
        XCTAssertTrue(IDEACPLaunchUnavailable.cliMissing("opencode").message.contains("opencode"))
        XCTAssertTrue(IDEACPLaunchUnavailable.notInstalled("Codex").message.contains("Settings"))
    }

    func testACustomRowWithoutACatalogEntryRunsExactlyAsTyped() throws {
        let definition = IDEACPDefinition(name: "Mine", command: "mine", args: ["--acp"])
        let launch = try XCTUnwrap(resolve(definition, present: ["/bin/mine"]).launch)
        XCTAssertEqual(launch.executable, "/bin/mine")
        XCTAssertEqual(launch.args, ["--acp"])
        XCTAssertEqual(launch.identity, "custom:mine --acp")
        XCTAssertEqual(resolve(definition, present: []), .unavailable(.customMissing(definition.missingExecutableMessage)))
    }

    func testPackageNameIsReadFromTheLinkedPackageJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-pkgname-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let packageDirectory = dir.appendingPathComponent("lib/node_modules/@agentclientprotocol/codex-acp/dist")
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        try Data(#"{"name":"@agentclientprotocol/codex-acp"}"#.utf8)
            .write(to: dir.appendingPathComponent("lib/node_modules/@agentclientprotocol/codex-acp/package.json"))
        try "x".write(to: packageDirectory.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        let bin = dir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("codex-acp"), withDestinationURL: packageDirectory.appendingPathComponent("index.js"))
        XCTAssertEqual(IDEACPLaunchResolver.packageName(ofExecutable: bin.appendingPathComponent("codex-acp").path), "@agentclientprotocol/codex-acp")
        XCTAssertNil(IDEACPLaunchResolver.packageName(ofExecutable: "/nonexistent/codex-acp"))
    }

    // MARK: Definitions

    func testRowsSavedBeforeLaunchModesMigrateToTheCatalogOrStayCustom() throws {
        func decode(_ json: String) throws -> IDEACPDefinition {
            try JSONDecoder().decode(IDEACPDefinition.self, from: Data(json.utf8))
        }
        let id = UUID().uuidString
        let npxRow = try decode(#"{"id":"\#(id)","name":"Codex","command":"npx","args":["-y","@agentclientprotocol/codex-acp"],"presetID":"codex"}"#)
        XCTAssertEqual(npxRow.launchMode, .auto, "an old npx preset row now follows the catalog and never runs npx")
        let adapterRow = try decode(#"{"id":"\#(id)","name":"Codex","command":"codex-acp","presetID":"codex"}"#)
        XCTAssertEqual(adapterRow.launchMode, .auto)
        let pathRow = try decode(#"{"id":"\#(id)","name":"Codex","command":"/tmp/x/codex-acp","presetID":"codex"}"#)
        XCTAssertEqual(pathRow.launchMode, .custom, "a command the user typed stays theirs")
        let typedRow = try decode(#"{"id":"\#(id)","name":"Mine","command":"npx","args":["-y","thing"]}"#)
        XCTAssertEqual(typedRow.launchMode, .custom, "a row that is not a preset is never rewritten")
        let explicit = try decode(#"{"id":"\#(id)","name":"Codex","command":"codex-acp","presetID":"codex","launchMode":"custom"}"#)
        XCTAssertEqual(explicit.launchMode, .custom)

        let encoded = try JSONEncoder().encode(npxRow)
        XCTAssertEqual(try JSONDecoder().decode(IDEACPDefinition.self, from: encoded).launchMode, .auto)
        XCTAssertNil(npxRow.adapterEntry.flatMap { _ in nil as String? })
        XCTAssertEqual(npxRow.adapterEntry?.id, "codex-acp")
        XCTAssertNil(pathRow.adapterEntry)
    }

    @MainActor
    func testEditingACatalogRowOnlyMakesItCustomWhenTheCommandChanges() {
        let settings = IDEAgentSettings(defaults: UserDefaults(suiteName: "umbra.acp.res.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        let row = settings.materializePreset(IDEACPRegistry.preset(id: "codex")!)
        XCTAssertEqual(row.launchMode, .auto)
        XCTAssertTrue(settings.updateACPAgent(id: row.id, name: "My Codex", commandLine: "codex-acp"))
        XCTAssertEqual(settings.acpAgents[0].launchMode, .auto, "a rename keeps Umbra's choice")
        XCTAssertEqual(settings.acpAgents[0].name, "My Codex")
        XCTAssertTrue(settings.updateACPAgent(id: row.id, name: "My Codex", commandLine: "/opt/mine/codex-acp --flag"))
        XCTAssertEqual(settings.acpAgents[0].launchMode, .custom)
        settings.useCatalogLaunch(id: row.id)
        XCTAssertEqual(settings.acpAgents[0].launchMode, .auto)
        XCTAssertEqual(settings.acpAgents[0].command, "codex-acp")
        XCTAssertTrue(settings.acpAgents[0].args.isEmpty)
        XCTAssertEqual(settings.acpAgents[0].id, row.id, "the identity, and so the chats and secrets, stay")
    }
}
