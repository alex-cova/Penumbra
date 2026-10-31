import AgentKit
import Foundation

/// A `ToolOutputStore` that lives for one trial, so oversized output is saved and read back the way
/// it is in Umbra. Without one, a trial would never exercise `read_tool_output`.
final class MemoryOutputStore: ToolOutputStore, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [String: String] = [:]

    func save(_ text: String, id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        saved[id] = text
        return true
    }

    func load(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return saved[id]
    }
}
