import Foundation

/// What a project's chats were asked, oldest first, for ↑ and Ctrl-R in the message field. One JSON
/// string per line in `prompts.jsonl` beside the project's conversations, readable by the user alone
/// (prompts can contain anything). Consecutive repeats are kept once, and only the newest 500 stay.
final class IDEAgentPromptHistory {
    static let limit = 500

    private(set) var prompts: [String] = []
    private let file: URL?
    private let limit: Int
    /// Lines in the file, so it is rewritten when it has grown well past the limit, not on every add.
    private var linesOnDisk = 0

    /// With no file, the history lives only as long as this object (tests, a window with no saved state).
    init(file: URL?, limit: Int = IDEAgentPromptHistory.limit) {
        self.file = file
        self.limit = limit
        load()
    }

    /// Adds what was just sent. Blank text and a repeat of the latest prompt are ignored.
    func add(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, prompts.last != prompt else { return }
        prompts.append(prompt)
        guard let file else {
            if prompts.count > limit { prompts.removeFirst(prompts.count - limit) }
            return
        }
        if prompts.count > limit { prompts.removeFirst(prompts.count - limit) }
        linesOnDisk += 1
        if linesOnDisk > limit + max(limit / 5, 1) {
            rewrite(file)
        } else {
            append(prompt, to: file)
        }
    }

    func clear() {
        prompts = []
        linesOnDisk = 0
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    // MARK: - Disk

    private func load() {
        guard let file, let data = try? Data(contentsOf: file) else { return }
        var loaded: [String] = []
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            // A line that is not a JSON string (a half-written one) is skipped.
            if let text = try? JSONDecoder().decode(String.self, from: Data(line)), !text.isEmpty { loaded.append(text) }
        }
        linesOnDisk = loaded.count
        prompts = Array(loaded.suffix(limit))
    }

    private func append(_ prompt: String, to file: URL) {
        guard var line = try? JSONEncoder().encode(prompt) else { return }
        line.append(UInt8(ascii: "\n"))
        let manager = FileManager.default
        try? manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: file, options: .atomic)
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    private func rewrite(_ file: URL) {
        var data = Data()
        for prompt in prompts {
            guard var line = try? JSONEncoder().encode(prompt) else { continue }
            line.append(UInt8(ascii: "\n"))
            data.append(line)
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        linesOnDisk = prompts.count
    }
}

/// Where ↑ and ↓ are in the history, and the draft to come back to. Pure.
struct IDEAgentPromptRecall: Equatable {
    /// Index into the prompts being shown, or `nil` when the field shows the user's own text.
    private(set) var position: Int?
    private var draft = ""

    var isRecalling: Bool { position != nil }

    /// ↑: the previous prompt. The first press keeps what was typed, to return to with ↓.
    /// `nil` at the oldest one: there is nothing further back.
    mutating func previous(current: String, in prompts: [String]) -> String? {
        guard !prompts.isEmpty else { return nil }
        if let position {
            guard position > 0 else { return nil }
            self.position = position - 1
        } else {
            draft = current
            position = prompts.count - 1
        }
        return prompts[position!]
    }

    /// ↓: the next prompt, and after the newest the text that was being typed. `nil` when not recalling.
    mutating func next(in prompts: [String]) -> String? {
        guard let position else { return nil }
        if position + 1 < prompts.count {
            self.position = position + 1
            return prompts[position + 1]
        }
        self.position = nil
        return draft
    }

    /// The user typed, sent or switched: whatever is in the field is theirs again.
    mutating func reset() {
        position = nil
        draft = ""
    }

    /// Prompts matching `query`, newest first, for Ctrl-R. Fuzzy on the whole prompt; an empty query is everything.
    static func search(_ query: String, in prompts: [String], match: (String, String) -> Int?, limit: Int = 30) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        var seen = Set<String>()
        var scored: [(prompt: String, score: Int, recency: Int)] = []
        for (index, prompt) in prompts.enumerated().reversed() where seen.insert(prompt).inserted {
            if trimmed.isEmpty { scored.append((prompt, 0, index)); continue }
            if let score = match(trimmed, prompt) { scored.append((prompt, score, index)) }
        }
        scored.sort { ($0.score, $0.recency) > ($1.score, $1.recency) }
        return scored.prefix(limit).map(\.prompt)
    }
}
