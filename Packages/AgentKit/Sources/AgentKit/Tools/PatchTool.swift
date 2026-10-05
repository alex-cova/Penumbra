import Foundation

/// Where a hunk lands in a file's lines, or why it can't.
enum HunkMatcher {
    /// `lines` have no terminators. Returns the index of the hunk's first old line.
    static func locate(
        _ hunk: PatchHunk, in lines: [String], notBefore floor: Int, path: String,
        tolerance: EditTolerance = .hosted
    ) throws -> Placement {
        let old = hunk.oldLines
        if old.isEmpty {
            // A pure insertion: `@@ -n,0 ... @@` adds after line n.
            return Placement(index: min(max(hunk.oldStart, floor), lines.count))
        }

        func matches(at position: Int) -> Bool {
            guard position >= floor, position + old.count <= lines.count else { return false }
            for offset in 0..<old.count where lines[position + offset] != old[offset] { return false }
            return true
        }

        let stated = max(0, hunk.oldStart - 1)
        if matches(at: stated) { return Placement(index: stated) }
        let candidates = (floor...max(floor, lines.count - old.count)).filter(matches)
        switch candidates.count {
        case 1:
            return Placement(index: candidates[0])
        case 0:
            if let found = EditMatching.hunkPosition(old: old, in: lines, floor: floor, tolerance: tolerance) {
                let note = found.shift == nil
                    ? " Applied after normalizing line endings, trailing whitespace or punctuation."
                    : " Applied after shifting indentation to match the file."
                return Placement(index: found.index, shift: found.shift, note: note)
            }
            throw PatchError(mismatch(hunk, lines: lines, floor: floor, path: path))
        default:
            // Nearest to where the hunk says it is; a tie means the context is not enough to decide.
            let ranked = candidates.sorted { abs($0 - stated) < abs($1 - stated) }
            if abs(ranked[0] - stated) == abs(ranked[1] - stated) || candidates.count > 1 && abs(ranked[0] - stated) > 3 {
                let places = candidates.prefix(4).map { String($0 + 1) }.joined(separator: ", ")
                throw PatchError("Hunk \(hunk.number) of \(path) matches \(candidates.count) places (lines \(places)\(candidates.count > 4 ? ", …" : "")). Add more unchanged lines around the change so it matches exactly one.")
            }
            return Placement(index: ranked[0])
        }
    }

    struct Placement {
        var index: Int
        var shift: EditMatching.IndentShift?
        var note: String = ""
    }

    /// Names the first line that did not match, at the place where the most lines matched.
    private static func mismatch(_ hunk: PatchHunk, lines: [String], floor: Int, path: String) -> String {
        let old = hunk.oldLines
        var best = (position: -1, matched: -1)
        for position in floor..<max(floor + 1, lines.count) {
            var matched = 0
            while matched < old.count, position + matched < lines.count, lines[position + matched] == old[matched] { matched += 1 }
            if matched > best.matched { best = (position, matched) }
        }
        let prefix = "Hunk \(hunk.number) (\(hunk.header)) of \(path) does not match the file."
        guard best.matched > 0 || (best.position >= 0 && best.position < lines.count) else {
            return prefix + " The file has no lines there; re-read it."
        }
        if best.matched == 0 {
            return prefix + " Its first line was not found anywhere: expected `\(clip(old[0]))`. Copy the lines from a fresh read_file, exactly, including indentation."
        }
        let at = best.position + best.matched
        let actual = at < lines.count ? "`\(clip(lines[at]))`" : "the end of the file"
        return prefix + " The first \(best.matched) line(s) match at line \(best.position + 1), then hunk line \(best.matched + 1) expected `\(clip(old[best.matched]))` but the file has \(actual) at line \(at + 1)."
    }

    private static func clip(_ text: String) -> String { text.count > 100 ? String(text.prefix(100)) + "…" : text }
}

