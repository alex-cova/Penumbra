import CryptoKit
import Foundation
import SubprocessKit

/// The compilation database SourceKit-LSP needs for an Xcode project, and the one process that makes it.
///
/// SourceKit-LSP understands a SwiftPM package on its own. For an `.xcodeproj` it knows nothing: a file
/// opened from one has no module, no SDK and no sibling files, so every type declared in another file is
/// unknown. `xcodebuild -showBuildSettingsForIndex` is what Xcode itself asks for the same purpose; its
/// answer becomes `compile_commands.json` (see ``IDEXcodeIndexSettings``).
///
/// The database lives in the app's cache folder, not in the project: the project is the user's and
/// nothing is written there. SourceKit-LSP ignores an absolute search path outside the workspace and
/// follows a relative one, so ``initializationOptions(for:caches:)`` names it relative to the project.
enum IDEXcodeIndexDatabase {
    enum Outcome: Equatable, Sendable {
        case generated(files: Int, modules: Int)
        /// There is nothing to generate from or nothing to generate with (no project, no `xcodebuild`).
        case unavailable(String)
        case failed(String)

        var isUsable: Bool {
            if case .generated = self { return true }
            return false
        }
    }

    static let fileName = "compile_commands.json"

    /// `<caches>/com.umbra.editor/sourcekit/<16 hex digits of the folder path's SHA-256>`.
    static func directory(for root: URL, caches: URL? = nil) -> URL {
        let base = caches ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return base
            .appendingPathComponent("com.umbra.editor", isDirectory: true)
            .appendingPathComponent("sourcekit", isDirectory: true)
            .appendingPathComponent(hex, isDirectory: true)
    }

    /// An Xcode project with no `Package.swift`: SourceKit-LSP finds a package by itself, so a folder with
    /// both is left to it.
    static func isXcodeOnly(root: URL) -> Bool {
        !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path)
            && IDEXcodeProjectModel.findProject(in: root) != nil
    }

    /// `{"compilationDatabase": {"searchPaths": ["../../Library/Caches/…"]}}` for an Xcode-only folder whose
    /// database exists, else nil (the server then starts as it does for any other folder).
    static func initializationOptions(for root: URL, caches: URL? = nil) -> Data? {
        guard isXcodeOnly(root: root) else { return nil }
        let directory = directory(for: root, caches: caches)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path) else { return nil }
        // SourceKit-LSP resolves the folder's symlinks (`/var` → `/private/var`) before it applies the `..`
        // of a relative search path, so the path is counted between the real locations, not the spelled ones.
        let path = IDEXcodeIndexSettings.relativePath(
            from: URL(fileURLWithPath: IDEXcodeIndexSettings.realPath(root.path) ?? root.path),
            to: URL(fileURLWithPath: IDEXcodeIndexSettings.realPath(directory.path) ?? directory.path)
        )
        let options: [String: Any] = ["compilationDatabase": ["searchPaths": [path]]]
        return try? JSONSerialization.data(withJSONObject: options, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Asks `xcodebuild` for the project's index settings and writes the database. `environment` nil
    /// inherits the app's; tests pass a PATH that holds a fake `xcodebuild`.
    ///
    /// A failure leaves the previous database in place: a stale one still gives the server module,
    /// SDK and sibling files, which is most of what it needs.
    static func generate(root: URL, caches: URL? = nil, environment: [String: String]? = nil) async -> Outcome {
        guard let project = IDEXcodeProjectModel.findProject(in: root) else { return .unavailable("No Xcode project in this folder.") }
        guard let xcodebuild = IDEXcodeProjectSystem.resolveXcodebuild(environment: environment) else {
            return .unavailable("xcodebuild was not found.")
        }
        var request = SubprocessRequest(
            executable: xcodebuild,
            arguments: ["-project", project.path, "-alltargets", "-showBuildSettingsForIndex", "-json", "-skipPackageUpdates"]
        )
        request.workingDirectory = root
        request.environment = environment
        request.processGroup = true
        request.killGroupOnExit = true
        request.timeout = nil
        request.stderrCapture = .bounded(head: 2_048, tail: 2_048)
        let result: SubprocessResult
        do {
            result = try await SubprocessRunner.run(request)
        } catch {
            return .failed("xcodebuild failed to start.")
        }
        if result.cancelled || Task.isCancelled { return .failed("Cancelled.") }
        guard result.exit.succeeded else {
            let detail = result.stderr.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed("xcodebuild exited with status \(result.exit.status). \(detail)".trimmingCharacters(in: .whitespaces))
        }

        let model = try? IDEXcodeProjectModel.load(projectURL: project)
        let targetOrder = (model?.targets ?? []).sorted { ($0.kind == .test ? 1 : 0) < ($1.kind == .test ? 1 : 0) }.map(\.name)
        let folder = directory(for: root, caches: caches)
        let database: IDEXcodeIndexSettings.Database
        do {
            database = try IDEXcodeIndexSettings.database(
                from: result.stdout.data, projectRoot: root, responseFileDirectory: folder, targetOrder: targetOrder
            )
        } catch IDEXcodeIndexSettings.Failure.noSwiftFiles {
            return .unavailable("The project has no Swift sources.")
        } catch {
            return .failed("xcodebuild did not print index settings.")
        }
        do {
            try write(database, to: folder)
        } catch {
            return .failed("The database could not be written: \(error.localizedDescription)")
        }
        return .generated(files: database.fileCount, modules: database.moduleCount)
    }

    /// Replaces the folder's response files and then the database that names them, so a reader never sees
    /// a database whose response files are missing.
    static func write(_ database: IDEXcodeIndexSettings.Database, to folder: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in database.responseFiles.keys.sorted() {
            try Data(database.responseFiles[name]!.utf8).write(to: folder.appendingPathComponent(name), options: .atomic)
        }
        try database.compileCommands.write(to: folder.appendingPathComponent(fileName), options: .atomic)
        let current = Set(database.responseFiles.keys)
        for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        where name.hasSuffix(".rsp") && !current.contains(name) {
            try? fileManager.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
