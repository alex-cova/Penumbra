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
        XCTAssertTrue(model.isEmpty)
        XCTAssertEqual(model.groups.map(\.origin), [.app, .projectShared, .projectLocal, .claudeShared, .claudeLocal])
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
        model.add("Bash(ls:*)", kind: .allow, scope: .project)

        let claude = try XCTUnwrap(model.groups.first { $0.origin == .claudeShared }?.entries.first)
        XCTAssertFalse(claude.origin.isEditable)
        model.remove(claude)
        XCTAssertEqual(entries(model, .claudeShared), ["allow Bash(make:*)"], "Claude Code's file is never written")

        let ours = try XCTUnwrap(model.groups.first { $0.origin == .projectLocal }?.entries.first)
        model.remove(ours)
        XCTAssertTrue(entries(model, .projectLocal).isEmpty)
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