/// One file's computed result: the edits against the text the model read, and what they produce.
struct PlannedFile {
    let path: String
    let isCreation: Bool
    let original: String?
    let expected: String
    let edits: [AgentTextEdit]
    let added: Int
    let removed: Int
    let hunkCount: Int
    /// 1-based, in the new text: where the first hunk's first changed line is, and how many lines
    /// the change spans, so the preview shows the change and not just its surroundings.
    let firstChangedLine: Int
    let changedLineCount: Int
    /// Set when a hunk matched only after normalization or an indentation shift.
    let matchNote: String
}

enum PatchPlanner {
    static func plan(_ file: FilePatch, text: String?, tolerance: EditTolerance = .hosted) throws -> PlannedFile {
        if file.isCreation { return try planCreation(file) }
        guard let text else { throw PatchError("\(file.path) does not exist. To create a file, start the patch with `--- /dev/null`.") }

        let ending = EditSupport.lineEnding(of: text)
        let endsWithNewline = text.hasSuffix("\n")
        var lines = text.components(separatedBy: "\n")
        if endsWithNewline { lines.removeLast() }
        // Compare without carriage returns; the file's own endings are put back on write.
        let bare = lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }

        let ns = text as NSString
        var starts = [0]
        for index in 0..<ns.length where ns.character(at: index) == 0x0A { starts.append(index + 1) }

        var edits: [AgentTextEdit] = []
        var floor = 0
        var added = 0, removed = 0
        var firstChanged = 1
        var changedCount = 1
        var shift = 0  // lines added minus removed by earlier hunks
        var matchNote = ""
        for hunk in file.hunks {
            let located = try HunkMatcher.locate(hunk, in: bare, notBefore: floor, path: file.path, tolerance: tolerance)
            if matchNote.isEmpty { matchNote = located.note }
            let position = located.index
            let oldCount = hunk.oldLines.count
            let endsAtEOF = position + oldCount == lines.count
            if edits.isEmpty {
                let leading = hunk.lines.prefix { if case .context = $0 { true } else { false } }.count
                let trailing = hunk.lines.reversed().prefix { if case .context = $0 { true } else { false } }.count
                firstChanged = position + 1 + leading + shift
                changedCount = max(1, hunk.newLines.count - leading - trailing)
            }
            shift += hunk.addedCount - hunk.removedCount

            // Whether the file ends with a newline after this hunk.
            // Whether the file ends with a newline after this hunk. If the hunk's last line is an
            // added one, the new file ends with it, and it has a newline unless a `\ No newline`
            // marker says otherwise; if the last line is old text, the file's own state is kept
            // unless a marker says the file gains or loses it.
            var finalNewline = endsWithNewline
            if endsAtEOF {
                if case .added? = hunk.lines.last {
                    finalNewline = !hunk.newMissingEOL
                } else if hunk.newMissingEOL {
                    finalNewline = false
                } else if hunk.oldMissingEOL {
                    finalNewline = true
                }
            }

            let replacementLines = hunk.newLines.map { located.shift?.apply(to: $0) ?? $0 }
            var replacement = ""
            var location = position < starts.count ? starts[position] : ns.length
            var length = 0
            if oldCount > 0 {
                let end = position + oldCount < starts.count ? starts[position + oldCount] : ns.length
                length = end - location
            }
            for (offset, line) in replacementLines.enumerated() {
                let isLast = offset == replacementLines.count - 1
                replacement += line
                if !(isLast && endsAtEOF && !finalNewline) { replacement += ending }
            }
            if position >= lines.count, !endsWithNewline, !lines.isEmpty {
                // Appending after a last line that has no terminator: give it one first.
                replacement = ending + replacement
                location = ns.length
            }
            edits.append(AgentTextEdit(location: location, length: length, replacement: replacement))
            floor = position + oldCount
            added += hunk.addedCount
            removed += hunk.removedCount
        }

