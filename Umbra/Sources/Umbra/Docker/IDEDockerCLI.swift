import Foundation

struct IDEDockerContainer: Decodable, Identifiable {
    let id: String
    let name: String
    let image: String
    let status: String
    let state: String
    let ports: String

    private enum CodingKeys: String, CodingKey {
        case id = "ID"
        case name = "Names"
        case image = "Image"
        case status = "Status"
        case state = "State"
        case ports = "Ports"
    }
}

enum IDEDockerContainerAction: String, Identifiable {
    case start, stop, restart

    var id: Self { self }

    var title: String { rawValue.capitalized }
}

struct IDEDockerCLI {
    static let executablePreferenceKey = "com.umbra.docker.executable"
    let executable: URL

    static func discover() throws -> Self {
        let override = UserDefaults.standard.string(forKey: executablePreferenceKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
                throw Failure("The Docker executable in Settings → Docker must be an executable file at an absolute path.")
            }
            return Self(executable: URL(fileURLWithPath: path))
        }

        for directory in searchDirectories {
            let executable = URL(fileURLWithPath: directory).appendingPathComponent("docker")
            if FileManager.default.isExecutableFile(atPath: executable.path) {
                return Self(executable: executable)
            }
        }
        throw Failure("Install Docker Desktop or the Docker CLI, then click Refresh.")
    }

    private static var searchDirectories: [String] {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return path.filter { $0.hasPrefix("/") }
            + ["/usr/local/bin", "/opt/homebrew/bin",
               FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".docker/bin").path,
               "/Applications/Docker.app/Contents/Resources/bin", "/usr/bin", "/bin"]
    }

    var helperSearchPath: String {
        // Finder's PATH can omit Docker's credential helpers and Homebrew SSH tooling.
        (Self.searchDirectories + [executable.deletingLastPathComponent().path]).joined(separator: ":")
    }

    func contexts() async throws -> [String] {
        try await run(["context", "ls", "--format", "{{.Name}}"])
            .split(whereSeparator: \.isNewline).map(String.init)
    }

    func currentContext() async throws -> String {
        try await run(["context", "show"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func containers(in context: String) async throws -> [IDEDockerContainer] {
        let output = try await run([
            "--context", context, "container", "ls", "--all", "--no-trunc", "--format", "{{json .}}",
        ])
        return try Self.decodeLines(output)
    }

    func images(in context: String) async throws -> [IDEDockerImage] {
        let output = try await run(["--context", context, "image", "ls", "--no-trunc", "--format", "{{json .}}"])
        return try Self.decodeLines(output)
    }

    func inspectImage(_ id: String, in context: String) async throws -> String {
        try await run(["--context", context, "image", "inspect", "--", id])
    }

    func pullImage(_ reference: String, in context: String) async throws -> String {
        try await run(["--context", context, "image", "pull", "--", reference], combineOutput: true)
    }

    private static func decodeLines<Row: Decodable>(_ output: String) throws -> [Row] {
        let decoder = JSONDecoder()
        return try output.split(whereSeparator: \.isNewline).map {
            try decoder.decode(Row.self, from: Data($0.utf8))
        }
    }

    func logs(for id: String, in context: String) async throws -> String {
        try await run(["--context", context, "container", "logs", "--tail", "200", id], combineOutput: true)
    }

    func followLogs(
        for id: String,
        in context: String,
        chunks: AsyncStream<Data>.Continuation
    ) async throws {
        defer { chunks.finish() }
        _ = try await run(
            ["--context", context, "container", "logs", "--tail", "200", "--follow", id],
            combineOutput: true,
            chunks: chunks
        )
    }

    func inspect(_ id: String, in context: String) async throws -> String {
        try await run(["--context", context, "container", "inspect", id])
    }

    func perform(_ action: IDEDockerContainerAction, on id: String, in context: String) async throws {
        _ = try await run(["--context", context, "container", action.rawValue, id])
    }

    func pluginAvailable(_ name: String) async throws -> Bool {
        do {
            _ = try await run([name, "version"])
            return true
        } catch {
            try Task.checkCancellation()
            return false
        }
    }

    func endpoint(in context: String) async throws -> String {
        try await run(["context", "inspect", "--format", "{{.Endpoints.docker.Host}}", "--", context])
    }

    func composeServices(file: URL, in context: String) async throws -> [String] {
        try await run(composeArguments(file: file, context: context) + ["config", "--services"],
                      directory: file.deletingLastPathComponent())
            .split(whereSeparator: \.isNewline).map(String.init)
    }

    func build(
        file: URL, root: URL, tag: String, in context: String, chunks: AsyncStream<Data>.Continuation
    ) async throws {
        defer { chunks.finish() }
        var arguments = ["--context", context, "buildx", "build", "--load", "--progress", "plain",
                         "--file", file.path]
        if !tag.isEmpty { arguments += ["--tag", tag] }
        _ = try await run(arguments + ["--", root.path], combineOutput: true, chunks: chunks, directory: root)
    }

    func compose(
        _ command: IDEDockerComposeCommand, file: URL, service: String?,
        in context: String, chunks: AsyncStream<Data>.Continuation
    ) async throws {
        defer { chunks.finish() }
        var arguments = composeArguments(file: file, context: context) + command.arguments
        if let service { arguments += ["--", service] }
        _ = try await run(arguments, combineOutput: true, chunks: chunks, directory: file.deletingLastPathComponent())
    }

    private func composeArguments(file: URL, context: String) -> [String] {
        ["--context", context, "compose", "--ansi", "never", "--file", file.path,
         "--project-directory", file.deletingLastPathComponent().path]
    }

    @MainActor
    private func run(
        _ arguments: [String],
        combineOutput: Bool = false,
        chunks: AsyncStream<Data>.Continuation? = nil,
        directory: URL? = nil
    ) async throws -> String {
        try Task.checkCancellation()
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = helperSearchPath
        process.environment = environment
        process.currentDirectoryURL = directory
        // Docker and its SSH transport should not wait for terminal input.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = combineOutput ? stdout : stderr

        let (statuses, completion) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { process in
            completion.yield(process.terminationStatus)
            completion.finish()
        }
        try process.run()

        async let output = Self.drain(stdout.fileHandleForReading, chunks: chunks)
        async let errors = Self.drain(combineOutput ? nil : stderr.fileHandleForReading)
        let status = await withTaskCancellationHandler {
            var iterator = statuses.makeAsyncIterator()
            return await iterator.next()
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        let (outputText, errorText) = await (output, errors)
        try Task.checkCancellation()
        guard status == 0 else {
            let message = (combineOutput ? outputText : errorText).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message.isEmpty ? "Docker exited with status \(status ?? -1)." : message)
        }
        return outputText
    }

    private static func drain(
        _ handle: FileHandle?,
        chunks: AsyncStream<Data>.Continuation? = nil
    ) async -> String {
        guard let handle else { return "" }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                // Keep draining after the limit so a verbose child can still exit.
                var data = Data()
                let limit = 4 * 1024 * 1024
                var truncated = false
                while true {
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else { break }
                    chunks?.yield(chunk)
                    let remaining = limit - data.count
                    data.append(contentsOf: chunk.prefix(remaining))
                    truncated = truncated || chunk.count > remaining
                }
                var output = String(decoding: data, as: UTF8.self)
                if truncated { output += "\n[Output truncated]" }
                continuation.resume(returning: output)
            }
        }
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?

        init(_ description: String) {
            errorDescription = description
        }
    }
}
