import Foundation

enum IDEProjectWriterError: LocalizedError, Equatable {
    case invalid(String)
    case unsafePath(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .unsafePath(let path): "The template produced a path outside the project: \(path)"
        }
    }
}

/// Writes a template's files to disk. The whole project is written into a hidden staging folder
/// next to the destination and renamed into place, so a failure never leaves a half-written
/// project and an existing folder is never touched.
enum IDEProjectWriter {
    /// Creates the project and returns its root. Blocking file I/O: call it off the main actor.
    @discardableResult
    static func create(
        _ template: any IDEProjectTemplate,
        options: IDENewProjectOptions,
        fileManager: FileManager = .default
    ) throws -> URL {
        if let issue = IDENewProjectValidator.issues(for: options, template: template, fileManager: fileManager).first {
            throw IDEProjectWriterError.invalid(issue.message)
        }
        let files = try template.files(for: options)
        let destination = options.rootURL
        let staging = options.parentDirectory
            .appendingPathComponent(".\(options.name).umbra-new-\(UUID().uuidString)", isDirectory: true)

        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for file in files {
                let target = try resolve(file.path, in: staging)
                try fileManager.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try file.data.write(to: target, options: .atomic)
            }
            // moveItem fails when the destination appeared in the meantime, which is what we want.
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        return destination
    }

    /// `relative` joined to `root`, refusing absolute paths and `..` components.
    private static func resolve(_ relative: String, in root: URL) throws -> URL {
        let components = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard !relative.hasPrefix("/"), !components.isEmpty, !components.contains("..") else {
            throw IDEProjectWriterError.unsafePath(relative)
        }
        return components.reduce(root) { $0.appendingPathComponent(String($1)) }
    }
}
