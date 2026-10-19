import Foundation

/// One project's remembered notes: durable facts the model saved across chats. The file lives
/// beside the project's saved conversations (`<SessionStore dir>/<project hash>/MEMORY.md`), outside
/// the repo, so it is never committed and never falls under `WriteProtection`. The user can read
/// and delete it; the model only appends through the `remember` tool.
public enum ProjectMemory {
    public static let fileName = "MEMORY.md"
    /// What fits in the system prompt. Older entries are dropped first, so the newest survive.
    public static let byteLimit = 8 * 1024
    /// One appended line carries at most this many characters of the model's text.
    public static let maxLineLength = 300

    public static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// The memory text for the system prompt, or `nil` when there is none. A regular file, never a
    /// symlink; capped at `byteLimit` with the oldest entries dropped first.
    public static func load(at directory: URL) -> String? {
        let file = url(in: directory)
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let handle = try? FileHandle(forReadingFrom: file)
        else { return nil }
        defer { try? handle.close() }
        // The newest entries live at the end, so the cap keeps a window off the tail, not the head.
        let tailWindow = 64 * 1024
        let size = (try? handle.seekToEnd()) ?? 0
        guard size > 0 else { return nil }
        try? handle.seek(toFileOffset: size > UInt64(tailWindow) ? size - UInt64(tailWindow) : 0)
        var text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        if size > UInt64(tailWindow) {
            // The window starts mid-line: drop the partial first line.
            if let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
            else { return nil }
        }
        while text.first == "\u{FFFD}" { text.removeFirst() }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var kept: [String] = []
        var bytes = 0
        for line in lines.reversed() {
            let size = line.utf8.count + 1
            guard bytes + size <= byteLimit else { break }
            kept.append(line)
            bytes += size
        }
        let result = kept.reversed().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// Short and stable, so a host can start a new session when the memory changes. A write never
    /// touches the running session: memory loads once, at session start.
    public static func fingerprint(of text: String?) -> String {
        String(ReadLedger.hash(text ?? ""), radix: 16)
    }

    /// Appends `text` as one dated line, creating the file (0600) and its folder (0700) as needed.
    /// Returns whether anything was added: an empty text, or one already remembered, adds nothing.
    /// The file is rewritten atomically, so a concurrent reader never sees half a line.
    @discardableResult
    public static func append(_ text: String, at directory: URL, date: String) throws -> Bool {
        let clipped = String(text
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
            .prefix(maxLineLength))
        guard !clipped.isEmpty else { return false }
        let line = "\(date): \(clipped)"
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = url(in: directory)
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        if existing.split(separator: "\n").contains(where: { $0.body == clipped }) { return false }
        let next = existing.hasSuffix("\n") || existing.isEmpty ? existing + line + "\n" : existing + "\n" + line + "\n"
        try next.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return true
    }
}

private extension Substring {
    /// The remembered fact without its `YYYY-MM-DD: ` date prefix.
    var body: String {
        let text = String(self)
        guard text.count > 12 else { return text }
        let prefix = text.prefix(12)
        let digits = prefix.prefix(4).allSatisfy(\.isNumber)
            && prefix.dropFirst(5).prefix(2).allSatisfy(\.isNumber)
            && prefix.dropFirst(8).prefix(2).allSatisfy(\.isNumber)
        if digits && prefix.dropFirst(4).first == "-" && prefix.dropFirst(7).first == "-"
            && prefix.hasSuffix(": ") {
            return String(text.dropFirst(12))
        }
        return text
    }
}