        let expected = try AgentTextEdit.apply(edits, to: text)
        if expected == text {
            throw PatchError("\(file.path): the patch changes nothing once line endings, trailing whitespace or punctuation are normalized.")
        }
        return PlannedFile(
            path: file.path, isCreation: false, original: text, expected: expected, edits: edits,
            added: added, removed: removed, hunkCount: file.hunks.count, firstChangedLine: firstChanged,
            changedLineCount: changedCount, matchNote: matchNote)
    }

    private static func planCreation(_ file: FilePatch) throws -> PlannedFile {
        var lines: [String] = []
        var missingEOL = false
        for hunk in file.hunks {
            guard hunk.removedCount == 0, !hunk.lines.contains(where: { if case .context = $0 { true } else { false } }) else {
                throw PatchError("\(file.path) is being created, so its hunks may only add lines (`+`), but hunk \(hunk.number) has context or removals.")
            }
            lines += hunk.newLines
            missingEOL = hunk.newMissingEOL
        }
        let text = lines.joined(separator: "\n") + (missingEOL || lines.isEmpty ? "" : "\n")
        return PlannedFile(
            path: file.path, isCreation: true, original: nil, expected: text, edits: [], added: lines.count, removed: 0,
            hunkCount: file.hunks.count, firstChangedLine: 1, changedLineCount: max(lines.count, 1), matchNote: "")
    }
}

/// A patch failed on one file. `run` counts it and, on the third miss, suggests `write_file`.
private struct PatchFileFailure: Error {
    var path: String
    var message: String
}

public struct ApplyPatchTool: AgentTool {
    public static let maxFiles = 20

