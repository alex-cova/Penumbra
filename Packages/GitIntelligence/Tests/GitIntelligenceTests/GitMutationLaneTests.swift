import Foundation
import Testing

@testable import GitIntelligence

@Suite struct GitMutationLaneTests {
    private func directory() -> URL {
        URL(fileURLWithPath: "/tmp/git-lane-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func oneDirectorySerializes() async throws {
        let lane = GitMutationLane()
        let root = directory()
        let probe = DepthProbe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try await lane.perform(gitDirectory: root) {
                        await probe.enter()
                        try await Task.sleep(nanoseconds: 20_000_000)
                        await probe.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(await probe.maxDepth == 1)
    }

    @Test func cancellingAWaiterDoesNotCancelTheHolder() async throws {
        let lane = GitMutationLane()
        let root = directory()
        let started = Signal()
        let release = Signal()
        let holder = Task {
            try await lane.perform(gitDirectory: root) {
                await started.fire()
                await release.wait()
            }
        }
        await started.wait()
        let waiter = Task {
            try await lane.perform(gitDirectory: root) {
                Issue.record("the cancelled waiter ran")
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        waiter.cancel()
        await release.fire()
        try await holder.value
        let third = Task {
            try await lane.perform(gitDirectory: root) { }
        }
        try await third.value
        _ = await waiter.result
    }
}

private actor DepthProbe {
    private(set) var depth = 0
    private(set) var maxDepth = 0

    func enter() {
        depth += 1
        if depth > maxDepth { maxDepth = depth }
    }

    func leave() { depth -= 1 }
}

private actor Signal {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        fired = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        if fired { return }
        await withCheckedContinuation { continuation in
            if fired { continuation.resume() } else { waiters.append(continuation) }
        }
    }
}
