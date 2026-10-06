import Darwin
import Foundation
import XCTest
@testable import SubprocessKit

func shell(_ script: String) -> SubprocessRequest {
    SubprocessRequest(executable: "/bin/sh", arguments: ["-c", script])
}

func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

func waitUntilGone(_ pid: pid_t, seconds: Double = 5) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while isAlive(pid), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    return !isAlive(pid)
}

/// Reads a pid a script wrote with `echo $! > file`.
func readPID(_ url: URL) async throws -> pid_t {
    for _ in 0..<100 {
        if let text = try? String(contentsOf: url, encoding: .utf8),
           let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return value
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw XCTSkip("the child never reported its pid")
}

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("subprocesskit-\(UUID().uuidString)", isDirectory: true)
        .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class Chunks: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(SubprocessOutputSource, Data)] = []
    func append(_ data: Data, _ source: SubprocessOutputSource) { lock.withLock { items.append((source, data)) } }
    var count: Int { lock.withLock { items.count } }
    func text(_ source: SubprocessOutputSource) -> String {
        lock.withLock { String(decoding: items.filter { $0.0 == source }.reduce(Data()) { $0 + $1.1 }, as: UTF8.self) }
    }
}
