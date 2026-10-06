import AgentKit
import EditorIntelligence
import Foundation
import GitIntelligence

/// Turns the agent's UTF-16 offsets into the line and column positions `WorkspaceEdit` uses. Pure,
/// so it is checked against `WorkspaceEdit.apply`, which is what a closed file goes through.
enum IDEAgentEditTranslator {
    static func textEdits(_ edits: [AgentTextEdit], in text: String) throws -> [TextEdit] {
        try AgentTextEdit.validate(edits, in: text)
        let starts = lineStarts(in: text as NSString)
        func position(_ offset: Int) -> TextPosition {
            // Last line whose start is at or before the offset.
            var low = 0
            var high = starts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if starts[mid] <= offset { low = mid } else { high = mid - 1 }
            }
            return TextPosition(line: low, column: offset - starts[low], utf16Offset: offset)
        }
        return edits.map {
            TextEdit(
                range: TextRange(start: position($0.location), end: position($0.location + $0.length)),
                replacement: $0.replacement)
        }
    }

    /// Line starts as the editor counts them: `\n`, `\r\n` and a lone `\r` each end a line.
    static func lineStarts(in text: NSString) -> [Int] {
        var starts = [0]
        var index = 0
        while index < text.length {
            let unit = text.character(at: index)
            if unit == 0x0A {
                starts.append(index + 1)
            } else if unit == 0x0D {
                if index + 1 < text.length, text.character(at: index + 1) == 0x0A { index += 1 }
                starts.append(index + 1)
            }
            index += 1
        }
        return starts
    }
}

/// The agent's view of a window's project: reads come from `DiskAgentWorkspace` with the open
/// buffers' unsaved text laid over it; writes go through the window (`IDEWorkspaceEditApplier`), so
/// an open file is edited in its buffer as one undo group and left dirty, and a closed one is
/// rewritten atomically.
struct IDEAgentWorkspace: AgentWorkspace {
    /// A write that went through: the project-relative path, what the file held before (`nil` if it was
    /// new) and after (`nil` if it was deleted). For Local History.
    typealias WriteObserver = @Sendable (_ path: String, _ before: String?, _ after: String?) -> Void

    let disk: DiskAgentWorkspace
    let box: IDEAgentHostBox
    let onWrite: WriteObserver?

    init(root: URL, box: IDEAgentHostBox, onWrite: WriteObserver? = nil) {
        self.box = box
        self.onWrite = onWrite
        disk = DiskAgentWorkspace(root: root, unsavedBuffers: {
            await box.read(default: [:]) { $0.agentUnsavedBuffers() }
        }, visibleFiles: {
            await IDEGitVisibleFiles.relativePaths(under: root)
        })
    }

    var rootPath: String { disk.rootPath }

    func readText(path: String) async throws -> String { try await disk.readText(path: path) }
    func listDirectory(path: String) async throws -> [DirectoryEntry] { try await disk.listDirectory(path: path) }
    func allFiles() async throws -> [String] { try await disk.allFiles() }
    func search(_ query: SearchQuery) async throws -> SearchResults { try await disk.search(query) }

    func checkWritable(path: String) throws { try disk.checkWritable(path: path) }

    /// The jail-checked, project-relative spelling of a path.
    private func relative(_ path: String) throws -> String {
        try disk.checkWritable(path: path)
        return disk.jail.relativePath(of: try disk.jail.resolve(path))
    }

    func replaceText(path: String, expecting: String, edits: [AgentTextEdit]) async throws {
        let relativePath = try relative(path)
        try await box.replaceText(relativePath: relativePath, expecting: expecting, edits: edits)
        if let onWrite, let after = try? AgentTextEdit.apply(edits, to: expecting) { onWrite(relativePath, expecting, after) }
    }

    func createFile(path: String, contents: String) async throws {
        let relativePath = try relative(path)
        try await box.createFile(relativePath: relativePath, contents: contents)
        onWrite?(relativePath, nil, contents)
    }

    func trashFile(path: String) async throws {
        let relativePath = try relative(path)
        let before = try? await disk.readText(path: relativePath)
        try await box.trashFile(relativePath: relativePath)
        onWrite?(relativePath, before, nil)
    }
}
