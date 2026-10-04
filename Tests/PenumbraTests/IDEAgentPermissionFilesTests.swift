import AgentKit
import Foundation
import XCTest

@testable import Umbra

final class IDEAgentPermissionFilesTests: XCTestCase {
    private var root: URL!
    private var appFile: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("agent-perms-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("project", isDirectory: true)
        appFile = base.appendingPathComponent("app/permissions.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func write(_ text: String, to path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func rule(_ text: String) -> PermissionRule { PermissionRule(parsing: text)! }

    func testNoFilesMeansNoRules() {
        XCTAssertTrue(IDEAgentPermissionFiles.load(projectRoot: root, appFile: appFile).isEmpty)
        XCTAssertTrue(IDEAgentPermissionFiles.load(projectRoot: nil, appFile: nil).isEmpty)
    }

    func testEverySourceCountsAndTheListsMerge() throws {
        try FileManager.default.createDirectory(at: appFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"permissions":{"deny":["Bash(rm:*)"]}}"#.write(to: appFile, atomically: true, encoding: .utf8)
        try write(#"{"permissions":{"allow":["Bash(git status:*)"]}}"#, to: ".umbra/settings.json")
        try write(#"{"permissions":{"allow":["Bash(make:*)"],"ask":["Edit(docs/**)"]}}"#, to: ".umbra/settings.local.json")
        try write(#"{"permissions":{"allow":["Bash(git status:*)","Bash(npm test:*)"]}}"#, to: ".claude/settings.json")
        try write(#"{"permissions":{"deny":["Bash(curl:*)"]}}"#, to: ".claude/settings.local.json")

        let rules = IDEAgentPermissionFiles.load(projectRoot: root, appFile: appFile)
        XCTAssertEqual(rules.allow.map(\.description), ["Bash(git status:*)", "Bash(make:*)", "Bash(npm test:*)"], "a rule in two files appears once")
        XCTAssertEqual(rules.ask.map(\.description), ["Edit(docs/**)"])
        XCTAssertEqual(rules.deny.map(\.description), ["Bash(rm:*)", "Bash(curl:*)"], "a deny in any source applies")
    }

    func testABrokenFileLosesItsRulesWithoutStoppingTheOthers() throws {
        try write("{ not json", to: ".umbra/settings.json")
        try write(#"{"permissions":{"allow":["Bash(make:*)"]}}"#, to: ".umbra/settings.local.json")
        XCTAssertEqual(IDEAgentPermissionFiles.load(projectRoot: root, appFile: appFile).allow.map(\.description), ["Bash(make:*)"])
    }

    func testAddingCreatesTheFileAndFolderAndKeepsEverythingElse() throws {
        let file = try XCTUnwrap(IDEAgentPermissionFiles.file(for: .project, projectRoot: root, appFile: appFile))
        XCTAssertEqual(file.path, root.appendingPathComponent(".umbra/settings.local.json").path)

        XCTAssertTrue(try IDEAgentPermissionFiles.add(rule("Bash(git status:*)"), to: .allow, in: file))
        XCTAssertEqual(IDEAgentPermissionFiles.load(projectRoot: root, appFile: appFile).allow.map(\.description), ["Bash(git status:*)"])

        // Unrelated keys, in the file and in `permissions`, survive an addition.
        try #"{"theme":"dark","permissions":{"defaultMode":"plan","allow":["Bash(make:*)"]}}"#.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(try IDEAgentPermissionFiles.add(rule("Bash(npm test:*)"), to: .allow, in: file))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(object["theme"] as? String, "dark")
        let permissions = try XCTUnwrap(object["permissions"] as? [String: Any])
        XCTAssertEqual(permissions["defaultMode"] as? String, "plan")
        XCTAssertEqual(permissions["allow"] as? [String], ["Bash(make:*)", "Bash(npm test:*)"])
    }

    func testAddingTheSameRuleTwiceChangesNothingTheSecondTime() throws {
        let file = try XCTUnwrap(IDEAgentPermissionFiles.file(for: .project, projectRoot: root, appFile: appFile))
        XCTAssertTrue(try IDEAgentPermissionFiles.add(rule("Bash(make:*)"), to: .allow, in: file))
        XCTAssertFalse(try IDEAgentPermissionFiles.add(rule("Bash(make:*)"), to: .allow, in: file))
        XCTAssertEqual(IDEAgentPermissionFiles.load(projectRoot: root, appFile: appFile).allow.count, 1)
    }

    func testAFileThatIsNotJSONIsNeverOverwritten() throws {
        let file = root.appendingPathComponent(".umbra/settings.local.json")
        try write("// my notes\n{ \"permissions\": ", to: ".umbra/settings.local.json")
        XCTAssertThrowsError(try IDEAgentPermissionFiles.add(rule("Bash(make:*)"), to: .allow, in: file)) { error in
            XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("left as it is") == true)
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "// my notes\n{ \"permissions\": ")
    }

    func testAnEmptyFileIsTreatedAsNoSettings() throws {
        let file = root.appendingPathComponent(".umbra/settings.local.json")
        try write("  \n", to: ".umbra/settings.local.json")
        XCTAssertTrue(try IDEAgentPermissionFiles.add(rule("Bash(make:*)"), to: .allow, in: file))
    }

    func testRemovingTakesOutOnlyThatRule() throws {
        let file = try XCTUnwrap(IDEAgentPermissionFiles.file(for: .project, projectRoot: root, appFile: appFile))
        try IDEAgentPermissionFiles.add(rule("Bash(make:*)"), to: .allow, in: file)
        try IDEAgentPermissionFiles.add(rule("Bash(npm test:*)"), to: .allow, in: file)
        XCTAssertTrue(try IDEAgentPermissionFiles.remove(rule("Bash(make:*)"), from: .allow, in: file))
        XCTAssertEqual(IDEAgentPermissionFiles.load(projectRoot: root, appFile: appFile).allow.map(\.description), ["Bash(npm test:*)"])
        XCTAssertFalse(try IDEAgentPermissionFiles.remove(rule("Bash(make:*)"), from: .allow, in: file))
        XCTAssertFalse(try IDEAgentPermissionFiles.remove(rule("x"), from: .deny, in: root.appendingPathComponent("missing.json")))
    }

    func testTheAppScopeWritesToTheAppFile() throws {
        let file = try XCTUnwrap(IDEAgentPermissionFiles.file(for: .app, projectRoot: root, appFile: appFile))
        XCTAssertEqual(file, appFile)
        try IDEAgentPermissionFiles.add(rule("Bash(ls:*)"), to: .allow, in: file)
        XCTAssertEqual(IDEAgentPermissionFiles.load(projectRoot: nil, appFile: appFile).allow.map(\.description), ["Bash(ls:*)"])
        XCTAssertNil(IDEAgentPermissionFiles.file(for: .project, projectRoot: nil, appFile: appFile))
    }

    func testSourcesAreListedAppFirstThenTheProjectFiles() {
        let urls = IDEAgentPermissionFiles.sources(projectRoot: root, appFile: appFile)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["permissions.json", "settings.json", "settings.local.json", "settings.json", "settings.local.json"])
        XCTAssertEqual(urls.map { $0.deletingLastPathComponent().lastPathComponent }, ["app", ".umbra", ".umbra", ".claude", ".claude"])
    }
}
