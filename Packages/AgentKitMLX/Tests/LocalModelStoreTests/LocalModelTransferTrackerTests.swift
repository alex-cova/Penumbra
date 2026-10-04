import Foundation
import Testing
@testable import LocalModelStore

struct LocalModelTransferTrackerTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func emitsNothingBeforeAnyBytesArrive() {
        var tracker = LocalModelTransferTracker(totalBytes: 1_000)
        #expect(tracker.snapshot(at: t0) == nil)
    }

    @Test func throttlesSnapshotsToTheMinimumInterval() {
        var tracker = LocalModelTransferTracker(totalBytes: 1_000)
        tracker.add(10)
        #expect(tracker.snapshot(at: t0, minInterval: 0.5) != nil)
        tracker.add(10)
        #expect(tracker.snapshot(at: t0.addingTimeInterval(0.2), minInterval: 0.5) == nil)
        #expect(tracker.snapshot(at: t0.addingTimeInterval(0.6), minInterval: 0.5) != nil)
    }

    @Test func forcedSnapshotBypassesTheThrottleAndTheZeroByteGuard() {
        var tracker = LocalModelTransferTracker(totalBytes: 1_000)
        #expect(tracker.snapshot(at: t0, force: true) != nil)
        tracker.add(5)
        _ = tracker.snapshot(at: t0.addingTimeInterval(0.1))
        #expect(tracker.snapshot(at: t0.addingTimeInterval(0.15), force: true) != nil)
    }

    @Test func estimatesSpeedFromBytesOverTime() throws {
        var tracker = LocalModelTransferTracker(totalBytes: 10_000)
        tracker.add(1)
        _ = tracker.snapshot(at: t0, minInterval: 0)          // opens the speed window
        tracker.add(1_000)
        let taken = tracker.snapshot(at: t0.addingTimeInterval(1), minInterval: 0)
        let snapshot = try #require(taken)
        let speed = try #require(snapshot.bytesPerSecond)
        #expect(abs(speed - 1_000) < 1)
    }

    @Test func smoothsSpeedAcrossWindows() throws {
        var tracker = LocalModelTransferTracker(totalBytes: 100_000)
        tracker.add(1)
        _ = tracker.snapshot(at: t0, minInterval: 0)
        tracker.add(1_000)
        _ = tracker.snapshot(at: t0.addingTimeInterval(1), minInterval: 0)       // 1000 B/s
        tracker.add(3_000)
        let taken = tracker.snapshot(at: t0.addingTimeInterval(2), minInterval: 0)   // 3000 B/s instant
        // 0.65 * 1000 + 0.35 * 3000 = 1700
        let snapshot = try #require(taken)
        let speed = try #require(snapshot.bytesPerSecond)
        #expect(abs(speed - 1_700) < 1)
    }

    // MARK: - Per-file reconciliation

    /// URLSession's delegate can skip small files entirely; a finished file must still count in full.
    @Test func aFileThatNeverReportedBytesStillCountsOnceComplete() {
        var tracker = LocalModelTransferTracker(totalBytes: 1_000)
        tracker.completeFile(size: 937)
        #expect(tracker.bytesDownloaded == 937)
    }

    @Test func completingAFileReplacesTheDelegatesRunningCountInsteadOfAddingToIt() {
        var tracker = LocalModelTransferTracker(totalBytes: 1_000)
        tracker.add(300)
        tracker.add(200)
        tracker.completeFile(size: 500)
        #expect(tracker.bytesDownloaded == 500)   // not 1_000
    }

    @Test func aPartiallyReportedFileDoesNotDriftTheTotal() {
        var tracker = LocalModelTransferTracker(totalBytes: 1_000)
        tracker.add(100)                 // delegate saw only part of the file
        tracker.completeFile(size: 400)
        tracker.add(50)                  // next file in flight
        #expect(tracker.bytesDownloaded == 450)
        tracker.completeFile(size: 600)
        #expect(tracker.bytesDownloaded == 1_000)
    }

    @Test func meterReachesTheTotalEvenWhenTheDelegateStaysSilent() {
        let meter = LocalModelTransferMeter(totalBytes: 10)
        meter.begin(file: "config.json")
        meter.completeFile(size: 2)
        meter.begin(file: "model.safetensors")
        meter.completeFile(size: 8)
        #expect(meter.final().fractionCompleted == 1)
    }

    @Test func ignoresNegativeByteCounts() {
        var tracker = LocalModelTransferTracker(totalBytes: 100)
        tracker.add(50)
        tracker.add(-20)
        #expect(tracker.bytesDownloaded == 50)
    }

    @Test func negativeTotalIsClampedToZero() {
        #expect(LocalModelTransferTracker(totalBytes: -5).totalBytes == 0)
    }

    // MARK: - Progress value

    @Test func fractionIsCappedAtOneAndNilWithoutATotal() {
        #expect(LocalModelDownloadProgress(bytesDownloaded: 50, totalBytes: 200).fractionCompleted == 0.25)
        #expect(LocalModelDownloadProgress(bytesDownloaded: 300, totalBytes: 200).fractionCompleted == 1)
        #expect(LocalModelDownloadProgress(bytesDownloaded: 50, totalBytes: 0).fractionCompleted == nil)
    }

    @Test func detailTextShowsTotalAndSpeedOnlyWhenKnown() {
        let full = LocalModelDownloadProgress(bytesDownloaded: 1_000_000, totalBytes: 5_000_000, bytesPerSecond: 500_000)
        #expect(full.detailText.contains(" of "))
        #expect(full.detailText.contains("/s"))
        #expect(full.speedText?.contains("/s") == true)

        let bare = LocalModelDownloadProgress(bytesDownloaded: 1_000_000, totalBytes: 0)
        #expect(!bare.detailText.contains(" of "))
        #expect(!bare.detailText.contains("/s"))

        let paused = LocalModelDownloadProgress(bytesDownloaded: 1_000_000, totalBytes: 5_000_000, isPaused: true)
        #expect(paused.detailText.contains("Paused"))
        #expect(paused.speedText == nil)
    }

    @Test func etaTextAppearsWhenSpeedAndTotalAreKnown() {
        let progress = LocalModelDownloadProgress(
            bytesDownloaded: 1_000_000, totalBytes: 5_000_000, bytesPerSecond: 1_000_000
        )
        #expect(progress.etaText?.contains("left") == true)
        #expect(progress.detailText.contains("left"))
    }

    @Test func meterRestoresPausedProgress() {
        let meter = LocalModelTransferMeter(totalBytes: 1_000)
        meter.restore(completedBytes: 400, currentFile: "model.safetensors")
        let snapshot = meter.final()
        #expect(snapshot.bytesDownloaded == 400)
        #expect(snapshot.currentFile == "model.safetensors")
    }

    @Test func meterAggregatesBytesAndReportsTheCurrentFile() throws {
        let meter = LocalModelTransferMeter(totalBytes: 1_000)
        meter.begin(file: "model.safetensors")
        _ = meter.add(400)
        let final = meter.final()
        #expect(final.bytesDownloaded == 400)
        #expect(final.currentFile == "model.safetensors")
        #expect(final.totalBytes == 1_000)
    }
}
