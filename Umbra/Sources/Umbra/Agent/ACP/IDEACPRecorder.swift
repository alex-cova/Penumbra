import AgentKit
import Foundation

/// Records an external agent's ACP traffic for replay tests (`ACPRecording`, `ACPReplayTransport`,
/// `docs/harness/agent-harness-11.md` item 3). Off unless `UMBRA_ACP_RECORD_DIR` names a folder: a developer
/// switch, not a setting. Each agent process gets one `.jsonl` file. Every string is scrubbed
/// (`IDEACPSecretScrubber`, and the home folder becomes `~`) before it is written, and the file still holds
/// prompts, replies and paths, so it is read before it is committed.
final class IDEACPRecorder: @unchecked Sendable {
    static let environmentKey = "UMBRA_ACP_RECORD_DIR"

    private let lock = NSLock()
    private let handle: FileHandle
    let url: URL

    /// Nil when recording is off or the file cannot be made.
    static func make(agent: String, version: String?, environment: [String: String] = ProcessInfo.processInfo.environment) -> IDEACPRecorder? {
        guard let folder = environment[environmentKey], !folder.isEmpty else { return nil }
        let directory = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let slug = agent.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let name = String(slug) + (version.map { "-\($0)" } ?? "") + "-" + formatter.string(from: Date()) + ".jsonl"
        let url = directory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let note = "// \(agent)\(version.map { " \($0)" } ?? "") recorded by Umbra. Scrubbed, but read it before committing.\n"
            guard FileManager.default.createFile(atPath: url.path, contents: Data(note.utf8), attributes: [.posixPermissions: 0o600])
            else { return nil }
            return IDEACPRecorder(url: url, handle: try FileHandle(forWritingTo: url))
        } catch {
            return nil
        }
    }

    private init(url: URL, handle: FileHandle) {
        self.url = url
        self.handle = handle
        handle.seekToEndOfFile()
    }

    /// The transport the session talks through: `inner`, with every frame written here.
    func wrap(_ inner: any ACPTransport) -> any ACPTransport {
        ACPRecordingTransport(wrapping: inner) { [self] entry in write(entry) }
    }

    func write(_ entry: ACPRecording.Entry) {
        let scrubbed = ACPRecording.Entry(side: entry.side, frame: entry.frame.map { ACPRecording.mappingStrings($0, Self.scrub) })
        lock.withLock { handle.write(Data((scrubbed.line + "\n").utf8)) }
    }

    static func scrub(_ text: String) -> String {
        let home = NSHomeDirectory()
        let withoutHome = home.isEmpty ? text : text.replacingOccurrences(of: home, with: "~")
        return IDEACPSecretScrubber.scrub(withoutHome)
    }

    deinit { try? handle.close() }
}
