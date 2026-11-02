import AgentKit
import Foundation
import XCTest

@testable import Umbra

/// The harness-5 `/pr` skill: seeded from the bundle, picked up by the command catalog.
final class IDEAgentBundledSkillsTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundled-skills-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    private func bundled() throws -> URL {
        let bundled = base.appendingPathComponent("bundle", isDirectory: true)
        let skill = bundled.appendingPathComponent("pr", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try """
        ---
        name: pr
        description: Open a pull request for the current branch with gh.
        allowed-tools: [git_log, git_diff, run_command]
        ---

        # Opening a pull request
        """.write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return bundled
    }

    func testSeedCopiesMissingSkillsAndKeepsUserEdits() throws {
        let support = base.appendingPathComponent("support", isDirectory: true)
        try IDEAgentBundledSkills.seed(appSupport: support, bundled: bundled())
        let target = support.appendingPathComponent("skills/pr/SKILL.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))

        let catalog = SkillCatalog.load(
            skillFolders: [.init(url: support.appendingPathComponent("skills"), label: "Umbra skills")],
            commandFolders: [])
        let skill = catalog.skill(named: "pr")
        XCTAssertEqual(skill?.description, "Open a pull request for the current branch with gh.")
        XCTAssertEqual(skill?.allowedTools, ["git_log", "git_diff", "run_command"])

        try "custom".write(to: target, atomically: true, encoding: .utf8)
        try IDEAgentBundledSkills.seed(appSupport: support, bundled: bundled())
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "custom")
    }

    func testSeedWithNoFoldersDoesNothing() {
        IDEAgentBundledSkills.seed(appSupport: nil, bundled: nil)
        IDEAgentBundledSkills.seed(appSupport: base, bundled: nil)
    }
}
