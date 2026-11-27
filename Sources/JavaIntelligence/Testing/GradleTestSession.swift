import Foundation

/// Owns journal decoding and the result graph for one invocation. A reader can also reconstruct
/// the graph from a saved journal using this same actor.
public actor GradleTestSession {
    public nonisolated let id: UUID
    public nonisolated let directory: URL

    public struct Node: Identifiable, Sendable {
        public var id: String { event.nodeID ?? "" }
        public fileprivate(set) var event: GradleTestEvent
        public fileprivate(set) var outcome: GradleTestEvent.Outcome
        public fileprivate(set) var output: [GradleTestEvent.Output] = []

        public var isTest: Bool { event.kind == .testStarted || event.kind == .testFinished }
        public var isSuite: Bool { event.kind == .suiteStarted || event.kind == .suiteFinished }
    }

    public struct Update: Sendable {
        public let nodes: [Node]
        public let counts: [GradleTestEvent.Outcome: Int]
        public let issues: Int
    }

    private var offset: UInt64 = 0
    private var pending = Data()
    private var skippingRecord = false
    private var sequences: Set<UInt64> = []
    private var nodes: [String: Node] = [:]
    private var pendingOutput: [String: [GradleTestEvent.Output]] = [:]
    private var changed: Set<String> = []
    private var counts: [GradleTestEvent.Outcome: Int] = [:]
    private var issues = 0
    private var sealed = false

    public init(id: UUID, directory: URL) {
        self.id = id
        self.directory = directory
    }

    public func ingest(_ event: GradleTestEvent) {
        guard !sealed, event.version == 1, event.sessionID == id else { return }
        guard sequences.insert(event.sequence).inserted else { return }
        guard let nodeID = event.nodeID else { return }
        if event.kind == .output {
            guard let output = event.output else { return }
            if nodes[nodeID] != nil {
                nodes[nodeID]?.output.append(output)
                changed.insert(nodeID)
            } else {
                pendingOutput[nodeID, default: []].append(output)
            }
            return
        }

        let old = nodes[nodeID]
        let outcome = event.outcome ?? .running
        if let old, old.outcome != .running { return }
        if let old, old.event.sequence > event.sequence, outcome == .running { return }
        let node = Node(event: event, outcome: outcome, output: old?.output ?? pendingOutput.removeValue(forKey: nodeID) ?? [])
        if old?.isTest == true, let previous = old?.outcome { counts[previous, default: 0] -= 1 }
        if node.isTest { counts[outcome, default: 0] += 1 }
        nodes[nodeID] = node
        changed.insert(nodeID)
    }

    /// Reads complete records written so far. The caller may poll while the writer is alive.
    public func poll() -> Update {
        readJournal(maxBytes: 2 * 1024 * 1024)
        return update()
    }

    public func seal(unfinished: GradleTestEvent.Outcome, cancelledAt: Date? = nil) -> Update {
        readJournal()
        sealed = true
        if !pending.isEmpty || skippingRecord { issues += 1 }
        let workerFailures: [String: Int64] = Dictionary(nodes.values.compactMap { node -> (String, Int64)? in
            guard node.event.kind == .taskFinished, let failure = node.event.failure, let task = node.event.task,
                  failure.type.contains("WorkerProcessException") || failure.type.contains("ExecException")
                    || (failure.type.contains("ProcessExecutionException") && failure.stackTrace?.contains("Gradle Test Executor") == true)
            else { return nil }
            return (node.event.build + "\0" + task, node.event.timestamp)
        }, uniquingKeysWith: max)
        let cancellationFile = directory.appendingPathComponent("cancelled-at.txt")
        let cancellationTime: Int64?
        if let cancelledAt {
            let millis = Int64(cancelledAt.timeIntervalSince1970 * 1_000)
            try? Data(String(millis).utf8).write(to: cancellationFile, options: .atomic)
            cancellationTime = millis
        } else if unfinished == .cancelled {
            cancellationTime = (try? String(contentsOf: cancellationFile, encoding: .utf8)).flatMap(Int64.init)
        } else {
            cancellationTime = nil
        }
        for id in Array(nodes.keys) {
            guard var node = nodes[id] else { continue }
            let taskKey = node.event.build + "\0" + (node.event.task ?? "")
            let workerFailure = workerFailures[taskKey]
            let outcome: GradleTestEvent.Outcome
            if node.outcome == .running {
                outcome = unfinished == .unknown && workerFailure != nil ? .aborted : unfinished
            } else if node.isTest, node.outcome == .skipped, (node.event.durationMs ?? 0) > 0 {
                // Gradle may synthesize a skipped finish when it unwinds a live test. Prefer
                // cancellation or worker failure evidence only at the end of the affected task.
                if unfinished == .cancelled, let cancellationTime, node.event.timestamp >= cancellationTime {
                    outcome = .cancelled
                } else if let workerFailure, node.event.timestamp <= workerFailure,
                          workerFailure.subtractingReportingOverflow(node.event.timestamp).partialValue.magnitude <= 100 {
                    outcome = .aborted
                } else {
                    continue
                }
            } else {
                continue
            }
            if node.isTest {
                counts[node.outcome, default: 0] -= 1
                counts[outcome, default: 0] += 1
            }
            node.outcome = outcome
            nodes[id] = node
            changed.insert(id)
        }
        return update()
    }

    private func update() -> Update {
        let delta = changed.compactMap { nodes[$0] }.sorted { $0.event.sequence < $1.event.sequence }
        changed.removeAll(keepingCapacity: true)
        return Update(nodes: delta, counts: counts, issues: issues)
    }

    private func readJournal(maxBytes: UInt64 = .max) {
        guard !sealed else { return }
        let url = directory.appendingPathComponent("events.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let fileEnd = try file.seekToEnd()
            guard offset <= fileEnd else { issues += 1; return }
            let end = offset + min(maxBytes, fileEnd - offset)
            try file.seek(toOffset: offset)
            while offset < end {
                let read = try autoreleasepool {
                    guard let chunk = try file.read(upToCount: Int(min(256 * 1024, end - offset))), !chunk.isEmpty else {
                        return false
                    }
                    offset += UInt64(chunk.count)
                    consume(chunk)
                    return true
                }
                if !read { break }
            }
        } catch {
            issues += 1
        }
    }

    private func consume(_ chunk: Data) {
        let decoder = JSONDecoder()
        var start = chunk.startIndex
        while start < chunk.endIndex {
            let newline = chunk[start...].firstIndex(of: 0x0A)
            let end = newline ?? chunk.endIndex
            if !skippingRecord, pending.count + (end - start) <= 1024 * 1024 {
                pending.append(chunk[start..<end])
            } else {
                pending.removeAll(keepingCapacity: true)
                skippingRecord = true
            }
            guard let newline else { break }
            if !skippingRecord,
               let event = try? decoder.decode(GradleTestEvent.self, from: pending),
               event.version == 1, event.sessionID == id {
                ingest(event)
            } else {
                issues += 1
            }
            pending.removeAll(keepingCapacity: true)
            skippingRecord = false
            start = newline + 1
        }
    }
}
