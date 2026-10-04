import Foundation

/// One scripted task: a small project, a prompt, and a command that decides whether the work is done.
public struct EvalTask: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var difficulty: String
    public var prompt: String
    /// Run in the project folder after the agent finishes; exit status 0 means the task is done.
    public var check: String
    /// Globs of files the agent must leave unchanged (the tests). Changing one fails the trial.
    public var protected: [String]
    public var timeoutSeconds: Int
    public var projectDirectory: URL
    /// Files laid over the project to make the reference solution; used by `validate`.
    public var solutionDirectory: URL?
}

public enum TaskLibraryError: Error, LocalizedError, Equatable {
    case noTasksFolder(String)
    case invalidTask(id: String, reason: String)
    case unknownTasks([String])

    public var errorDescription: String? {
        switch self {
        case .noTasksFolder(let path): "No tasks folder at \(path). Pass --task-dir."
        case .invalidTask(let id, let reason): "Task \(id) is invalid: \(reason)"
        case .unknownTasks(let ids): "Unknown task\(ids.count == 1 ? "" : "s"): \(ids.joined(separator: ", "))"
        }
    }
}

/// Loads `<folder>/<id>/task.json` with its `project/` (and optional `solution/`) folders.
public enum TaskLibrary {
    private struct File: Decodable {
        var title: String
        var difficulty: String?
        var prompt: String
        var check: String
        var protected: [String]?
        var timeoutSeconds: Int?
    }

    /// `Tools/AgentEval/Tasks` of this checkout, found from this source file.
    public static func defaultDirectory() -> URL {
        // Derived here, from this file's own location, so it is right whichever target calls it.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tasks", isDirectory: true)
    }

    public static func load(from folder: URL, only ids: [String]? = nil) throws -> [EvalTask] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TaskLibraryError.noTasksFolder(folder.path)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        var tasks: [EvalTask] = []
        for name in names where !name.hasPrefix(".") {
            let directory = folder.appendingPathComponent(name, isDirectory: true)
            let manifest = directory.appendingPathComponent("task.json")
            guard FileManager.default.fileExists(atPath: manifest.path) else { continue }
            let file: File
            do { file = try JSONDecoder().decode(File.self, from: Data(contentsOf: manifest)) } catch {
                throw TaskLibraryError.invalidTask(id: name, reason: "task.json: \(error.localizedDescription)")
            }
            let project = directory.appendingPathComponent("project", isDirectory: true)
            guard FileManager.default.fileExists(atPath: project.path) else {
                throw TaskLibraryError.invalidTask(id: name, reason: "no project/ folder")
            }
            guard !file.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !file.check.isEmpty else {
                throw TaskLibraryError.invalidTask(id: name, reason: "empty prompt or check")
            }
            let solution = directory.appendingPathComponent("solution", isDirectory: true)
            tasks.append(EvalTask(
                id: name, title: file.title, difficulty: file.difficulty ?? "medium", prompt: file.prompt, check: file.check,
                protected: file.protected ?? [], timeoutSeconds: file.timeoutSeconds ?? 60, projectDirectory: project,
                solutionDirectory: FileManager.default.fileExists(atPath: solution.path) ? solution : nil))
        }
        guard let ids else { return tasks }
        let missing = ids.filter { id in !tasks.contains { $0.id == id } }
        guard missing.isEmpty else { throw TaskLibraryError.unknownTasks(missing) }
        return ids.compactMap { id in tasks.first { $0.id == id } }
    }
}
