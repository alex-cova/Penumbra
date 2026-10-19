import AgentKit
import Foundation
import XCTest

@testable import Umbra

@MainActor
final class IDEAgentPermissionsModelTests: XCTestCase {
    private var base: URL!
    private var root: URL!
    private var appFile: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("agent-perm-model-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("project", isDirectory: true)
        appFile = base.appendingPathComponent("app/permissions.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    private func makeModel() -> IDEAgentPermissionsModel {
        IDEAgentPermissionsModel(projectRoot: { [root] in root }, appFile: appFile)
    }

    private func entries(_ model: IDEAgentPermissionsModel, _ origin: IDEAgentPermissionFiles.Origin) -> [String] {
        model.groups.first { $0.origin == origin }?.entries.map { "\($0.kind) \($0.rule)" } ?? []
    }

    func testAnEmptyProjectHasNoRulesButEveryPlaceTheyCouldBe() {
        let model = makeModel()
        model.reload()
        XCTAssertTrue(model.isEmpty)
        XCTAssertEqual(model.groups.map(\.origin), [.app, .projectShared, .projectLocal, .claudeShared, .claudeLocal])
    }

    func testInitReadsNothingAndReloadPicksUpTheFiles() throws {
        // `init` must stay cheap: the section's `State(initialValue:)` evaluates it on every
        // parent redraw and discards all but the first result, so a read here repeats per keystroke.
        let model = makeModel()
        XCTAssertTrue(model.groups.isEmpty, "nothing is read until the section's task reloads")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try #"{"permissions":{"allow":["Bash(make:*)"]}}"#.write(to: root.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
        model.reload()
        XCTAssertEqual(entries(model, .claudeShared), ["allow Bash(make:*)"])
    }

    func testAddingWritesToTheChosenFileAndListsItUnderThatSource() throws {
        let model = makeModel()
        model.add("Bash(npm test:*)", kind: .allow, scope: .project)
        model.add("Bash(rm:*)", kind: .deny, scope: .app)

        XCTAssertEqual(entries(model, .projectLocal), ["allow Bash(npm test:*)"])
        XCTAssertEqual(entries(model, .app), ["deny Bash(rm:*)"])
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".umbra/settings.local.json").path))
    }

    func testTextThatIsNotARuleIsReportedAndWritesNothing() {
        let model = makeModel()
        model.add("Bash(", kind: .allow, scope: .project)
        XCTAssertTrue(model.error?.contains("is not a rule") == true)
        XCTAssertTrue(model.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".umbra").path))

        model.add("Bash(ls:*)", kind: .allow, scope: .project)
        XCTAssertNil(model.error, "the next good rule clears the message")
    }

    func testRemovingEditsOnlyTheFilesUmbraOwns() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try #"{"permissions":{"allow":["Bash(make:*)"]}}"#.write(to: root.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
        let model = makeModel()
        model.reload()
        model.add("Bash(ls:*)", kind: .allow, scope: .project)

        let claude = try XCTUnwrap(model.groups.first { $0.origin == .claudeShared }?.entries.first)
        XCTAssertFalse(claude.origin.isEditable)
        model.remove(claude)
        XCTAssertEqual(entries(model, .claudeShared), ["allow Bash(make:*)"], "Claude Code's file is never written")

        let ours = try XCTUnwrap(model.groups.first { $0.origin == .projectLocal }?.entries.first)
        model.remove(ours)
        XCTAssertTrue(entries(model, .projectLocal).isEmpty)
    }

    func testExampleFailuresBadgeOnTheRightEntry() throws {
        let local = root.appendingPathComponent(".umbra/settings.local.json")
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"""
        {"permissions":{"allow":[
          {"rule":"Bash(git status:*)","match":["git status --short"],"not_match":["git push"]},
          {"rule":"Bash(npm test:*)","match":["npm run"]}
        ]}}
        """#.write(to: local, atomically: true, encoding: .utf8)
        let model = makeModel()
        model.reload()
        let localEntries = try XCTUnwrap(model.groups.first { $0.origin == .projectLocal }?.entries)
        XCTAssertEqual(localEntries.count, 2)
        let passing = try XCTUnwrap(localEntries.first { $0.rule == PermissionRule(tool: "Bash", pattern: "git status:*") })
        XCTAssertTrue(passing.exampleFailures.isEmpty, "passing examples give no badge")
        let failing = try XCTUnwrap(localEntries.first { $0.rule == PermissionRule(tool: "Bash", pattern: "npm test:*") })
        XCTAssertEqual(failing.exampleFailures.count, 1, "one failing example gives exactly one badge")
        XCTAssertEqual(failing.exampleFailures.first?.example, "npm run")
        XCTAssertEqual(failing.exampleFailures.first?.expectedMatch, true)
    }

    func testFileWithNoExamplesGivesNoBadges() throws {
        let local = root.appendingPathComponent(".umbra/settings.local.json")
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"permissions":{"allow":["Bash(make:*)"]}}"#.write(to: local, atomically: true, encoding: .utf8)
        let model = makeModel()
        model.reload()
        let localEntries = try XCTUnwrap(model.groups.first { $0.origin == .projectLocal }?.entries)
        XCTAssertEqual(localEntries.count, 1)
        XCTAssertTrue(localEntries.allSatisfy { $0.exampleFailures.isEmpty })
    }

    func testAskingWhetherACommandWouldRunUsesTheRulesAndTheMode() async throws {
        let model = makeModel()
        model.add("Bash(make:*)", kind: .allow, scope: .project)
        model.add("Bash(make clean:*)", kind: .deny, scope: .project)

        let runs = await model.verdict(forCommand: "make test", mode: .manual)
        XCTAssertEqual(runs, .allow)
        let denied = await model.verdict(forCommand: "make clean", mode: .manual)
        guard case .deny = denied else { return XCTFail("expected a refusal, got \(denied)") }
        let asks = await model.verdict(forCommand: "swift build", mode: .acceptEdits)
        guard case .ask = asks else { return XCTFail("expected an ask, got \(asks)") }
        let auto = await model.verdict(forCommand: "git status", mode: .auto)
        XCTAssertEqual(auto, .allow)

        XCTAssertEqual(IDEAgentPermissionsModel.describe(.allow), "Runs without asking.")
        XCTAssertEqual(IDEAgentPermissionsModel.describe(.ask(notes: [])), "Asks first.")
        XCTAssertEqual(IDEAgentPermissionsModel.describe(.deny("no")), "no")
    }
}