    public init() {}
    public var risk: ToolRisk { .edit }
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "apply_patch",
            description: """
            Change several places or files at once with a unified diff. All or nothing: if any hunk \
            does not match, nothing is changed. Format: for each file `--- a/path` and `+++ b/path` \
            (`--- /dev/null` to create a file), then hunks starting `@@ -start,count +start,count @@`, \
            whose lines begin with a space (unchanged), `-` (removed) or `+` (added). Include about \
            three unchanged lines around each change, copied exactly from read_file with indentation; \
            line numbers may be approximate, the content decides. It cannot delete or rename files. \
            Read each existing file first.
            """,
            parameters: [ToolParameter("patch", .string, "The unified diff.")])
    }

    /// The files the diff names. A diff that does not parse names none, and fails on its own.
    public func permissionSubject(for arguments: ToolArguments) -> PermissionSubject {
        guard let text = try? arguments.string("patch"), let files = try? PatchParser.parse(text) else { return .none }
        return .paths(files.map(\.path))
    }

    /// Every file checked and the result computed, before anything is written.
    func prepare(_ arguments: ToolArguments, context: ToolContext) async throws -> [PlannedFile] {
        let files: [FilePatch]
        do { files = try PatchParser.parse(try arguments.string("patch")) } catch let error as PatchError { throw ToolError(error.message) }
        guard files.count <= Self.maxFiles else { throw ToolError("The patch touches \(files.count) files; at most \(Self.maxFiles) at a time.") }
        if let deletion = files.first(where: \.isDeletion) {
            throw ToolError("\(deletion.path): apply_patch cannot delete files.")
        }

        var planned: [PlannedFile] = []
        for file in files {
            do {
                try context.workspace.checkWritable(path: file.path)
                if file.isCreation {
                    if (try? await context.workspace.readText(path: file.path)) != nil {
                        throw PatchError("\(file.path) already exists, so it cannot be created. Patch it instead.")
                    }
                    planned.append(try PatchPlanner.plan(file, text: nil))
                } else {
                    let text = try await context.workspace.readText(path: file.path)
                    try await EditSupport.requireFreshRead(path: file.path, text: text, context: context)
                    planned.append(try PatchPlanner.plan(file, text: text, tolerance: context.editTolerance))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as PatchError {
                throw PatchFileFailure(path: file.path, message: error.message)
            } catch let error as PatchFileFailure {
                throw error
            } catch {
                throw PatchFileFailure(path: file.path, message: error.localizedDescription)
            }
        }
        return planned
    }

    public func editPreview(for arguments: ToolArguments, context: ToolContext) async -> EditPreview? {
        guard let planned = try? await prepare(arguments, context: context) else { return nil }
        let diff = planned.map { UnifiedDiff.make(path: $0.path, old: $0.original, new: $0.expected) }.joined(separator: "\n")
        let names = planned.map(\.path)
        return EditPreview(summary: "Patch \(names.count == 1 ? names[0] : "\(names.count) files: " + names.joined(separator: ", "))", diff: diff)
    }

    public func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        do {
            return try await apply(arguments, context: context)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as PatchFileFailure {
            let count = await context.editFailures?.recordFailure(failure.path) ?? 0
            let hint = EditFailureLog.hint(count: count) ?? ""
            throw ToolError(failure.message + hint)
        }
    }

    /// Everything is checked and computed first, so a bad hunk in the last file changes nothing.
    private func apply(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let planned = try await prepare(arguments, context: context)

        var applied: [PlannedFile] = []
        var writtenText: [String: String] = [:]
        do {
            for plan in planned {
                await context.checkpoint?.willChange(path: plan.path, original: plan.original)
                if plan.isCreation {
                    try await context.workspace.createFile(path: plan.path, contents: plan.expected)
                } else {
                    try await context.workspace.replaceText(path: plan.path, expecting: plan.original!, edits: plan.edits)
                }
                applied.append(plan)
                let after = try await context.workspace.readText(path: plan.path)
                writtenText[plan.path] = after
                await context.checkpoint?.didChange(path: plan.path, written: after)
            }
        } catch {
            let failed = planned[applied.count]
            let undone = await rollBack(applied, written: writtenText, context: context)
            throw PatchFileFailure(path: failed.path, message: "Applying \(failed.path) failed: \(error.localizedDescription) \(undone)")
        }

        for plan in planned where !plan.path.isEmpty {
            await context.editFailures?.recordSuccess(plan.path)
        }

        var report: [String] = []
        for plan in planned {
            let after = writtenText[plan.path] ?? plan.expected
            if after != plan.expected {
                report.append("Warning: \(plan.path) differs from what the patch should produce (it changed while being written). Read it again.")
                continue
            }
            await context.ledger.record(path: plan.path, text: after)
            if plan.isCreation {
                report.append("Created \(plan.path) (\(plan.added) lines).")
            } else {
                report.append("Patched \(plan.path): \(plan.hunkCount) hunk\(plan.hunkCount == 1 ? "" : "s"), +\(plan.added) −\(plan.removed).\(plan.matchNote)")
                if planned.count <= 3 {
                    report.append(EditSupport.snippet(
                        path: plan.path, text: after, startLine: plan.firstChangedLine, lineCount: plan.changedLineCount))
                }
            }
        }
        var text = report.joined(separator: "\n")
        for plan in planned {
            text = await context.finishFileTool(text, path: plan.path)
        }
        return text
    }

    /// Puts back what was applied before the failure, newest first. Reports what it managed.
    private func rollBack(_ applied: [PlannedFile], written: [String: String], context: ToolContext) async -> String {
        guard !applied.isEmpty else { return "Nothing was changed." }
        var failures: [String] = []
        for plan in applied.reversed() {
            do {
                if plan.isCreation {
                    try await context.workspace.trashFile(path: plan.path)
                } else if let original = plan.original {
                    let current = written[plan.path] ?? plan.expected
                    let whole = AgentTextEdit(location: 0, length: (current as NSString).length, replacement: original)
                    try await context.workspace.replaceText(path: plan.path, expecting: current, edits: [whole])
                    await context.checkpoint?.didChange(path: plan.path, written: original)
                }
            } catch {
                failures.append(plan.path)
            }
        }
        return failures.isEmpty
            ? "The files already patched were put back, so nothing was changed."
            : "Putting back \(failures.joined(separator: ", ")) failed; use Revert Run to restore them."
    }
}
