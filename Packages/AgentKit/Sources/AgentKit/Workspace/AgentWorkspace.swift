import Foundation

public struct DirectoryEntry: Sendable, Hashable {
    public let name: String
    public let isDirectory: Bool

    public init(name: String, isDirectory: Bool) {
        self.name = name
        self.isDirectory = isDirectory
    }
}

public struct SearchQuery: Sendable, Hashable {
    public var pattern: String
    public var isRegex: Bool
    public var caseSensitive: Bool
    /// Project-relative folder or file to search under; `nil` for the whole project.
    public var path: String?
    /// Only files whose project-relative path matches (see `GlobPattern`).
    public var fileGlob: String?
    public var maxResults: Int

    public init(
        pattern: String, isRegex: Bool = true, caseSensitive: Bool = true,
        path: String? = nil, fileGlob: String? = nil, maxResults: Int = 100
    ) {
        self.pattern = pattern
        self.isRegex = isRegex
        self.caseSensitive = caseSensitive
        self.path = path
        self.fileGlob = fileGlob
        self.maxResults = maxResults
    }
}

public struct SearchMatch: Sendable, Hashable {
    public let path: String
    /// 1-based.
    public let line: Int
    public let text: String

    public init(path: String, line: Int, text: String) {
        self.path = path
        self.line = line
        self.text = text
    }
}

public struct SearchResults: Sendable, Hashable {
    public var matches: [SearchMatch]
    /// More matches existed than `maxResults`.
    public var truncated: Bool

    public init(matches: [SearchMatch], truncated: Bool) {
        self.matches = matches
        self.truncated = truncated
    }
}

public enum AgentWorkspaceError: Error, Sendable, Equatable, LocalizedError {
    case outsideProject(String)
    case notFound(String)
    case notAFile(String)
    case notADirectory(String)
    case notText(String)
    case tooLarge(path: String, bytes: Int)
    case invalidPattern(String)
    case readOnly
    case writeProtected(String)
    case alreadyExists(String)
    /// The text on disk or in the editor no longer matches what the tool based its edit on.
    case changedSinceRead(String)
    case unsavedBuffer(String)
    case invalidEdit(String)
    case writeFailed(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .outsideProject(let path): "\(path) is outside the project."
        case .notFound(let path): "\(path) does not exist."
        case .notAFile(let path): "\(path) is not a file."
        case .notADirectory(let path): "\(path) is not a directory."
        case .notText(let path): "\(path) is not a UTF-8 text file."
        case .tooLarge(let path, let bytes): "\(path) is too large to read (\(bytes) bytes)."
        case .invalidPattern(let detail): "Invalid pattern: \(detail)"
        case .readOnly: "This workspace is read-only."
        case .writeProtected(let path): "\(path) is build output or version-control data; the agent does not write there."
        case .alreadyExists(let path): "\(path) already exists."
        case .changedSinceRead(let path): "\(path) changed while the edit was being prepared. Read it again."
        case .unsavedBuffer(let path): "\(path) has unsaved changes in an editor and cannot be written on disk."
        case .invalidEdit(let detail): "Invalid edit: \(detail)"
        case .writeFailed(let path, let reason): "Could not write \(path): \(reason)"
        }
    }
}

/// One replacement inside a file's text, addressed by UTF-16 offsets into the text the tool read.
public struct AgentTextEdit: Sendable, Hashable {
    public let location: Int
    public let length: Int
    public let replacement: String

    public init(location: Int, length: Int, replacement: String) {
        self.location = location
        self.length = length
        self.replacement = replacement
    }

    /// Sorted, in range, and not overlapping; the shape every workspace may rely on.
    public static func validate(_ edits: [AgentTextEdit], in text: String) throws {
        let total = (text as NSString).length
        var end = 0
        for edit in edits.sorted(by: { $0.location < $1.location }) {
            guard edit.location >= 0, edit.length >= 0, edit.location + edit.length <= total else {
                throw AgentWorkspaceError.invalidEdit("a range points outside the file")
            }
            guard edit.location >= end else { throw AgentWorkspaceError.invalidEdit("two edits overlap") }
            end = edit.location + edit.length
        }
    }

    /// The text with every edit applied; edits address the original text.
    public static func apply(_ edits: [AgentTextEdit], to text: String) throws -> String {
        try validate(edits, in: text)
        let result = NSMutableString(string: text)
        for edit in edits.sorted(by: { $0.location > $1.location }) {
            result.replaceCharacters(in: NSRange(location: edit.location, length: edit.length), with: edit.replacement)
        }
        return result as String
    }
}

/// The seam between the generic tools and the app. A file's text is what the user would see: Umbra
/// answers from an open buffer, `DiskAgentWorkspace` from disk. Paths are project-relative, with `/`.
public protocol AgentWorkspace: Sendable {
    /// Absolute path of the project root, for the system prompt.
    var rootPath: String { get }
    func readText(path: String) async throws -> String
    func listDirectory(path: String) async throws -> [DirectoryEntry]
    /// Every file a search or glob should see, project-relative and sorted.
    func allFiles() async throws -> [String]
    func search(_ query: SearchQuery) async throws -> SearchResults

    // MARK: Writing
    // Defaults make a workspace read-only. A writer must refuse paths outside the project and
    // under protected folders even if a tool forgot to ask, and must leave open buffers dirty.

    /// Throws `.outsideProject` or `.writeProtected` for a path the agent may not write.
    func checkWritable(path: String) throws

    /// Applies `edits` to the file's current text, which must still equal `expecting`. An open
    /// editor gets the change as one undo group; a closed file is rewritten atomically.
    func replaceText(path: String, expecting: String, edits: [AgentTextEdit]) async throws

    /// Creates a new file, and its folders; fails if the path exists.
    func createFile(path: String, contents: String) async throws

    /// Moves a file to the Trash, closing any editor on it.
    func trashFile(path: String) async throws
}

extension AgentWorkspace {
    public func checkWritable(path: String) throws { throw AgentWorkspaceError.readOnly }
    public func replaceText(path: String, expecting: String, edits: [AgentTextEdit]) async throws {
        throw AgentWorkspaceError.readOnly
    }
    public func createFile(path: String, contents: String) async throws { throw AgentWorkspaceError.readOnly }
    public func trashFile(path: String) async throws { throw AgentWorkspaceError.readOnly }
}
