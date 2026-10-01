import Foundation

enum JavaDebugProcessError: Error, Sendable {
    case adapterNotFound
    case launchFailed(String)
    case disconnected
}

extension JavaDebugProcessError: LocalizedError {
    /// Without it the panel shows "The operation couldn't be completed. (…error 0.)".
    var errorDescription: String? {
        switch self {
        case .adapterNotFound: "The Java debug adapter was not found."
        case .launchFailed(let message): message
        case .disconnected: "The debug adapter disconnected."
        }
    }
}

/// Spawns the JDI debug adapter and the target JVM process.
struct JavaDebugProcessLauncher: Sendable {
    func adapterJarURL() -> URL? {
        let bundled = Bundle.main.url(forResource: "java-debug-adapter", withExtension: "jar")
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Tools/JavaDebugAdapter/build/java-debug-adapter.jar")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    func startAdapter(javaHome: URL) throws -> Process {
        guard let jar = adapterJarURL() else { throw JavaDebugProcessError.adapterNotFound }
        let process = Process()
        process.executableURL = javaHome.appendingPathComponent("bin/java")
        process.arguments = ["-jar", jar.path]
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        return process
    }
}
