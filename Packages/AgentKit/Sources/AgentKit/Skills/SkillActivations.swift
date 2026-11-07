import Foundation

extension Skill {
    /// What the model reads when a skill is started, by the `skill` tool or by the user's `/name`: the
    /// instructions inside `<skill_content>` so they can be told apart from the rest of the conversation and
    /// found again (a compaction keeps them, a second load is refused), then the skill's folder, which is what
    /// relative paths in the instructions mean, and the files in it. The files are named, never read.
    public func activationText() -> String {
        var listed = SkillTool.listFiles(in: directory, limit: SkillTool.maxListedFiles + 1)
        let cut = listed.count > SkillTool.maxListedFiles
        if cut { listed.removeLast() }

        var text = "<skill_content name=\"\(name)\">\n\(Self.defangClosing(body))\n\n"
        text += "Skill directory: \(directory.standardizedFileURL.path)\n"
        text += "Relative paths in this skill are relative to that directory. Read a file there with "
        text += "skill(name: \"\(name)\", file: \"path\"); run a script by its absolute path.\n"
        if !listed.isEmpty {
            text += "<skill_resources>\n"
            for file in listed { text += "  <file>\(file)</file>\n" }
            if cut { text += "  (more files exist; this list is cut)\n" }
            text += "</skill_resources>\n"
        }
        text += "</skill_content>"
        return text
    }

    /// A body cannot end its own block early.
    private static func defangClosing(_ body: String) -> String {
        body.replacingOccurrences(of: "</skill_content", with: "< /skill_content", options: .caseInsensitive)
    }
}

/// Finds the skills a conversation has already loaded. The model is not told twice (a second `skill` call
/// answers "already loaded"), a compaction does not stub or lose them, and a summary re-announces the ones it
/// swallowed. Only blocks the editor itself produced count: the output of a `skill` call without `file`, and a
/// user message outside any `<untrusted>` block. A `read_file` that happens to print one proves nothing, and
/// what a note repeats after a summary comes from the catalog, never from text found in the history.
public enum SkillActivations {
    public struct Block: Sendable, Equatable {
        public var name: String
        /// The item the block is in.
        public var index: Int
    }

    static let opening = "<skill_content name=\""

    /// Every genuine block, oldest first.
    public static func blocks(in items: [ConversationItem]) -> [Block] {
        var found: [Block] = []
        for index in items.indices {
            switch items[index] {
            case .toolOutput(let callID, let output):
                guard output.hasPrefix(opening), isSkillActivationCall(callID, before: index, in: items),
                      let open = output.range(of: opening), let name = name(after: open, in: output)
                else { continue }
                found.append(Block(name: name, index: index))
            case .user(let text):
                found += userBlocks(in: text, index: index)
            case .userParts(let parts):
                let text = parts.compactMap { part -> String? in if case .text(let value) = part { value } else { nil } }.joined(separator: "\n")
                found += userBlocks(in: text, index: index)
            default:
                continue
            }
        }
        return found
    }

    /// Names (lowercased) of the skills with a block somewhere in `items`.
    public static func loaded(in items: [ConversationItem]) -> Set<String> {
        Set(blocks(in: items).map { $0.name.lowercased() })
    }

    /// True for a tool output that is a skill's instructions, which compaction must not turn into a stub.
    static func isActivationOutput(at index: Int, in items: [ConversationItem]) -> Bool {
        guard case .toolOutput(let callID, let output) = items[index], output.hasPrefix(opening) else { return false }
        return isSkillActivationCall(callID, before: index, in: items)
    }

    /// The `skill` call that made output `callID`, with no `file` argument (that reads a file, not the instructions).
    private static func isSkillActivationCall(_ callID: String, before index: Int, in items: [ConversationItem]) -> Bool {
        for item in items[..<index].reversed() {
            guard case .toolCall(let id, let name, let arguments) = item, id == callID else { continue }
            guard name == "skill" else { return false }
            let object = (try? JSONValue(parsing: arguments))?.objectValue
            let file = object?["file"]?.stringValue ?? ""
            return file.isEmpty
        }
        return false
    }

    private static func userBlocks(in text: String, index: Int) -> [Block] {
        guard text.contains(opening) else { return [] }
        var body = Substring(text)
        if let end = text.range(of: UserText.editorStateEnd) { body = text[end.upperBound...] }
        var blocks: [Block] = []
        var search = body.startIndex
        while let range = body.range(of: opening, range: search..<body.endIndex) {
            search = range.upperBound
            let atLineStart = range.lowerBound == body.startIndex || body[body.index(before: range.lowerBound)] == "\n"
            guard atLineStart, !isInsideUntrusted(body[..<range.lowerBound]), let name = name(after: range, in: body) else { continue }
            blocks.append(Block(name: name, index: index))
        }
        return blocks
    }

    /// An attachment or shell output may quote anything; a block inside one is not the editor's.
    private static func isInsideUntrusted(_ before: Substring) -> Bool {
        let lowered = before.lowercased()
        return lowered.ranges(of: "<untrusted").count > lowered.ranges(of: "</untrusted>").count
    }

    /// The name between the quotes that follow `open`, the range of the opening text.
    private static func name(after open: Range<String.Index>, in text: some StringProtocol) -> String? {
        guard let quote = text[open.upperBound...].firstIndex(of: "\"") else { return nil }
        let name = String(text[open.upperBound..<quote])
        guard !name.isEmpty, name.count <= 200, !name.contains(where: { $0 == "<" || $0 == ">" || $0.isNewline }) else { return nil }
        return name
    }
}
