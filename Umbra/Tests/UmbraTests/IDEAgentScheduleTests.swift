import AgentKit
import AppKit
import SwiftUI
import XCTest
@testable import Umbra

final class IDEAgentScheduleTimingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func schedule(created: Date, lastRun: Date? = nil, paused: Bool = false) -> IDEAgentSchedule {
        IDEAgentSchedule(
            name: "check", prompt: "check the build", interval: 3_600, mode: .acceptEdits,
            createdAt: created, lastRunAt: lastRun, isPaused: paused)
    }

    func testADueScheduleRunsAndOneDueBeforeWatchingIsOfferedInstead() {
        let fresh = schedule(created: start)
        XCTAssertEqual(IDEAgentScheduleTiming.decide(fresh, now: start.addingTimeInterval(1_800), watchingSince: start), .notDue)
        XCTAssertEqual(IDEAgentScheduleTiming.decide(fresh, now: start.addingTimeInterval(3_601), watchingSince: start), .run)

        // Due an hour before the window started watching (Umbra was closed).
        let stale = schedule(created: start.addingTimeInterval(-7_200))
        XCTAssertEqual(
            IDEAgentScheduleTiming.decide(stale, now: start, watchingSince: start),
            .missed(due: start.addingTimeInterval(-3_600)))
    }

    func testAPausedScheduleNeverFires() {
        let paused = schedule(created: start, paused: true)
        XCTAssertEqual(IDEAgentScheduleTiming.decide(paused, now: start.addingTimeInterval(99_999), watchingSince: start), .notDue)
    }

    func testTheLastRunSetsTheNextOne() {
        let ran = schedule(created: start, lastRun: start.addingTimeInterval(5_000))
        XCTAssertEqual(ran.nextDue, start.addingTimeInterval(8_600))
    }

    func testNamesAndIntervals() {
        XCTAssertEqual(IDEAgentSchedule.name(for: "check the build\nand report"), "check the build")
        XCTAssertEqual(IDEAgentSchedule.name(for: String(repeating: "x", count: 60)).count, 40)
        XCTAssertEqual(IDEAgentScheduler.describe(interval: 300), "every 5 min")
        XCTAssertEqual(IDEAgentScheduler.describe(interval: 7_200), "every 2 h")
        XCTAssertEqual(IDEAgentScheduler.describe(interval: 86_400), "every day")
        XCTAssertEqual(IDEAgentLoopInterval.parse("1d"), 86_400)
    }
}

@MainActor
final class IDEAgentSchedulerTests: XCTestCase {
    private var base: URL!
    private var project: URL!
    private var storeDirectory: URL!
    private var workspace: IDEWorkspace!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        base = FileManager.default.temporaryDirectory.appendingPathComponent("agent-schedules-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        project = base.appendingPathComponent("project")
        storeDirectory = base.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        workspace = IDEWorkspace()
        workspace.project.setRoot(project)
    }

