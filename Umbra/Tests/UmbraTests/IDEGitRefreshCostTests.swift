import Foundation
import GitIntelligence
import XCTest
@testable import Umbra

/// Opt-in: the cost of refreshing a repository with a very large change set (audit G-13). Point
/// `UMBRA_GIT_COST_REPO` at a repository with ~100,000 files and ~10,000 modified ones, and run in
/// release (`swift test -c release -Xswiftc -enable-testing --package-path Umbra --filter IDEGitRefreshCostTests`);
/// Debug timings say nothing. It prints a `GITCOST` line per phase, and the largest gap a 1 ms ticker
/// on the main actor saw. With `UMBRA_GIT_COST_BUDGET=1` it also holds the budget: largest gap
/// under 50 ms and a refresh under 400 ms end to end.
@MainActor
final class IDEGitRefreshCostTests: XCTestCase {
    @MainActor private final class Ticker {
        var maxGap: Duration = .zero
        var stopped = false
        func run() async {
            var last = ContinuousClock.now
            while !stopped {
                try? await Task.sleep(for: .milliseconds(1))
                let now = ContinuousClock.now
                maxGap = max(maxGap, now - last - .milliseconds(1))
                last = now
            }
        }
    }

    private func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
    }

    func testRefreshOfALargeChangeSet() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["UMBRA_GIT_COST_REPO"] else { throw XCTSkip("set UMBRA_GIT_COST_REPO to run") }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let clock = ContinuousClock()

        // Where the time goes outside the model: git, then the parse of its output.
        let discovered = await GitRepository.discover(from: root)
        let repository = try XCTUnwrap(discovered)
        var entries: [GitStatusEntry] = []
        let statusStart = clock.now
        entries = try await repository.status()
        let statusTime = clock.now - statusStart
        var snapshot = IDEGitStatusModel.GitSnapshot()
        let parseTime = clock.measure {
            snapshot = IDEGitStatusModel.parse(entries: entries, toplevel: repository.root.path, branch: "main")
        }
        let names = entries.map(\.path).shuffled()
        var sorted: [String] = []
        let sortTime = clock.measure { sorted = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
        let plainSortTime = clock.measure { _ = names.sorted() }
        print("GITCOST sort(localizedStandardCompare)=\(milliseconds(sortTime))ms plain-sort=\(milliseconds(plainSortTime))ms n=\(sorted.count)")
        let listTime = clock.measure { _ = IDEGitChangeRows.listed(in: snapshot.changes) }
        print("GITCOST entries=\(entries.count) git-status=\(milliseconds(statusTime))ms parse=\(milliseconds(parseTime))ms listed=\(milliseconds(listTime))ms")

        // The whole path, with the main actor watched.
        let model = IDEGitStatusModel()
        let ticker = Ticker()
        let tickerTask = Task { await ticker.run() }
        let firstStart = clock.now
        model.setRoot(root)
        while model.workspaceSnapshot == nil, clock.now - firstStart < .seconds(60) { try await Task.sleep(for: .milliseconds(5)) }
        let first = clock.now - firstStart
        let firstGap = ticker.maxGap
        XCTAssertNotNil(model.workspaceSnapshot)

        try await Task.sleep(for: .seconds(2))   // let the ignored pass, history and the rest settle
        ticker.maxGap = .zero
        let before = model.lastAppliedRefreshEpoch
        let start = clock.now
        model.refresh()
        while model.lastAppliedRefreshEpoch == before, clock.now - start < .seconds(60) { try await Task.sleep(for: .milliseconds(2)) }
        let refresh = clock.now - start
        let refreshGap = ticker.maxGap
        ticker.stopped = true
        _ = await tickerTask.value
        print("GITCOST changes=\(model.changes.count) first-load=\(milliseconds(first))ms (gap \(milliseconds(firstGap))ms) refresh=\(milliseconds(refresh))ms (largest main-actor gap \(milliseconds(refreshGap))ms)")
        model.setRoot(nil)

        if environment["UMBRA_GIT_COST_BUDGET"] == "1" {
            XCTAssertLessThan(milliseconds(refreshGap), 50, "main actor stalled")
            XCTAssertLessThan(milliseconds(refresh), 400, "refresh too slow")
        }
    }
}
