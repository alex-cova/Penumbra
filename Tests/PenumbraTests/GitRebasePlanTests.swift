import XCTest
@testable import GitIntelligence

final class GitRebasePlanTests: XCTestCase {
    private func step(_ action: GitRebaseStep.Action, _ name: String, message: String? = nil) -> GitRebaseStep {
        GitRebaseStep(action: action, hash: String(repeating: name, count: 40), subject: "subject \(name)", message: message)
    }

    private func todo(_ steps: [GitRebaseStep]) -> [String] {
        GitRebasePlan(steps: steps).todoText { "/m/\($0)" }.split(separator: "\n").map(String.init)
    }

    func testPlainActionsBecomeTodoLines() {
        let lines = todo([step(.pick, "a"), step(.edit, "b"), step(.drop, "c")])
        XCTAssertEqual(lines, [
            "pick \(String(repeating: "a", count: 40)) subject a",
            "edit \(String(repeating: "b", count: 40)) subject b",
            "drop \(String(repeating: "c", count: 40)) subject c"
        ])
    }

    func testARewordIsAPickFollowedByAnAmendWithItsMessageFile() {
        let lines = todo([step(.reword, "a", message: "new text"), step(.pick, "b")])
        XCTAssertEqual(lines[0], "pick \(String(repeating: "a", count: 40)) subject a")
        XCTAssertTrue(lines[1].hasPrefix("exec git commit --amend --no-verify"), lines[1])
        XCTAssertTrue(lines[1].hasSuffix("-F '/m/0'"), lines[1])
        XCTAssertEqual(lines.count, 3)
    }

    func testASquashGroupGetsOneAmendAfterItsLastStep() {
        let lines = todo([
            step(.pick, "a", message: "combined"), step(.squash, "b"), step(.fixup, "c"), step(.pick, "d")
        ])
        XCTAssertEqual(lines.count, 5)
        XCTAssertTrue(lines[0].hasPrefix("pick "))
        XCTAssertTrue(lines[1].hasPrefix("squash "))
        XCTAssertTrue(lines[2].hasPrefix("fixup "))
        XCTAssertTrue(lines[3].hasPrefix("exec git commit --amend"), "after the group, not inside it: \(lines[3])")
        XCTAssertTrue(lines[3].hasSuffix("-F '/m/0'"))
        XCTAssertTrue(lines[4].hasPrefix("pick "))
    }

    func testASquashGroupWithoutAMessageKeepsGitsOwn() {
        let lines = todo([step(.pick, "a"), step(.squash, "b")])
        XCTAssertEqual(lines.count, 2)
    }

    func testAPathWithAQuoteIsEscapedForTheShell() {
        let plan = GitRebasePlan(steps: [step(.reword, "a", message: "m")])
        let text = plan.todoText { _ in "/tmp/it's here/message" }
        XCTAssertTrue(text.contains("-F '/tmp/it'\\''s here/message'"), text)
    }

    func testValidation() {
        XCTAssertNil(GitRebasePlan(steps: [step(.pick, "a"), step(.squash, "b")]).validationProblem())
        XCTAssertNotNil(GitRebasePlan(steps: []).validationProblem())
        XCTAssertNotNil(GitRebasePlan(steps: [step(.squash, "a"), step(.pick, "b")]).validationProblem(),
                        "the first commit cannot be squashed")
        XCTAssertNotNil(GitRebasePlan(steps: [step(.drop, "a"), step(.fixup, "b")]).validationProblem(),
                        "dropping the commit above leaves the fixup first")
        XCTAssertNotNil(GitRebasePlan(steps: [step(.drop, "a")]).validationProblem())
        XCTAssertNotNil(GitRebasePlan(steps: [step(.reword, "a", message: "  ")]).validationProblem())
        XCTAssertNotNil(GitRebasePlan(steps: [step(.pick, "a"), step(.pick, "a")]).validationProblem())
    }

    func testChangesNothing() {
        let steps = [step(.pick, "a"), step(.pick, "b")]
        XCTAssertTrue(GitRebasePlan(steps: steps).changesNothing(originalOrder: steps.map(\.hash)))
        XCTAssertFalse(GitRebasePlan(steps: steps.reversed()).changesNothing(originalOrder: steps.map(\.hash)))
        XCTAssertFalse(GitRebasePlan(steps: [step(.pick, "a"), step(.drop, "b")]).changesNothing(originalOrder: steps.map(\.hash)))
    }

    // MARK: - Builders

    private func plan(_ names: [String]) -> GitRebasePlan {
        GitRebasePlan(steps: names.map { step(.pick, $0) })
    }

    private func hash(_ name: String) -> String { String(repeating: name, count: 40) }

    func testRewordingSetsTheActionAndMessage() {
        let result = plan(["a", "b"]).rewording(hash("b"), to: "new")
        XCTAssertEqual(result.steps.map(\.action), [.pick, .reword])
        XCTAssertEqual(result.steps[1].message, "new")
        XCTAssertNil(result.validationProblem())
    }

    func testDroppingMarksOnlyTheChosen() {
        let result = plan(["a", "b", "c"]).dropping([hash("b")])
        XCTAssertEqual(result.steps.map(\.action), [.pick, .drop, .pick])
    }

    func testSquashingMovesTheSelectedUnderTheOldestAndKeepsTheRestInOrder() {
        let result = plan(["a", "b", "c", "d"]).squashing([hash("a"), hash("c")], message: "joined")
        XCTAssertEqual(result.steps.map(\.hash), [hash("a"), hash("c"), hash("b"), hash("d")])
        XCTAssertEqual(result.steps.map(\.action), [.pick, .squash, .pick, .pick])
        XCTAssertEqual(result.steps[0].message, "joined")
        XCTAssertNil(result.validationProblem())
    }

    func testSquashingKeepsCommitsBeforeTheGroupWhereTheyAre() {
        let result = plan(["a", "b", "c"]).squashing([hash("b"), hash("c")], message: nil)
        XCTAssertEqual(result.steps.map(\.hash), [hash("a"), hash("b"), hash("c")])
        XCTAssertEqual(result.steps.map(\.action), [.pick, .pick, .squash])
    }

    func testFixingUpMovesTheCommitUnderItsTarget() {
        let result = plan(["a", "b", "c"]).fixingUp(hash("c"), into: hash("a"))
        XCTAssertEqual(result.steps.map(\.hash), [hash("a"), hash("c"), hash("b")])
        XCTAssertEqual(result.steps.map(\.action), [.pick, .fixup, .pick])
        let unchanged = plan(["a", "b"]).fixingUp(hash("a"), into: hash("b"))
        XCTAssertEqual(unchanged, plan(["a", "b"]), "a commit cannot fix up one that comes after it")
    }
}

