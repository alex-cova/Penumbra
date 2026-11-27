import CryptoKit
import Foundation
import os

/// Stores test results and console logs. Exact replay settings live in the current process.
public actor GradleTestHistory {
    public enum State: String, Codable, Sendable {
        case running, finished, cancelled, failed, interrupted
    }

    public struct Summary: Identifiable, Codable, Sendable {
        public let id: UUID
        public let root: URL
        public let tasks: [String]
        public let started: Date
        public let original: UUID?
        public var state: State
        public var exitCode: Int32?
        public var finishedAt: Date?
        public var message: String?
    }

    public static let shared = GradleTestHistory(directory: FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    )[0].appendingPathComponent("Umbra/Gradle Test History", isDirectory: true))

    public nonisolated let directory: URL
    private var writers: Set<UUID> = []
    private var readers: [UUID: Int] = [:]

    public init(directory: URL) { self.directory = directory }

    public nonisolated func directory(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func begin(root: URL, tasks: [String], original: UUID? = nil) throws -> Summary {
        let summary = Summary(id: UUID(), root: root.standardizedFileURL, tasks: tasks, started: Date(), original: original, state: .running)
        let folder = directory(for: summary.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try write(summary)
        writers.insert(summary.id)
        return summary
    }

    public func finish(_ summary: Summary, state: State, exitCode: Int32?, message: String, days: Int, bytes: Int64) throws {
        defer { writers.remove(summary.id) }
        var finished = summary
        finished.state = state
        finished.exitCode = exitCode
        finished.finishedAt = Date()
        finished.message = message
        try write(finished)
        try evict(days: days, bytes: bytes)
    }

    public func list(root: URL) -> [Summary] {
        summaries().filter { $0.root.path == root.standardizedFileURL.path }
            .sorted { $0.started > $1.started }
    }

    public func acquire(_ id: UUID) -> Bool {
        guard FileManager.default.fileExists(atPath: directory(for: id).path) else { return false }
        readers[id, default: 0] += 1
        return true
    }

    public func release(_ id: UUID) {
        guard let count = readers[id] else { return }
        readers[id] = count == 1 ? nil : count - 1
    }

    public func evict(days: Int, bytes: Int64, now: Date = Date()) throws {
        let entries = summaries().sorted { $0.started < $1.started }.map { ($0, size(of: directory(for: $0.id))) }
        var total = entries.reduce(Int64.zero) { $0 + $1.1 }
        let oldest = now.addingTimeInterval(-Double(max(0, days)) * 86400)
        for (summary, size) in entries {
            guard !writers.contains(summary.id), readers[summary.id] == nil,
                  summary.started < oldest || total > max(0, bytes) else { continue }
            let folder = directory(for: summary.id)
            try FileManager.default.removeItem(at: folder)
            GradleLaunchSnapshot.discard(for: folder)
            total -= size
        }
    }

    private func summaries() -> [Summary] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("summary.json")),
                  var summary = try? JSONDecoder().decode(Summary.self, from: data) else { return nil }
            if summary.state == .running, !writers.contains(summary.id) {
                summary.state = .interrupted
                summary.message = "Umbra closed before the Gradle invocation finished."
            }
            return summary
        }
    }

    private func write(_ summary: Summary) throws {
        try JSONEncoder().encode(summary).write(to: directory(for: summary.id).appendingPathComponent("summary.json"), options: .atomic)
    }

    private func size(of folder: URL) -> Int64 {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        var total: Int64 = 0
        while let file = files?.nextObject() as? URL {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }
}

/// A resolved Gradle client launch. Files are fingerprinted at launch and revalidated at replay.
public struct GradleLaunchSnapshot: Codable, Sendable {
    public enum ReplayError: LocalizedError {
        case changedFile(String), missingIdentity, modifiedLaunch, unavailable(String)

        public var errorDescription: String? {
            switch self {
            case .changedFile(let path): "The original Gradle executable, wrapper, distribution or JDK changed: \(path)."
            case .missingIdentity: "The original wrapper distribution or JDK could not be identified."
            case .unavailable(let reason): reason
            case .modifiedLaunch: "This launch needs a fresh debugger, coverage collector or before-launch step."
            }
        }
    }

    public let executable: URL
    public let leadingArguments: [String]
    public let root: URL
    public let tasks: [String]
    public let arguments: [String]
    public let environment: [String: String]
    public let javaHome: URL?
    public let workingDirectory: URL
    public let canReplay: Bool
    public let gradleVersion: String?
    public let beforeLaunch: [JavaRunConfiguration.BeforeLaunchTask]
    public let instrumentation: JavaRunInstrumentation
    private let fingerprints: [String: Data]

