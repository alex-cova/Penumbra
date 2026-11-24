import AgentKit
import AppKit
import SwiftUI
import XCTest
@testable import Umbra

final class IDEAgentUsageTests: XCTestCase {
    private func usage(_ input: Int, _ output: Int, cached: Int = 0) -> TokenUsage {
        TokenUsage(inputTokens: input, outputTokens: output, cachedInputTokens: cached)
    }

    private func record(
        project: String = "/p/app", model: String = "sonnet", input: Int = 1_000, output: Int = 100,
        cached: Int = 0, cost: Double? = 0.5, at date: Date = Date(), byModel: [String: TokenUsage]? = nil
    ) -> IDEAgentUsageRecord {
        let total = usage(input, output, cached: cached)
        return IDEAgentUsageRecord(
            id: UUID(), title: "t", projectRoot: project, updatedAt: date, usage: total,
            byModel: byModel ?? [model: total], cost: cost)
    }

    func testTotalsKeepRecordedCostsAndCountChatsWithoutOne() {
        let report = IDEAgentUsageReport.make([
            record(input: 1_000, output: 100, cached: 400, cost: 0.5),
            record(model: "qwen-local", input: 2_000, output: 200, cost: nil),
            record(input: 0, output: 0, cost: nil),
        ], days: nil)
        XCTAssertEqual(report.chats, 2, "a chat that used no tokens is not counted")
        XCTAssertEqual(report.cost, 0.5)
        XCTAssertEqual(report.unpricedChats, 1)
        XCTAssertEqual(report.total.inputTokens, 3_000)
        XCTAssertEqual(report.cachedShare ?? -1, 400.0 / 3_000.0, accuracy: 0.0001)
        XCTAssertEqual(report.byModel.map(\.name), ["sonnet", "qwen-local"], "costliest first, then by tokens")
        XCTAssertNil(report.byModel[1].cost)
    }

    func testAChatsCostGoesToTheModelThatDidMostOfItsWork() {
        let chat = record(cost: 1.0, byModel: ["sonnet": usage(5_000, 500), "helper-local": usage(20_000, 300)])
        let report = IDEAgentUsageReport.make([chat], days: nil)
        let rows = Dictionary(uniqueKeysWithValues: report.byModel.map { ($0.name, $0) })
        XCTAssertEqual(rows["helper-local"]?.cost, 1.0)
        XCTAssertNil(rows["sonnet"]?.cost)
        XCTAssertEqual(rows["sonnet"]?.chats, 1)
        XCTAssertEqual(report.byModel.reduce(0) { $0 + $1.usage.inputTokens }, 25_000)
    }

    func testProjectsAreNamedByFolderAndAIChatByName() {
        let report = IDEAgentUsageReport.make([
            record(project: "/Users/me/shop", cost: 2),
            record(project: IDEAIChatConversation.storeRoot, cost: 1),
        ], days: nil)
        XCTAssertEqual(report.byProject.map(\.name), ["shop", "AI Chat"])
    }