    override func tearDownWithError() throws {
        workspace.teardown()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: base)
    }

    /// A controller whose scheduler is driven by hand: its own loop is stopped before its first tick.
    private func makeController(_ turns: [MockTurn] = [.text("Build is green.")]) -> (IDEAgentController, MockLLMClient) {
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        settings.saveAPIKey("sk-test")
        settings.acceptDisclosure()
        let client = MockLLMClient(turns: turns)
        let controller = IDEAgentController(
            settings: settings, store: SessionStore(directory: storeDirectory), clientFactory: { _ in client })
        controller.attach(host: workspace)
        controller.scheduler.stop()
        controller.newConversation()
        return (controller, client)
    }

    private func waitFor(_ message: String, _ condition: () -> Bool) async {
        for _ in 0..<800 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }

    func testTheCommandAddsAScheduleWithThisChatsModeAndAutoOnlyWhenAsked() throws {
        let (controller, _) = makeController()
        controller.selected.setMode(.auto)
        controller.scheduleCommand(arguments: "2m check")
        XCTAssertTrue(controller.scheduler.schedules.isEmpty, "under five minutes is refused")
        XCTAssertTrue(controller.selected.entries.last?.text.contains("/loop") == true)

        controller.scheduleCommand(arguments: "1h check the build")
        controller.scheduleCommand(arguments: "1d --auto tidy imports")
        let schedules = controller.scheduler.schedules
        XCTAssertEqual(schedules.map(\.interval), [3_600, 86_400])
        XCTAssertEqual(schedules.map(\.mode), [.acceptEdits, .auto], "Auto carries over only with --auto")
        XCTAssertEqual(schedules.first?.prompt, "check the build")

        // Saved beside the project's chats, so a new window finds them.
        let store = SessionStore(directory: storeDirectory)
        let loaded = IDEAgentScheduleFile.load(store: store, projectRoot: project.standardizedFileURL.path)
        XCTAssertEqual(loaded.map(\.id), schedules.map(\.id))
        XCTAssertEqual(loaded.map(\.mode), [.acceptEdits, .auto])
        XCTAssertEqual(loaded.map(\.prompt), ["check the build", "tidy imports"])

        controller.scheduleCommand(arguments: "")
        XCTAssertTrue(controller.isShowingSchedules)
        controller.teardown()
    }

    func testADueScheduleRunsInAChatOfItsOwnWithoutTakingTheSelection() async throws {
        let (controller, client) = makeController()
        let start = Date()
        controller.scheduler.tick(now: start)  // starts watching the project
        let visible = controller.selected.id
        controller.scheduler.add(IDEAgentSchedule(
            name: "check the build", prompt: "check the build", interval: 3_600, mode: .acceptEdits, createdAt: start))

        controller.scheduler.tick(now: start.addingTimeInterval(1_800))
        XCTAssertEqual(controller.conversations.count, 1, "not due yet")

        controller.scheduler.tick(now: start.addingTimeInterval(3_601))
        XCTAssertEqual(controller.conversations.count, 2)
        XCTAssertEqual(controller.selected.id, visible, "a scheduled run does not take the panel")
        let run = try XCTUnwrap(controller.conversations.last)
        XCTAssertTrue(run.title.hasPrefix("check the build · "), run.title)
        XCTAssertEqual(run.mode, .acceptEdits)
        await waitFor("the run answers") { !run.isRunning && run.entries.contains { $0.kind == .assistant } }
        let sent = client.requests.first?.items.compactMap { item -> String? in if case .user(let text) = item { text } else { nil } }.joined() ?? ""
        XCTAssertTrue(sent.contains("check the build"), sent)
        let saved = try XCTUnwrap(controller.scheduler.schedules.first)
        XCTAssertEqual(saved.lastChatID, run.conversationID)
        XCTAssertEqual(saved.lastRunAt, start.addingTimeInterval(3_601))
        controller.teardown()
    }

    func testARunMissedWhileTheProjectWasClosedIsOfferedNotRun() throws {
        let store = SessionStore(directory: storeDirectory)
        let twoHoursAgo = Date().addingTimeInterval(-7_200)
        IDEAgentScheduleFile.save([IDEAgentSchedule(
            name: "nightly", prompt: "run the nightly checks", interval: 3_600, mode: .acceptEdits, createdAt: twoHoursAgo)],
            store: store, projectRoot: project.standardizedFileURL.path)

        let (controller, client) = makeController()
        var notified: [String] = []
        controller.onNotify = { _, title, _, _ in notified.append(title) }
        controller.scheduler.tick()

        let offered = try XCTUnwrap(controller.conversations.last)
        XCTAssertFalse(offered.isRunning)
        XCTAssertEqual(offered.draft, "run the nightly checks", "the prompt waits in the field")
        XCTAssertTrue(offered.entries.contains { $0.kind == .notice && $0.text.contains("was due") })
        XCTAssertTrue(client.requests.isEmpty, "nothing was sent")
        XCTAssertEqual(notified, ["Scheduled prompt “nightly” was missed"])

        // It is offered once: the next tick counts from now.
        controller.scheduler.tick()
        XCTAssertEqual(controller.conversations.count, 2)
        controller.teardown()
    }

    func testPausedSchedulesWaitAndResumeCountsFromNow() {
        let (controller, _) = makeController()
        let start = Date()
        controller.scheduler.tick(now: start)
        controller.scheduler.add(IDEAgentSchedule(
            name: "check", prompt: "check", interval: 300, mode: .acceptEdits, createdAt: start))
        let id = try! XCTUnwrap(controller.scheduler.schedules.first?.id)
        controller.scheduler.setPaused(true, id: id)
        controller.scheduler.tick(now: start.addingTimeInterval(3_600))
        XCTAssertEqual(controller.conversations.count, 1)
        controller.scheduler.setPaused(false, id: id)
        XCTAssertGreaterThan(try! XCTUnwrap(controller.scheduler.schedules.first?.nextDue), Date())
        controller.scheduler.remove(id)
        XCTAssertTrue(controller.scheduler.schedules.isEmpty)
        controller.teardown()
    }

    /// Writes `schedules-sheet.png` when `AI_MODE_PNG_DIR` is set.
    func testTheSheetRenders() async throws {
        let (controller, _) = makeController()
        let now = Date()
        controller.scheduler.add(IDEAgentSchedule(
            name: "check the build", prompt: "check the build", interval: 3_600, mode: .acceptEdits,
            createdAt: now, lastRunAt: now.addingTimeInterval(-1_200)))
        var nightly = IDEAgentSchedule(
            name: "Run the nightly checks and report…", prompt: "Run the nightly checks and report anything that regressed since yesterday, with the failing test names.",
            interval: 86_400, mode: .auto, createdAt: now)
        nightly.lastNote = "Skipped 09:00: the previous run was still going."
        controller.scheduler.add(nightly)
        var paused = IDEAgentSchedule(name: "tidy imports", prompt: "tidy imports", interval: 900, mode: .manual, createdAt: now)
        paused.isPaused = true
        controller.scheduler.add(paused)
        let sheet = IDEAgentSchedulesSheet(agent: controller, dismiss: {})
            .background(IDEAppearance.ColorToken.window)
            .preferredColorScheme(IDEAppearance.preferredColorScheme)
        let host = NSHostingView(rootView: sheet)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertGreaterThan(host.fittingSize.height, 300, "the list is not collapsed")
        defer { controller.teardown() }
        guard let directory = ProcessInfo.processInfo.environment["AI_MODE_PNG_DIR"],
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("schedules-sheet.png"))
    }
}
