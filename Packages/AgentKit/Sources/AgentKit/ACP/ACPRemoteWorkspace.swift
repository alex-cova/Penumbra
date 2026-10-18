import Foundation

/// An `AgentWorkspace` that reads through to the ACP client when the local project does not
/// have the file: a missing or out-of-jail path falls back to the remote client's
/// `fs/read_text_file` (only when the client advertised it). Listing, search, and all writes
/// stay local — the endpoint never writes to the client's machine in v1.
public struct ACPRemoteWorkspace: AgentWorkspace, Sendable {
    public let local: any AgentWorkspace
    /// Reads an absolute path from the remote client. `nil` when the client did not advertise
    /// `fs.readTextFile`.
    public var remoteFileReader: (@Sendable (String) async throws -> String)?

    public init(local: any AgentWorkspace, remoteFileReader: (@Sendable (String) async throws -> String)? = nil) {
        self.local = local
        self.remoteFileReader = remoteFileReader
    }

    public var rootPath: String { local.rootPath }

    public func readText(path: String) async throws -> String {
        do {
            return try await local.readText(path: path)
        } catch let error as AgentWorkspaceError {
            switch error {
            case .notFound, .outsideProject:
                guard let remoteFileReader else { throw error }
                return try await remoteFileReader(path)
            default:
                throw error
            }
        }
    }

    public func listDirectory(path: String) async throws -> [DirectoryEntry] {
        try await local.listDirectory(path: path)
    }

    public func allFiles() async throws -> [String] { try await local.allFiles() }

    public func search(_ query: SearchQuery) async throws -> SearchResults {
        try await local.search(query)
    }

    public func checkWritable(path: String) throws { try local.checkWritable(path: path) }

    public func replaceText(path: String, expecting: String, edits: [AgentTextEdit]) async throws {
        try await local.replaceText(path: path, expecting: expecting, edits: edits)
    }

    public func createFile(path: String, contents: String) async throws {
        try await local.createFile(path: path, contents: contents)
    }

    public func trashFile(path: String) async throws { try await local.trashFile(path: path) }
}