    func testThePeriodShowsEveryDayEndingToday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 15)))
        let twoDaysAgo = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: now))
        let report = IDEAgentUsageReport.make(
            [record(cost: 0.25, at: twoDaysAgo), record(cost: 0.75, at: now)], days: 7, now: now, calendar: calendar)
        XCTAssertEqual(report.byDay.count, 7)
        XCTAssertEqual(report.byDay.last?.day, calendar.startOfDay(for: now))
        XCTAssertEqual(report.byDay.last?.cost, 0.75)
        XCTAssertEqual(report.byDay[4].cost, 0.25)
        XCTAssertEqual(report.byDay.filter { $0.cost == 0 }.count, 5)
    }

    // MARK: - Loading saved chats

    private func makeStore() throws -> SessionStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return SessionStore(directory: folder)
    }

    private func save(
        _ store: SessionStore, project: String, total: TokenUsage, cost: Double?,
        byModel: [String: TokenUsage] = [:], choice: IDEAIModelChoice? = nil, updatedAt: Date = Date()
    ) throws {
        let host = IDEAgentSavedTranscript.encode(entries: [], cost: cost, modelChoice: choice, usageByModel: byModel)
        try store.save(SessionSnapshot(
            projectRoot: project, title: "chat", updatedAt: updatedAt, items: [.user("hi")], totalUsage: total, host: host))
    }

    func testTheLoaderReadsSavedSplitsAndFallsBackForOlderChats() throws {
        let store = try makeStore()
        try save(store, project: "/p/app", total: usage(300, 30), cost: 0.2,
                 byModel: ["sonnet": usage(200, 20), "haiku": usage(100, 10)])
        try save(store, project: "/p/app", total: usage(50, 5), cost: nil,
                 choice: IDEAIModelChoice(provider: .ollama, model: "qwen3"))
        try save(store, project: "/p/other", total: usage(10, 1), cost: 0.01)

        let app = IDEAgentUsageLoader.records(in: store, projectRoot: "/p/app", since: nil)
        XCTAssertEqual(app.count, 2)
        let split = try XCTUnwrap(app.first { $0.cost == 0.2 })
        XCTAssertEqual(split.byModel["haiku"], usage(100, 10))
        let older = try XCTUnwrap(app.first { $0.cost == nil })
        XCTAssertEqual(older.byModel, ["qwen3": usage(50, 5)], "a chat without a saved split is put on its model")

        XCTAssertEqual(IDEAgentUsageLoader.records(in: store, projectRoot: nil, since: nil).count, 3)
    }

    func testTheLoaderSkipsChatsOlderThanThePeriod() throws {
        let store = try makeStore()
        let old = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -40, to: Date()))
        try save(store, project: "/p/app", total: usage(10, 1), cost: 0.1, updatedAt: old)
        try save(store, project: "/p/app", total: usage(10, 1), cost: 0.2)
        let since = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -30, to: Date()))
        let recent = IDEAgentUsageLoader.records(in: store, projectRoot: "/p/app", since: since)
        XCTAssertEqual(recent.map(\.cost), [0.2])
    }

    func testAChatSavesItsPerModelSplit() throws {
        let split = ["sonnet": usage(7, 3)]
        let data = try XCTUnwrap(IDEAgentSavedTranscript.encode(entries: [], cost: 0.1, usageByModel: split))
        XCTAssertEqual(IDEAgentSavedTranscript.decode(data).usageByModel, split)
        XCTAssertEqual(IDEAgentSavedTranscript.decode(IDEAgentSavedTranscript.encode(entries: [], cost: nil)).usageByModel, [:])
    }

    /// Draws the sheet over seeded chats; writes `usage-sheet.png` when `AI_MODE_PNG_DIR` is set.
    @MainActor
    func testTheSheetRendersSeededChats() async throws {
        let store = try makeStore()
        let calendar = Calendar.current
        for (offset, cost) in [(0, 0.42), (1, 1.10), (3, 0.35), (6, 2.05), (12, 0.80)] {
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: -offset, to: Date()))
            try save(store, project: "/Users/me/shop", total: usage(180_000, 9_000), cost: cost,
                     byModel: ["claude-sonnet-5-5": usage(150_000, 8_000), "qwen3-coder (local)": usage(30_000, 1_000)],
                     updatedAt: day)
        }
        try save(store, project: "/Users/me/shop", total: usage(40_000, 2_000), cost: nil,
                 choice: IDEAIModelChoice(provider: .ollama, model: "qwen3"))
        let sheet = IDEAgentUsageSheet(
            sources: .init(agentStore: store, projectRoot: "/Users/me/shop", chatStore: nil), dismiss: {})
            .background(IDEAppearance.ColorToken.window)
            .preferredColorScheme(IDEAppearance.preferredColorScheme)
        let host = NSHostingView(rootView: sheet)
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 760)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(800))
        host.layoutSubtreeIfNeeded()
        // The tables must fit in the sheet's own size, not only in a tall window.
        XCTAssertGreaterThan(host.fittingSize.height, 600)
        guard let directory = ProcessInfo.processInfo.environment["AI_MODE_PNG_DIR"],
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("usage-sheet.png"))
    }
}