    init(
        executable: URL, leadingArguments: [String], root: URL, tasks: [String], arguments: [String],
        environment: [String: String], javaHome: URL?, canReplay: Bool, workingDirectory: URL,
        beforeLaunch: [JavaRunConfiguration.BeforeLaunchTask], instrumentation: JavaRunInstrumentation
    ) throws {
        self.executable = executable
        self.leadingArguments = leadingArguments
        self.root = root
        self.tasks = tasks
        self.arguments = arguments
        self.environment = environment
        self.javaHome = javaHome
        self.workingDirectory = workingDirectory
        self.canReplay = canReplay
        self.beforeLaunch = beforeLaunch
        self.instrumentation = instrumentation
        let manager = FileManager.default
        let wrapper = root.appendingPathComponent("gradlew")
        let properties = root.appendingPathComponent("gradle/wrapper/gradle-wrapper.properties")
        let jar = root.appendingPathComponent("gradle/wrapper/gradle-wrapper.jar")
        var files = [executable]
        var version: String?
        if manager.fileExists(atPath: wrapper.path) {
            files += [wrapper, properties, jar]
            let contents = try String(contentsOf: properties, encoding: .utf8)
            guard let match = contents.firstMatch(of: /gradle-([0-9]+\.[0-9]+(?:\.[0-9]+)?)-(bin|all)\.zip/),
                  !contents.contains("distributionBase=PROJECT"), !contents.contains("distributionPath=") ||
                    contents.contains("distributionPath=wrapper/dists") else {
                throw ReplayError.missingIdentity
            }
            let discovered = String(match.1)
            version = discovered
            let home = environment["GRADLE_USER_HOME"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gradle")
            let folder = home.appendingPathComponent("wrapper/dists/gradle-\(discovered)-\(match.2)")
            let distributions = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            let launchers = distributions.map {
                $0.appendingPathComponent("gradle-\(discovered)/lib/gradle-launcher-\(discovered).jar")
            }.filter { manager.fileExists(atPath: $0.path) }
            guard launchers.count == 1 else { throw ReplayError.missingIdentity }
            files += launchers
        } else {
            let executable = executable.resolvingSymlinksInPath()
            let libs = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib")
            let candidates = try manager.contentsOfDirectory(at: libs, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("gradle-launcher-") && $0.pathExtension == "jar" }
            guard let launcher = candidates.first, candidates.count == 1 else { throw ReplayError.missingIdentity }
            version = String(launcher.deletingPathExtension().lastPathComponent.dropFirst("gradle-launcher-".count))
            files += candidates
        }
        let jdk = javaHome ?? environment["JAVA_HOME"].map { URL(fileURLWithPath: $0) }
        guard let jdk else { throw ReplayError.missingIdentity }
        files += [jdk.appendingPathComponent("release"), jdk.appendingPathComponent("bin/java")]
        var values: [String: Data] = [:]
        for file in files { values[file.path] = try Self.fingerprint(file) }
        fingerprints = values
        gradleVersion = version
    }

    public func validate(root: URL) throws {
        guard canReplay, root.standardizedFileURL == self.root.standardizedFileURL else { throw ReplayError.modifiedLaunch }
        for (path, expected) in fingerprints {
            guard (try? Self.fingerprint(URL(fileURLWithPath: path))) == expected else { throw ReplayError.changedFile(path) }
        }
    }

    // A launch can inherit credentials through environment variables or arguments.
    private static let replaySettings = OSAllocatedUnfairLock(initialState: [URL: Result<Self, Error>]())

    static func remember(_ result: Result<Self, Error>, for directory: URL) {
        replaySettings.withLock { $0[directory.standardizedFileURL] = result }
    }

    static func hasReplaySettings(for directory: URL) -> Bool {
        replaySettings.withLock { settings in
            if case .success? = settings[directory.standardizedFileURL] { return true }
            return false
        }
    }

    static func discard(for directory: URL) {
        _ = replaySettings.withLock { $0.removeValue(forKey: directory.standardizedFileURL) }
    }

    public static func load(from directory: URL) throws -> Self {
        guard let result = replaySettings.withLock({ $0[directory.standardizedFileURL] }) else {
            throw ReplayError.unavailable("Exact replay requires a run started in this Umbra session.")
        }
        return try result.get()
    }

    private static func fingerprint(_ file: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 128 * 1024), !data.isEmpty { hash.update(data: data) }
        return Data(hash.finalize())
    }
}
