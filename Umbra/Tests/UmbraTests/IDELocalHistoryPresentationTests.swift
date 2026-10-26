import Foundation
import XCTest

@testable import Umbra

final class IDELocalHistoryPresentationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(
        _ path: String, _ seconds: Double, _ source: IDELocalHistorySource = .save, group: UUID? = nil, label: String? = nil
    ) -> IDELocalHistoryEvent {
        IDELocalHistoryEvent(time: t0.addingTimeInterval(seconds), path: path, before: "b", after: "a", source: source, group: group, label: label)
    }

    func testEverySourceHasATitleAndAnIcon() {
        XCTAssertEqual(IDELocalHistoryPresentation.title(for: .baseline), "Opened")
        XCTAssertEqual(IDELocalHistoryPresentation.title(for: .save), "Saved")
        XCTAssertEqual(IDELocalHistoryPresentation.title(for: .revert), "Reverted")
        XCTAssertEqual(IDELocalHistoryPresentation.title(for: .external), "Changed on disk")
        XCTAssertEqual(IDELocalHistoryPresentation.title(for: .refactor("Rename Foo")), "Rename Foo")
        XCTAssertEqual(IDELocalHistoryPresentation.title(for: .refactor("")), "Refactoring")
        XCTAssertEqual(IDELocalHistoryPresentation.title(for: .save, label: "before the big change"), "before the big change", "a name wins")
        XCTAssertEqual(IDELocalHistoryPresentation.symbol(for: .save, label: "x"), "tag.fill")
        for source in [IDELocalHistorySource.baseline, .save, .agent(tab: "t", prompt: "p"), .refactor("r"), .revert, .external, .label] {
            XCTAssertFalse(IDELocalHistoryPresentation.symbol(for: source).isEmpty)
        }
    }

    func testAnAgentRevisionNamesTheMessageThatCausedIt() {
        XCTAssertEqual(IDELocalHistoryPresentation.title(for: .agent(tab: "Parser", prompt: "make it faster")), "Agent · make it faster")
        XCTAssertEqual(IDELocalHistoryPresentation.title(for: .agent(tab: "Parser", prompt: "first line\nsecond line")), "Agent · first line")
        XCTAssertEqual(IDELocalHistoryPresentation.title(for: .agent(tab: "Parser", prompt: "")), "Agent · Parser")
        let long = IDELocalHistoryPresentation.title(for: .agent(tab: "T", prompt: String(repeating: "x", count: 200)))
        XCTAssertEqual(long.count, "Agent · ".count + 60)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testDaysAreHeadedTodayYesterdayThenTheDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_700_000_000 + 12 * 3_600)
        XCTAssertEqual(IDELocalHistoryPresentation.dayHeading(for: now.addingTimeInterval(-3_600), now: now, calendar: calendar), "Today")
        XCTAssertEqual(IDELocalHistoryPresentation.dayHeading(for: now.addingTimeInterval(-86_400), now: now, calendar: calendar), "Yesterday")
        let older = IDELocalHistoryPresentation.dayHeading(for: now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar)
        XCTAssertFalse(older == "Today" || older == "Yesterday" || older.isEmpty)

        let sections = IDELocalHistoryPresentation.byDay(
            [now, now.addingTimeInterval(-60), now.addingTimeInterval(-86_400), now.addingTimeInterval(-86_400 - 60)],
            time: { $0 }, now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.heading), ["Today", "Yesterday"])
        XCTAssertEqual(sections.map(\.items.count), [2, 2])
    }

    func testEventsOfOneActionAreOneGroup() {
        let run = UUID()
        let events = [
            event("A.java", 100, .agent(tab: "T", prompt: "p"), group: run),
            event("B.java", 99, .agent(tab: "T", prompt: "p"), group: run),
            event("C.java", 98, .agent(tab: "T", prompt: "p"), group: UUID()),
            event("A.java", 50),
        ]
        let groups = IDELocalHistoryPresentation.groups(events)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].id, run)
        XCTAssertEqual(groups[0].paths, ["A.java", "B.java"])
        XCTAssertEqual(IDELocalHistoryPresentation.summary(of: groups[0]), "2 files")
        XCTAssertEqual(IDELocalHistoryPresentation.summary(of: groups[1]), "C.java")
    }

    func testSavesWithinAFewSecondsAreOneSaveAll() {
        let events = [event("C", 10), event("B", 9), event("A", 8), event("Z", 0)]
        let groups = IDELocalHistoryPresentation.groups(events)
        XCTAssertEqual(groups.map(\.events.count), [3, 1])
        XCTAssertEqual(groups[0].paths, ["C", "B", "A"])
    }

    func testAgentWritesAndLabelsNeverMergeIntoSaves() {
        let events = [
            event("B", 10), event("A", 9, .agent(tab: "T", prompt: "p")), event("A", 8), event("A", 7, label: "named"), event("A", 6),
        ]
        XCTAssertEqual(IDELocalHistoryPresentation.groups(events).map(\.events.count), [1, 1, 1, 1, 1])
    }

    func testTheSameFileSavedTwiceQuicklyListsItOnce() {
        let groups = IDELocalHistoryPresentation.groups([event("A", 2), event("A", 1)])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].paths, ["A"])
        XCTAssertEqual(IDELocalHistoryPresentation.summary(of: groups[0]), "A")
    }

    func testAgentOnlyFilteringKeepsJustAgentRevisions() {
        let events = [event("A", 3, .agent(tab: "T", prompt: "p")), event("A", 2), event("A", 1, .revert)]
        XCTAssertEqual(events.filter(IDELocalHistoryPresentation.isAgent).count, 1)
    }

    func testNoEventsNoGroups() {
        XCTAssertTrue(IDELocalHistoryPresentation.groups([]).isEmpty)
    }
}
